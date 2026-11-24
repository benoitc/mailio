%%% @doc SMTP submission client (RFC 6409, RFC 5321).
%%%
%%% One call submits one message. The result tells the caller exactly where
%%% a failure happened, because that decides whether a retry is safe:
%%% <ul>
%%%   <li>`smtp_transient' (retryable): the failure came before the message
%%%       body was sent (connect, TLS, authentication, envelope). Nothing was
%%%       submitted.</li>
%%%   <li>`smtp_rejected': the server refused the sender, every recipient or
%%%       the message itself. Nothing was submitted and retrying will not help.</li>
%%%   <li>`smtp_outcome_unknown': the body was sent but no final reply came.
%%%       The message may have been accepted. Never resend automatically.</li>
%%% </ul>
%%% A success reports which recipients were accepted and which were refused.
%%%
%%% Config: `#{host, port, tls => true | starttls | false, verify =>
%%% verify_peer | verify_none, cacerts | cacertfile, ehlo_name, credentials}'. TLS
%%% certificates and host names are verified unless `verify' says otherwise.
%%% `credentials' is a `mailio_credentials:cred()'.
-module(mailio_smtp).

-export([submit/4]).

-export_type([config/0, result/0]).

-define(TIMEOUT, 30000).

-type config() :: map().
-type result() :: #{
    accepted := [binary()],
    rejected := [#{recipient := binary(), code := integer(), reply := binary()}],
    code := integer(),
    reply := binary()
}.

-record(c, {mod :: gen_tcp | ssl, sock :: term(), config :: map()}).

-spec submit(config(), binary(), [binary()], iodata()) ->
    {ok, result()} | mailio_error:t().
submit(Config, From, Rcpts, Data) ->
    try
        C0 = connect(Config),
        {220, _} = read_reply(C0),
        {C1, Caps} = ehlo(C0, Config),
        C2 = auth(C1, Config, Caps),
        session(C2, From, Rcpts, Data)
    catch
        throw:{mailio_smtp, Error} ->
            Error;
        error:{badmatch, {Code, Text}} when is_integer(Code) ->
            transient(unexpected_reply, #{code => Code, reply => bin(Text)})
    end.

%%====================================================================
%% Connection, EHLO, STARTTLS, AUTH
%%====================================================================

connect(#{host := Host} = Config) ->
    Port = maps:get(port, Config, default_port(maps:get(tls, Config, starttls))),
    HostStr = to_list(Host),
    case maps:get(tls, Config, starttls) of
        true ->
            case ssl:connect(HostStr, Port, ssl_opts(Config) ++ sock_opts(), ?TIMEOUT) of
                {ok, S} -> #c{mod = ssl, sock = S, config = Config};
                {error, R} -> throw({mailio_smtp, tls_error(R)})
            end;
        _ ->
            case gen_tcp:connect(HostStr, Port, sock_opts(), ?TIMEOUT) of
                {ok, S} ->
                    #c{mod = gen_tcp, sock = S, config = Config};
                {error, R} ->
                    throw(
                        {mailio_smtp,
                            mailio_error:new(
                                smtp_connect_failed,
                                <<"cannot connect to the SMTP server">>,
                                #{reason => R}
                            )}
                    )
            end
    end.

default_port(true) -> 465;
default_port(_) -> 587.

sock_opts() -> [{active, false}, binary, {packet, line}].

ssl_opts(#{host := Host} = Config) ->
    Base = [{server_name_indication, to_list(Host)}, {versions, ['tlsv1.3', 'tlsv1.2']}],
    case maps:get(verify, Config, verify_peer) of
        verify_none ->
            [{verify, verify_none} | Base];
        verify_peer ->
            CA =
                case {maps:find(cacerts, Config), maps:find(cacertfile, Config)} of
                    {{ok, Certs}, _} -> [{cacerts, Certs}];
                    {_, {ok, F}} -> [{cacertfile, F}];
                    _ -> [{cacerts, public_key:cacerts_get()}]
                end,
            [
                {verify, verify_peer},
                {customize_hostname_check, [
                    {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                ]}
                | CA ++ Base
            ]
    end.

tls_error(R) ->
    mailio_error:new(
        smtp_tls_failed,
        <<"TLS handshake with the SMTP server failed">>,
        #{reason => R, retryable => false}
    ).

ehlo(#c{config = Config} = C, Config) ->
    Name = maps:get(ehlo_name, Config, <<"localhost">>),
    {250, Text} = cmd(C, [<<"EHLO ">>, Name]),
    Caps = caps(Text),
    case {C#c.mod, maps:get(tls, Config, starttls)} of
        {gen_tcp, starttls} ->
            case has(Caps, <<"STARTTLS">>) of
                false ->
                    throw(
                        {mailio_smtp,
                            mailio_error:new(
                                smtp_tls_failed,
                                <<"the server does not offer STARTTLS">>,
                                #{}
                            )}
                    );
                true ->
                    ok
            end,
            {220, _} = cmd(C, [<<"STARTTLS">>]),
            ok = inet:setopts(C#c.sock, [{packet, raw}]),
            case ssl:connect(C#c.sock, ssl_opts(Config), ?TIMEOUT) of
                {ok, S} ->
                    ok = ssl:setopts(S, [{packet, line}]),
                    C2 = C#c{mod = ssl, sock = S},
                    {250, Text2} = cmd(C2, [<<"EHLO ">>, Name]),
                    {C2, caps(Text2)};
                {error, R} ->
                    throw({mailio_smtp, tls_error(R)})
            end;
        _ ->
            {C, Caps}
    end.

caps(Text) ->
    [string:uppercase(L) || L <- binary:split(Text, <<"\n">>, [global])].

has(Caps, Word) ->
    lists:any(fun(L) -> binary:match(L, Word) =/= nomatch end, Caps).

auth(C, Config, Caps) ->
    case maps:get(credentials, Config, undefined) of
        undefined -> C;
        Cred -> auth_with(C, force(Cred), Caps)
    end.

force({token_fun, F}) ->
    case F() of
        {ok, Cred} ->
            force(Cred);
        {error, R} ->
            throw(
                {mailio_smtp,
                    mailio_error:new(
                        smtp_auth_failed,
                        <<"credentials unavailable">>,
                        #{reason => R}
                    )}
            )
    end;
force(Cred) ->
    Cred.

auth_with(C, {oauth2, User, Token}, _Caps) ->
    Init = base64:encode(<<"user=", User/binary, 1, "auth=Bearer ", Token/binary, 1, 1>>),
    expect_auth(C, cmd(C, [<<"AUTH XOAUTH2 ">>, Init]));
auth_with(C, {password, User, Pass}, Caps) ->
    case has(Caps, <<"PLAIN">>) of
        true ->
            expect_auth(
                C,
                cmd(C, [
                    <<"AUTH PLAIN ">>,
                    base64:encode(<<0, User/binary, 0, Pass/binary>>)
                ])
            );
        false ->
            {334, _} = cmd(C, [<<"AUTH LOGIN">>]),
            {334, _} = cmd(C, [base64:encode(User)]),
            expect_auth(C, cmd(C, [base64:encode(Pass)]))
    end.

expect_auth(C, {235, _}) ->
    C;
expect_auth(_C, {334, _}) ->
    %% XOAUTH2 error challenge: the server wants an empty line, then fails.
    throw({mailio_smtp, mailio_error:new(smtp_auth_failed, <<"authentication failed">>, #{})});
expect_auth(_C, {Code, Text}) when Code >= 400, Code < 500 ->
    transient(auth_temporary, #{code => Code, reply => bin(Text)});
expect_auth(_C, {Code, Text}) ->
    throw(
        {mailio_smtp,
            mailio_error:new(
                smtp_auth_failed,
                <<"authentication failed">>,
                #{code => Code, reply => bin(Text)}
            )}
    ).

%%====================================================================
%% Envelope and message
%%====================================================================

session(C, From, Rcpts, Data) ->
    case cmd(C, [<<"MAIL FROM:<">>, From, <<">">>]) of
        {250, _} -> ok;
        {MC, MT} -> rejected_or_transient(C, mail_from, MC, MT, [])
    end,
    Results = [{R, cmd(C, [<<"RCPT TO:<">>, R, <<">">>])} || R <- Rcpts],
    Accepted = [R || {R, {Cd, _}} <- Results, Cd =:= 250 orelse Cd =:= 251],
    Rejected = [
        #{recipient => R, code => Cd, reply => bin(T)}
     || {R, {Cd, T}} <- Results, Cd =/= 250, Cd =/= 251
    ],
    case Accepted of
        [] ->
            _ = cmd_quiet(C, [<<"QUIT">>]),
            throw(
                {mailio_smtp,
                    mailio_error:new(
                        smtp_rejected,
                        <<"every recipient was refused">>,
                        #{stage => rcpt_to, rejected => Rejected}
                    )}
            );
        _ ->
            ok
    end,
    case cmd(C, [<<"DATA">>]) of
        {354, _} -> ok;
        {DC, DT} -> rejected_or_transient(C, data, DC, DT, Rejected)
    end,
    %% From here on a lost reply means the outcome is unknown.
    Body = stuff(iolist_to_binary(Data)),
    case send(C, [Body, <<".\r\n">>]) of
        ok -> ok;
        {error, R} -> throw({mailio_smtp, unknown(#{reason => {send, R}})})
    end,
    case read_reply_quiet(C) of
        {ok, {Code, Text}} when Code >= 200, Code < 300 ->
            _ = cmd_quiet(C, [<<"QUIT">>]),
            {ok, #{accepted => Accepted, rejected => Rejected, code => Code, reply => bin(Text)}};
        {ok, {Code, Text}} when Code >= 400, Code < 500 ->
            %% A 4xx after the dot means the server did not take the message.
            throw(
                {mailio_smtp,
                    mailio_error:new(
                        smtp_transient,
                        <<"the server deferred the message">>,
                        #{stage => data_end, code => Code, reply => bin(Text)}
                    )}
            );
        {ok, {Code, Text}} ->
            throw(
                {mailio_smtp,
                    mailio_error:new(
                        smtp_rejected,
                        <<"the server refused the message">>,
                        #{
                            stage => data_end,
                            code => Code,
                            reply => bin(Text),
                            rejected => Rejected
                        }
                    )}
            );
        {error, R2} ->
            throw({mailio_smtp, unknown(#{reason => {no_final_reply, R2}})})
    end.

-spec rejected_or_transient(#c{}, atom(), integer(), binary(), list()) -> no_return().
rejected_or_transient(_C, Stage, Code, Text, Rejected) when Code >= 400, Code < 500 ->
    throw(
        {mailio_smtp,
            mailio_error:new(
                smtp_transient,
                <<"the server deferred the request">>,
                #{
                    stage => Stage,
                    code => Code,
                    reply => bin(Text),
                    rejected => Rejected
                }
            )}
    );
rejected_or_transient(_C, Stage, Code, Text, Rejected) ->
    throw(
        {mailio_smtp,
            mailio_error:new(
                smtp_rejected,
                <<"the server refused the request">>,
                #{
                    stage => Stage,
                    code => Code,
                    reply => bin(Text),
                    rejected => Rejected
                }
            )}
    ).

unknown(Detail) ->
    mailio_error:new(
        smtp_outcome_unknown,
        <<
            "the connection ended after the message was sent and no final reply arrived; "
            "it may have been accepted"
        >>,
        Detail
    ).

-spec transient(atom(), map()) -> no_return().
transient(Stage, Detail) ->
    throw(
        {mailio_smtp,
            mailio_error:new(
                smtp_transient,
                <<"the request failed before the message was sent">>,
                Detail#{stage => Stage}
            )}
    ).

%% Normalize line endings and dot-stuff (RFC 5321 4.5.2).
stuff(Bin) ->
    Crlf = re:replace(Bin, <<"\r?\n">>, <<"\r\n">>, [global, {return, binary}]),
    Dots = re:replace(Crlf, <<"(?m)^\\.">>, <<"..">>, [global, {return, binary}]),
    case Dots of
        <<>> ->
            <<>>;
        _ ->
            case binary:longest_common_suffix([Dots, <<"\r\n">>]) of
                2 -> Dots;
                _ -> <<Dots/binary, "\r\n">>
            end
    end.

%%====================================================================
%% Wire
%%====================================================================

cmd(C, Parts) ->
    case send(C, [Parts, <<"\r\n">>]) of
        ok -> ok;
        {error, R} -> transient(send, #{reason => R})
    end,
    read_reply(C).

cmd_quiet(C, Parts) ->
    _ = send(C, [Parts, <<"\r\n">>]),
    read_reply_quiet(C).

send(#c{mod = M, sock = S}, Data) ->
    M:send(S, iolist_to_binary(Data)).

read_reply(C) ->
    case read_reply_quiet(C) of
        {ok, R} -> R;
        {error, R} -> transient(recv, #{reason => R})
    end.

read_reply_quiet(C) -> read_reply(C, []).

read_reply(#c{mod = M, sock = S} = C, Acc) ->
    case M:recv(S, 0, ?TIMEOUT) of
        {ok, Line} ->
            L = chomp(Line),
            case L of
                <<_:3/binary, $-, Rest/binary>> ->
                    read_reply(C, [Rest | Acc]);
                <<Code:3/binary, Rest/binary>> ->
                    try binary_to_integer(Code) of
                        N ->
                            {ok,
                                {N,
                                    iolist_to_binary(
                                        lists:join(
                                            <<"\n">>, lists:reverse([string:trim(Rest) | Acc])
                                        )
                                    )}}
                    catch
                        error:badarg -> {error, bad_reply}
                    end;
                _ ->
                    {error, bad_reply}
            end;
        {error, R} ->
            {error, R}
    end.

chomp(Bin) ->
    Sz = byte_size(Bin),
    case Sz > 0 andalso lists:member(binary:last(Bin), [$\r, $\n]) of
        true -> chomp(binary:part(Bin, 0, Sz - 1));
        false -> Bin
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

bin(B) when is_binary(B) -> B;
bin(L) -> iolist_to_binary(io_lib:format("~p", [L])).
