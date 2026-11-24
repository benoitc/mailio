%%% @doc POP3 client (RFC 1939, with CAPA, UIDL, TOP, STLS and the XOAUTH2
%%% SASL mechanism).
%%%
%%% This is the protocol only: connect, authenticate, list, identify, fetch
%%% headers or the whole message. It never sends DELE, so a caller cannot
%%% remove mail from the server by accident, and it keeps no index.
%%%
%%% Message identity: UIDL when the server has it. A server may repeat one
%%% UIDL for identical copies, so {@link unique_ids/1} gives repeated ids an
%%% ordinal suffix. Without UIDL the functions return `pop3_unsupported' and
%%% the caller decides on another identity (for example a hash of the
%%% headers and size).
%%%
%%% Headers: TOP when the server has it; otherwise {@link headers/4} falls
%%% back to RETR for messages up to `max_retr' bytes and refuses larger ones.
%%%
%%% Config: `#{host, port, tls => true | starttls | false, verify =>
%%% verify_peer | verify_none, cacerts | cacertfile, credentials}'. TLS
%%% certificates and host names are verified unless `verify' says otherwise.
-module(mailio_pop3).

-export([open/1, close/1, capabilities/1]).
-export([stat/1, list/1, uidl/1, top/3, retr/3, headers/4]).
-export([unique_ids/1]).

-export_type([conn/0]).

-define(TIMEOUT, 30000).
%% Largest multi-line reply accepted, per command. The message size for RETR
%% comes from the caller. Overridable in the config with `max_list_bytes' and
%% `max_top_bytes'.
-define(MAX_LIST_BYTES, 33554432).
-define(MAX_TOP_BYTES, 1048576).
-define(MAX_LINE_BYTES, 65536).
-define(RETR_SLACK, 65536).

-opaque conn() :: #{mod := gen_tcp | ssl, sock := term(), caps := [binary()], config := map()}.

%%====================================================================
%% Connection
%%====================================================================

-spec open(map()) -> {ok, conn()} | mailio_error:t().
open(#{host := Host} = Config) ->
    try
        Port = maps:get(port, Config, default_port(maps:get(tls, Config, starttls))),
        {Mod, Sock} = connect(to_list(Host), Port, Config),
        C0 = #{mod => Mod, sock => Sock, caps => [], config => Config},
        {ok, <<"+OK", _/binary>>} = read_line(C0),
        C1 = refresh_caps(C0),
        C2 = stls(C1),
        C3 = auth(C2),
        {ok, refresh_caps(C3)}
    catch
        throw:{mailio_pop3, Error} ->
            Error;
        error:{badmatch, _} ->
            mailio_error:new(
                pop3_connect_failed, <<"unexpected greeting from the POP3 server">>, #{}
            )
    end.

default_port(true) -> 995;
default_port(_) -> 110.

-spec close(conn()) -> ok.
close(#{mod := M, sock := S} = C) ->
    _ = (catch_all(fun() -> send(C, [<<"QUIT">>]) end)),
    _ = M:close(S),
    ok.

-spec capabilities(conn()) -> [binary()].
capabilities(#{caps := Caps}) -> Caps.

connect(Host, Port, Config) ->
    case maps:get(tls, Config, starttls) of
        true ->
            case ssl:connect(Host, Port, ssl_opts(Config, Host) ++ sock_opts(Config), ?TIMEOUT) of
                {ok, S} -> {ssl, S};
                {error, R} -> fail(tls_failed(R))
            end;
        _ ->
            case gen_tcp:connect(Host, Port, sock_opts(Config), ?TIMEOUT) of
                {ok, S} ->
                    {gen_tcp, S};
                {error, R} ->
                    fail(
                        mailio_error:new(
                            pop3_connect_failed,
                            <<"cannot connect to the POP3 server">>,
                            #{reason => R}
                        )
                    )
            end
    end.

sock_opts(Config) ->
    [
        {active, false},
        binary,
        {packet, line},
        {packet_size, maps:get(max_line_bytes, Config, ?MAX_LINE_BYTES)}
    ].

ssl_opts(Config, Host) ->
    Base = [{server_name_indication, Host}, {versions, ['tlsv1.3', 'tlsv1.2']}],
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

tls_failed(R) ->
    mailio_error:new(pop3_tls_failed, <<"TLS handshake with the POP3 server failed">>, #{
        reason => R
    }).

refresh_caps(C) ->
    case cmd_multi(C, [<<"CAPA">>], limit(C, list)) of
        {ok, Lines} ->
            C#{caps => [string:uppercase(hd(binary:split(L, <<" ">>))) || L <- Lines]};
        {err, _} ->
            C#{caps => []}
    end.

stls(#{mod := gen_tcp, config := Config} = C) ->
    case maps:get(tls, Config, starttls) of
        starttls ->
            case lists:member(<<"STLS">>, maps:get(caps, C)) of
                false ->
                    fail(
                        mailio_error:new(pop3_tls_failed, <<"the server does not offer STLS">>, #{})
                    );
                true ->
                    ok
            end,
            {ok, _} = cmd(C, [<<"STLS">>]),
            ok = inet:setopts(maps:get(sock, C), [{packet, raw}]),
            Host = to_list(maps:get(host, Config)),
            case ssl:connect(maps:get(sock, C), ssl_opts(Config, Host), ?TIMEOUT) of
                {ok, S} ->
                    ok = ssl:setopts(S, [
                        {packet, line},
                        {packet_size, maps:get(max_line_bytes, Config, ?MAX_LINE_BYTES)}
                    ]),
                    refresh_caps(C#{mod := ssl, sock := S});
                {error, R} ->
                    fail(tls_failed(R))
            end;
        _ ->
            C
    end;
stls(C) ->
    C.

auth(#{config := Config} = C) ->
    case maps:get(credentials, Config, undefined) of
        undefined -> C;
        Cred -> auth_with(C, force(Cred))
    end.

force({token_fun, F}) ->
    case F() of
        {ok, Cred} ->
            force(Cred);
        {error, _Reason} ->
            fail(mailio_error:new(pop3_auth_failed, <<"credentials unavailable">>, #{}))
    end;
force(Cred) ->
    Cred.

auth_with(C, {password, User, Pass}) ->
    case cmd(C, [<<"USER ">>, User]) of
        {ok, _} ->
            case cmd(C, [<<"PASS ">>, Pass]) of
                {ok, _} -> C;
                {err, T} -> fail(auth_failed(T))
            end;
        {err, T} ->
            fail(auth_failed(T))
    end;
auth_with(C, {oauth2, User, Token}) ->
    Init = base64:encode(<<"user=", User/binary, 1, "auth=Bearer ", Token/binary, 1, 1>>),
    ok = send(C, [<<"AUTH XOAUTH2 ">>, Init]),
    case read_line(C) of
        {ok, <<"+OK", _/binary>>} ->
            C;
        {ok, <<"+ ", _/binary>>} ->
            %% error challenge: finish the exchange with an empty line
            ok = send(C, [<<>>]),
            _ = read_line(C),
            fail(auth_failed(<<"XOAUTH2 refused">>));
        {ok, Other} ->
            fail(auth_failed(Other))
    end.

auth_failed(Text) ->
    mailio_error:new(pop3_auth_failed, <<"authentication failed">>, #{reply => Text}).

%%====================================================================
%% Commands
%%====================================================================

-spec stat(conn()) -> {ok, non_neg_integer(), non_neg_integer()} | mailio_error:t().
stat(C) ->
    wrap(fun() ->
        case cmd(C, [<<"STAT">>]) of
            {ok, T} ->
                [N, O | _] = binary:split(T, <<" ">>, [global]),
                {ok, binary_to_integer(N), binary_to_integer(O)};
            {err, T} ->
                server_error(T)
        end
    end).

-spec list(conn()) -> {ok, [{pos_integer(), non_neg_integer()}]} | mailio_error:t().
list(C) ->
    wrap(fun() ->
        case cmd_multi(C, [<<"LIST">>], limit(C, list)) of
            {ok, Lines} ->
                {ok, [
                    {binary_to_integer(N), binary_to_integer(S)}
                 || L <- Lines, [N, S | _] <- [binary:split(L, <<" ">>, [global])]
                ]};
            {err, T} ->
                server_error(T)
        end
    end).

%% @doc Unique-id listing. `pop3_unsupported' when the server has no UIDL.
-spec uidl(conn()) -> {ok, [{pos_integer(), binary()}]} | mailio_error:t().
uidl(C) ->
    wrap(fun() ->
        case cmd_multi(C, [<<"UIDL">>], limit(C, list)) of
            {ok, Lines} ->
                {ok, [
                    {binary_to_integer(N), U}
                 || L <- Lines, [N, U | _] <- [binary:split(L, <<" ">>)]
                ]};
            {err, _} ->
                mailio_error:new(pop3_unsupported, <<"the server has no UIDL">>, #{
                    command => <<"UIDL">>
                })
        end
    end).

%% @doc The headers and the first `Lines' lines of the body. The message is
%% left on the server.
-spec top(conn(), pos_integer(), non_neg_integer()) -> {ok, binary()} | mailio_error:t().
top(C, N, Lines) ->
    wrap(fun() ->
        case
            cmd_multi(
                C,
                [<<"TOP ">>, integer_to_binary(N), <<" ">>, integer_to_binary(Lines)],
                limit(C, top)
            )
        of
            {ok, L} -> {ok, join(L)};
            {err, T} -> top_error(T)
        end
    end).

top_error(T) ->
    case binary:match(string:lowercase(T), [<<"no such">>, <<"not found">>, <<"invalid">>]) of
        nomatch ->
            mailio_error:new(pop3_unsupported, <<"the server has no TOP">>, #{
                command => <<"TOP">>, reply => T
            });
        _ ->
            mailio_error:new(pop3_no_such_message, <<"no such message">>, #{reply => T})
    end.

%% @doc The whole message, refused when its size exceeds `MaxBytes'.
-spec retr(conn(), pos_integer(), pos_integer()) -> {ok, binary()} | mailio_error:t().
retr(C, N, MaxBytes) ->
    wrap(fun() ->
        case list_one(C, N) of
            {ok, Size} when Size > MaxBytes ->
                mailio_error:new(
                    pop3_too_large,
                    <<"the message is larger than the limit">>,
                    #{size => Size, limit => MaxBytes}
                );
            {ok, _} ->
                case cmd_multi(C, [<<"RETR ">>, integer_to_binary(N)], MaxBytes + ?RETR_SLACK) of
                    {ok, L} ->
                        {ok, join(L)};
                    {err, T} ->
                        mailio_error:new(pop3_no_such_message, <<"no such message">>, #{reply => T})
                end;
            {err, T} ->
                mailio_error:new(pop3_no_such_message, <<"no such message">>, #{reply => T})
        end
    end).

list_one(C, N) ->
    case cmd(C, [<<"LIST ">>, integer_to_binary(N)]) of
        {ok, T} ->
            [_, S | _] = binary:split(T, <<" ">>, [global]),
            {ok, binary_to_integer(S)};
        {err, _} = E ->
            E
    end.

%% @doc Headers of a message: TOP when the server has it, else RETR when the
%% message is at most `max_retr' bytes (default 2 MiB), cut at the blank line.
-spec headers(conn(), pos_integer(), non_neg_integer(), map()) -> {ok, binary()} | mailio_error:t().
headers(C, N, Size, Opts) ->
    case lists:member(<<"TOP">>, capabilities(C)) of
        true ->
            top(C, N, 0);
        false ->
            case top(C, N, 0) of
                {ok, _} = Ok ->
                    Ok;
                {error, #{code := pop3_unsupported}} ->
                    Max = maps:get(max_retr, Opts, 2097152),
                    case Size =< Max of
                        true ->
                            case retr(C, N, Max) of
                                {ok, Raw} ->
                                    [H | _] = binary:split(Raw, <<"\r\n\r\n">>),
                                    {ok, H};
                                Error ->
                                    Error
                            end;
                        false ->
                            mailio_error:new(
                                pop3_too_large,
                                <<"no TOP, and the message is too large to fetch">>,
                                #{size => Size, limit => Max}
                            )
                    end;
                Error ->
                    Error
            end
    end.

%% @doc Give repeated ids an ordinal suffix so identical copies stay distinct.
-spec unique_ids([{pos_integer(), binary()}]) -> [{pos_integer(), binary()}].
unique_ids(Pairs) ->
    {Out, _} = lists:mapfoldl(
        fun({N, U}, Seen) ->
            K = maps:get(U, Seen, 0),
            Id =
                case K of
                    0 -> U;
                    _ -> <<U/binary, "#", (integer_to_binary(K))/binary>>
                end,
            {{N, Id}, Seen#{U => K + 1}}
        end,
        #{},
        Pairs
    ),
    Out.

%%====================================================================
%% Wire
%%====================================================================

wrap(Fun) ->
    try
        Fun()
    catch
        throw:{mailio_pop3, Error} -> Error
    end.

-spec fail(mailio_error:t()) -> no_return().
fail(Error) -> throw({mailio_pop3, Error}).

server_error(T) ->
    mailio_error:new(pop3_error, <<"the server refused the command">>, #{reply => T}).

send(#{mod := M, sock := S}, Parts) ->
    case M:send(S, iolist_to_binary([Parts, <<"\r\n">>])) of
        ok -> ok;
        {error, R} -> fail(disconnected(R))
    end.

disconnected(R) ->
    mailio_error:new(pop3_disconnected, <<"the connection to the POP3 server was lost">>, #{
        reason => R
    }).

read_line(#{mod := M, sock := S}) ->
    case M:recv(S, 0, ?TIMEOUT) of
        {ok, L} ->
            {ok, chomp(L)};
        {error, emsgsize} ->
            fail(
                mailio_error:new(
                    pop3_response_too_large,
                    <<"the POP3 reply line is larger than the limit">>,
                    #{}
                )
            );
        {error, timeout} ->
            fail(mailio_error:new(pop3_timeout, <<"the POP3 server did not answer in time">>, #{}));
        {error, R} ->
            fail(disconnected(R))
    end.

cmd(C, Parts) ->
    ok = send(C, Parts),
    case read_line(C) of
        {ok, <<"+OK", Rest/binary>>} -> {ok, string:trim(Rest)};
        {ok, <<"-ERR", Rest/binary>>} -> {err, string:trim(Rest)};
        {ok, Other} -> {err, Other}
    end.

cmd_multi(C, Parts, Max) ->
    case cmd(C, Parts) of
        {ok, _} -> {ok, read_multi(C, [], 0, Max)};
        {err, _} = E -> E
    end.

limit(#{config := Config}, list) -> maps:get(max_list_bytes, Config, ?MAX_LIST_BYTES);
limit(#{config := Config}, top) -> maps:get(max_top_bytes, Config, ?MAX_TOP_BYTES).

%% Multi-line reply ended by a lone dot; dot-unstuffed. A reply that grows
%% past `Max' bytes ends the connection.
read_multi(C, Acc, Bytes, Max) ->
    {ok, L} = read_line(C),
    Bytes1 = Bytes + byte_size(L) + 2,
    case Bytes1 > Max of
        true ->
            close(C),
            fail(
                mailio_error:new(
                    pop3_response_too_large,
                    <<"the POP3 reply is larger than the limit">>,
                    #{limit => Max}
                )
            );
        false ->
            case L of
                <<".">> -> lists:reverse(Acc);
                <<"..", R/binary>> -> read_multi(C, [<<".", R/binary>> | Acc], Bytes1, Max);
                _ -> read_multi(C, [L | Acc], Bytes1, Max)
            end
    end.

join(Lines) -> iolist_to_binary(lists:join(<<"\r\n">>, Lines)).

chomp(Bin) ->
    Sz = byte_size(Bin),
    case Sz > 0 andalso lists:member(binary:last(Bin), [$\r, $\n]) of
        true -> chomp(binary:part(Bin, 0, Sz - 1));
        false -> Bin
    end.

catch_all(F) ->
    try
        F()
    catch
        _:_ -> ok
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
