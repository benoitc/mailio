%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
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

-define(MAX_REPLY_LINES, 100).
-define(MAX_REPLY_LINE, 4096).
-define(MAX_REPLY_BYTES, 65536).
-define(TIMEOUT, 30000).
-define(TRACKED, mailio_smtp_submit).
-define(BODY_SENT, mailio_smtp_body_sent).

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
submit(_Config, _From, [], _Data) ->
    %% nothing to send to: no connection is made, and a retry would be the same
    mailio_error:new(smtp_rejected, <<"there is no recipient">>, #{stage => rcpt_to, rejected => []});
submit(Config, From, Rcpts, Data) ->
    try
        %% a setting that is not understood must not end up as plain text
        lists:member(maps:get(tls, Config, starttls), [true, starttls, false]) orelse
            throw(
                {mailio_smtp,
                    mailio_error:new(smtp_tls_failed, <<"the tls setting is not understood">>, #{})}
            ),
        C0 = track(connect(Config)),
        greeting(C0),
        {C1, Caps} = ehlo(C0, Config),
        C2 = auth(track(C1), Config, Caps),
        session(C2, From, Rcpts, Data)
    catch
        throw:{mailio_smtp, Error} ->
            Error;
        error:{badmatch, {Code, Text}} when is_integer(Code) ->
            unexpected(#{code => Code, reply => bin(Text)});
        Class:_Reason ->
            %% Whatever else goes wrong is an error value too, and says only what
            %% kind it was: no detail of the server's data goes into it
            unexpected(#{class => Class})
    after
        erase(?BODY_SENT),
        release()
    end.

%% After the message was sent a lost answer means the outcome is unknown; before
%% it nothing was submitted, so a retry is safe.
unexpected(Detail) ->
    case get(?BODY_SENT) of
        true ->
            unknown(Detail);
        _ ->
            try
                transient(unexpected_reply, Detail)
            catch
                throw:{mailio_smtp, Error} -> Error
            end
    end.

%% A service that is not ready says so with 4yz (try later) or 5yz (not for us, as
%% 554 does): only the first is worth a retry.
greeting(C) ->
    case read_reply(C) of
        {220, _} -> ok;
        {Code, Text} -> rejected_or_transient(C, greeting, Code, Text, [])
    end.

%% The newest connection of a submission in progress. Whatever ends the call,
%% its socket is closed here: a failed TLS upgrade leaves the plain socket
%% open, and a finished session never closed it.
track(C) ->
    put(?TRACKED, C),
    C.

release() ->
    case erase(?TRACKED) of
        #c{mod = M, sock = S} -> catch_all(fun() -> M:close(S) end);
        undefined -> ok
    end.

catch_all(F) ->
    try
        F()
    catch
        _:_ -> ok
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

sock_opts() -> [{active, false}, binary, {packet, line}, {packet_size, ?MAX_REPLY_LINE}].

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
    Text = read_ehlo(C, Name),
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
                    ok = ssl:setopts(S, [{packet, line}, {packet_size, ?MAX_REPLY_LINE}]),
                    C2 = C#c{mod = ssl, sock = S},
                    {C2, caps(read_ehlo(track(C2), Name))};
                {error, R} ->
                    throw({mailio_smtp, tls_error(R)})
            end;
        _ ->
            {C, Caps}
    end.

%% EHLO and what the server answers: 250, or a 4yz that asks for a retry, or a
%% refusal that retrying does not change (RFC 5321, section 4.2.1).
read_ehlo(C, Name) ->
    case cmd(C, [<<"EHLO ">>, Name]) of
        {250, Text} -> Text;
        {Code, Reply} -> rejected_or_transient(C, ehlo, Code, Reply, [])
    end.

caps(Text) ->
    [string:uppercase(L) || L <- binary:split(Text, <<"\n">>, [global])].

has(Caps, Word) ->
    lists:any(fun(L) -> binary:match(L, Word) =/= nomatch end, Caps).

auth(C, Config, Caps) ->
    case maps:get(credentials, Config, undefined) of
        undefined ->
            C;
        Cred ->
            case mailio_credentials:resolve(Cred, cred_opts(Config)) of
                {ok, Resolved} ->
                    auth_with(C, Resolved, Caps);
                {error, _Why} ->
                    %% the provider's own words may hold a secret: not repeated
                    throw(
                        {mailio_smtp,
                            mailio_error:new(
                                smtp_auth_failed,
                                <<"credentials unavailable">>,
                                #{}
                            )}
                    )
            end
    end.

cred_opts(#{credentials_timeout := T}) -> #{timeout => T};
cred_opts(_) -> #{}.

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
            %% Every recipient answered 4yz: the server asks for a retry (RFC 5321,
            %% section 4.2.1), and nothing was submitted. Only refusals that are all
            %% permanent are a rejection.
            case lists:all(fun(#{code := Cd}) -> Cd >= 400 andalso Cd < 500 end, Rejected) of
                true ->
                    throw(
                        {mailio_smtp,
                            mailio_error:new(
                                smtp_transient,
                                <<"the server deferred every recipient">>,
                                #{stage => rcpt_to, rejected => Rejected}
                            )}
                    );
                false ->
                    throw(
                        {mailio_smtp,
                            mailio_error:new(
                                smtp_rejected,
                                <<"every recipient was refused">>,
                                #{stage => rcpt_to, rejected => Rejected}
                            )}
                    )
            end;
        _ ->
            ok
    end,
    case cmd(C, [<<"DATA">>]) of
        {354, _} -> ok;
        {DC, DT} -> rejected_or_transient(C, data, DC, DT, Rejected)
    end,
    %% From here on a lost reply means the outcome is unknown.
    put(?BODY_SENT, true),
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

read_reply_quiet(C) -> read_reply(C, [], 0).

%% A reply is at most ?MAX_REPLY_LINES lines, ?MAX_REPLY_LINE bytes a line and
%% ?MAX_REPLY_BYTES bytes in all: a server cannot make us buffer without bound.
read_reply(_C, Acc, _Bytes) when length(Acc) >= ?MAX_REPLY_LINES ->
    {error, reply_too_large};
read_reply(#c{mod = M, sock = S} = C, Acc, Bytes) ->
    case M:recv(S, 0, ?TIMEOUT) of
        {ok, Line} when byte_size(Line) > ?MAX_REPLY_LINE ->
            {error, reply_too_large};
        {ok, Line} ->
            L = chomp(Line),
            Bytes1 = Bytes + byte_size(Line),
            case Bytes1 > ?MAX_REPLY_BYTES of
                true ->
                    {error, reply_too_large};
                false ->
                    case L of
                        <<_:3/binary, $-, Rest/binary>> ->
                            read_reply(C, [Rest | Acc], Bytes1);
                        <<Code:3/binary, Rest/binary>> ->
                            try binary_to_integer(Code) of
                                N ->
                                    {ok,
                                        {N,
                                            iolist_to_binary(
                                                lists:join(
                                                    <<"\n">>,
                                                    lists:reverse([string:trim(Rest) | Acc])
                                                )
                                            )}}
                            catch
                                error:badarg -> {error, bad_reply}
                            end;
                        _ ->
                            {error, bad_reply}
                    end
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
