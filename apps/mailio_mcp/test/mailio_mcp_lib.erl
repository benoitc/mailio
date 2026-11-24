%%% Test helpers: GreenMail seeding, a flaky SMTP server, app start/stop and
%%% an MCP client wrapper that records tool calls, response bytes and
%%% backend requests.
-module(mailio_mcp_lib).

-export([
    reachable/1,
    acct/4, acct/5,
    start_app/3,
    stop_app/0,
    msg/1,
    append/5,
    imap_conn/1,
    imap_flags/2,
    imap_cmd/2,
    imap_uids/1,
    smtp_send/3,
    start_http/0,
    stop_http/0,
    client/1,
    call/3, call/4,
    log/0,
    log_reset/0,
    fake_smtp/1,
    fake_smtp_stop/1,
    fake_smtp_data_count/1,
    gm_count/2
]).

reachable(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary], 500) of
        {ok, S} ->
            gen_tcp:close(S),
            true;
        _ ->
            false
    end.

%%--------------------------------------------------------------------
%% Accounts

acct(Id, Login, Idents, Extra) -> acct(Id, Login, Idents, Extra, #{}).
acct(Id, Login, Idents, Extra, Over) ->
    Base = #{
        id => Id,
        name => Id,
        incoming => #{protocol => imap, host => "127.0.0.1", port => 3143, tls => none},
        outgoing => #{host => "127.0.0.1", port => 3025, tls => none},
        auth => #{user => Login, secret => {value, <<"secret">>}, mechanism => login},
        identities => [#{address => A, name => N} || {A, N} <- Idents]
    },
    maps:merge(maps:merge(Base, Extra), Over).

start_app(Dir, Accounts, Principals) ->
    application:load(mailio_mcp),
    application:set_env(mailio_mcp, data_dir, Dir),
    application:set_env(mailio_mcp, accounts, Accounts),
    case Principals of
        undefined -> application:unset_env(mailio_mcp, principals);
        _ -> application:set_env(mailio_mcp, principals, Principals)
    end,
    {ok, _} = application:ensure_all_started(mailio_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

stop_app() ->
    application:stop(mailio_mcp),
    ok.

%%--------------------------------------------------------------------
%% Message building and seeding

msg(#{from := From, to := To, subject := Subj} = M) ->
    Hdrs =
        [
            {<<"From">>, From},
            {<<"To">>, To},
            {<<"Subject">>, Subj},
            {<<"Message-ID">>, maps:get(msgid, M, <<"<", (rand())/binary, "@example.test>">>)},
            {<<"Date">>, maps:get(date, M, <<"Mon, 23 Nov 2026 10:00:00 +0100">>)}
        ] ++
            [{<<"In-Reply-To">>, V} || V <- [maps:get(in_reply_to, M, undefined)], V =/= undefined] ++
            [{<<"References">>, V} || V <- [maps:get(references, M, undefined)], V =/= undefined] ++
            [{<<"Cc">>, V} || V <- [maps:get(cc, M, undefined)], V =/= undefined],
    Body = maps:get(body, M, <<"Hello.\r\n">>),
    AllHdrs = Hdrs ++ [{<<"MIME-Version">>, <<"1.0">>}],
    Text = #{
        type => <<"text">>,
        subtype => <<"plain">>,
        charset => <<"utf-8">>,
        encoding => <<"7bit">>,
        body => Body
    },
    case maps:get(attachment, M, undefined) of
        undefined ->
            mailio_mime_render:render(Text#{headers => AllHdrs});
        {Name, Type, Bytes} ->
            [T1, T2] = binary:split(Type, <<"/">>),
            Att = #{
                type => T1,
                subtype => T2,
                params => #{<<"name">> => Name},
                encoding => <<"base64">>,
                disposition => <<"attachment">>,
                filename => Name,
                body => Bytes
            },
            mailio_mime_render:render(#{
                type => <<"multipart">>,
                subtype => <<"mixed">>,
                headers => AllHdrs,
                parts => [Text, Att]
            })
    end.

rand() -> binary:encode_hex(crypto:strong_rand_bytes(6), lowercase).

imap_conn(Login) ->
    Acc = #{
        id => <<"t">>,
        incoming => #{host => "127.0.0.1", port => 3143, tls => none, protocol => imap},
        auth => #{
            user => iolist_to_binary(Login), secret => {value, <<"secret">>}, mechanism => login
        }
    },
    {ok, C} = mailio_mcp_imap_io:open(Acc),
    C.

%% Append with an explicit internal date ("29-Mar-2026 23:59:00 +0200") and flags.
append(Login, Box, Date, Flags, Raw) ->
    C = imap_conn(Login),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C, [
        <<"APPEND ">>,
        Box,
        <<" (">>,
        Flags,
        <<") \"">>,
        Date,
        <<"\" ">>,
        {literal, iolist_to_binary(Raw)}
    ]),
    mailio_mcp_imap_io:close(C),
    ok.

imap_cmd(Login, Parts) ->
    C = imap_conn(Login),
    R = mailio_mcp_imap_io:cmd(C, Parts),
    mailio_mcp_imap_io:close(C),
    R.

%% FLAGS of one UID in a mailbox, read with EXAMINE.
imap_flags(Login, Uid) ->
    C = imap_conn(Login),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C, [<<"EXAMINE INBOX">>]),
    {ok, U, _} = mailio_mcp_imap_io:cmd(C, [
        <<"UID FETCH ">>, integer_to_binary(Uid), <<" (FLAGS)">>
    ]),
    mailio_mcp_imap_io:close(C),
    case [Items || {fetch, _, Items} <- U] of
        [Items | _] -> [string:lowercase(F) || F <- proplists:get_value(flags, Items, [])];
        [] -> missing
    end.

imap_uids(Login) ->
    C = imap_conn(Login),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C, [<<"EXAMINE INBOX">>]),
    {ok, U, _} = mailio_mcp_imap_io:cmd(C, [<<"UID SEARCH ALL">>]),
    mailio_mcp_imap_io:close(C),
    lists:sort(lists:append([Uids || {search, Uids} <- U])).

gm_count(Login, Box) ->
    C = imap_conn(Login),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C, [<<"EXAMINE ">>, Box]),
    {ok, U, _} = mailio_mcp_imap_io:cmd(C, [<<"UID SEARCH ALL">>]),
    mailio_mcp_imap_io:close(C),
    length(lists:append([Uids || {search, Uids} <- U])).

smtp_send(From, To, Raw) ->
    {ok, _} = mailio_smtp:submit(
        #{host => <<"127.0.0.1">>, port => 3025, tls => false},
        From,
        [To],
        Raw
    ),
    ok.

%%--------------------------------------------------------------------
%% HTTP server and MCP client

-define(PORT, 18420).

start_http() ->
    Verifier = fun(Token) ->
        case Token of
            <<"tok-", Sub/binary>> -> {ok, #{<<"sub">> => Sub}};
            _ -> {error, invalid_token}
        end
    end,
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => ?PORT,
        auth => #{
            provider => barrel_mcp_auth_bearer,
            provider_opts => #{verifier => Verifier, audience => any}
        }
    }),
    ok.

stop_http() -> barrel_mcp:stop_http_stream().

client(Subject) ->
    {ok, C} = barrel_mcp_client:start_link(#{
        transport =>
            {http, iolist_to_binary(["http://127.0.0.1:", integer_to_list(?PORT), "/mcp"])},
        auth => {bearer, <<"tok-", Subject/binary>>},
        request_timeout => 60000
    }),
    wait_ready(C, 50),
    C.

wait_ready(_, 0) ->
    error(client_not_ready);
wait_ready(C, N) ->
    case barrel_mcp_client:server_capabilities(C) of
        {ok, _} ->
            ok;
        _ ->
            timer:sleep(100),
            wait_ready(C, N - 1)
    end.

%% Call a tool as the MCP client. Returns {ok, Map} | {error, Text}.
%% Every call is logged with its response size and backend request counts.
call(C, Name, Args) -> call(C, Name, Args, #{}).
call(C, Name, Args, _Opts) ->
    mailio_mcp_stats:reset(),
    T0 = erlang:monotonic_time(millisecond),
    R = barrel_mcp_client:call_tool(C, Name, Args),
    Ms = erlang:monotonic_time(millisecond) - T0,
    Stats = mailio_mcp_stats:snapshot(),
    {Out, Bytes} = decode(R),
    ets_log({Name, Args, Bytes, summary(Stats), Ms, Out}),
    Out.

decode({ok, #{<<"content">> := [#{<<"text">> := T} | _]} = Res}) ->
    Bytes = byte_size(T),
    case maps:get(<<"isError">>, Res, false) of
        true ->
            {{error, T}, Bytes};
        false ->
            {
                {ok,
                    try
                        json:decode(T)
                    catch
                        _:_ -> T
                    end},
                Bytes
            }
    end;
decode(Other) ->
    {{error, Other}, 0}.

summary(Stats) ->
    maps:fold(
        fun
            ({_Acc, Kind, req}, V, A) ->
                maps:update_with(Kind, fun(X) -> X + V end, V, A);
            ({_Acc, Kind, bytes}, V, A) ->
                maps:update_with({Kind, bytes}, fun(X) -> X + V end, V, A)
        end,
        #{},
        Stats
    ).

ets_log(Entry) ->
    case ets:whereis(mcp_log) of
        undefined -> ets:new(mcp_log, [named_table, public, ordered_set]);
        _ -> ok
    end,
    ets:insert(mcp_log, {erlang:unique_integer([monotonic]), Entry}).

log() -> [E || {_, E} <- ets:tab2list(mcp_log)].
log_reset() ->
    case ets:whereis(mcp_log) of
        undefined ->
            ok;
        _ ->
            ets:delete_all_objects(mcp_log),
            ok
    end.

%%--------------------------------------------------------------------
%% Fake SMTP server. Mode `drop_after_data' reads the whole message and
%% closes the connection without the final reply. Mode `ok' accepts.

fake_smtp(Mode) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {packet, line}]),
    {ok, Port} = inet:port(L),
    Counter = counters:new(2, []),
    Pid = spawn_link(fun() -> accept_loop(L, Mode, Counter) end),
    #{listen => L, port => Port, pid => Pid, counter => Counter}.

fake_smtp_stop(#{listen := L, pid := P}) ->
    unlink(P),
    exit(P, kill),
    gen_tcp:close(L),
    ok.

fake_smtp_data_count(#{counter := C}) -> counters:get(C, 1).

accept_loop(L, Mode, Counter) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            spawn(fun() -> session(S, Mode, Counter) end),
            accept_loop(L, Mode, Counter);
        _ ->
            ok
    end.

session(S, Mode, Counter) ->
    send(S, "220 fake ESMTP\r\n"),
    loop(S, Mode, Counter).

send(S, D) -> gen_tcp:send(S, D).

loop(S, Mode, Counter) ->
    case gen_tcp:recv(S, 0, 10000) of
        {ok, Line} ->
            U = string:uppercase(binary_to_list(Line)),
            case U of
                "EHLO" ++ _ ->
                    send(S, "250-fake\r\n250 AUTH PLAIN LOGIN\r\n"),
                    loop(S, Mode, Counter);
                "AUTH" ++ _ ->
                    send(S, "235 ok\r\n"),
                    loop(S, Mode, Counter);
                "MAIL" ++ _ ->
                    send(S, "250 ok\r\n"),
                    loop(S, Mode, Counter);
                "RCPT" ++ _ ->
                    send(S, "250 ok\r\n"),
                    loop(S, Mode, Counter);
                "DATA" ++ _ ->
                    send(S, "354 go\r\n"),
                    read_data(S),
                    counters:add(Counter, 1, 1),
                    case Mode of
                        drop_after_data ->
                            gen_tcp:close(S);
                        ok ->
                            send(S, "250 2.0.0 queued as FAKE1\r\n"),
                            loop(S, Mode, Counter)
                    end;
                "QUIT" ++ _ ->
                    send(S, "221 bye\r\n"),
                    gen_tcp:close(S);
                _ ->
                    send(S, "250 ok\r\n"),
                    loop(S, Mode, Counter)
            end;
        _ ->
            ok
    end.

read_data(S) ->
    case gen_tcp:recv(S, 0, 10000) of
        {ok, <<".\r\n">>} -> ok;
        {ok, _} -> read_data(S);
        _ -> ok
    end.
