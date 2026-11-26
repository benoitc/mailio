%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% An IMAP connection is protected unless it is said not to be, and a server that
%%% greets with PREAUTH is not a way around that (RFC 9051, section 7.1.4).
-module(mailio_imap_tls_default_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%% A one-connection server: `Greeting', then every command it receives is logged
%% and answered by `Answer(Tag)'.
serve(Greeting, Answer) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Log = ets:new(log, [public, ordered_set]),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        ok = gen_tcp:send(S, Greeting),
        loop(S, Log, Answer)
    end),
    {Port, Log, L}.

loop(S, Log, Answer) ->
    case gen_tcp:recv(S, 0, 1500) of
        {ok, Cmd} ->
            ets:insert(Log, {erlang:unique_integer([monotonic]), Cmd}),
            [Tag | _] = binary:split(Cmd, <<" ">>),
            gen_tcp:send(S, Answer(Tag, Cmd)),
            loop(S, Log, Answer);
        {error, _} ->
            ok
    end.

ok_all(Tag, Cmd) ->
    case binary:match(Cmd, <<"CAPABILITY">>) of
        nomatch -> [Tag, <<" OK done\r\n">>];
        _ -> [<<"* CAPABILITY IMAP4rev1\r\n">>, Tag, <<" OK done\r\n">>]
    end.

sent(Log) -> [C || {_, C} <- ets:tab2list(Log)].

noop(C) ->
    mailio_imap_conn:run(C, fun(Tag) -> {[Tag, <<" NOOP\r\n">>], undefined} end, 3000).

start(Port, Extra) ->
    {ok, C} = mailio_imap_conn:start_link(
        maps:merge(
            #{host => <<"127.0.0.1">>, port => Port, credentials => {password, <<"u">>, <<"p">>}},
            Extra
        )
    ),
    C.

%% No `tls' in the config: the connection asks for STARTTLS before any password
%% is sent, and a server that does not offer it is not sent one.
the_default_is_starttls_test() ->
    {Port, Log, L} = serve(<<"* OK ready\r\n">>, fun(Tag, _) -> [Tag, <<" NO no starttls\r\n">>] end),
    C = start(Port, #{}),
    ?assertEqual({error, tls_failed}, noop(C)),
    ?assertNot(lists:any(fun(S) -> binary:match(S, <<"LOGIN">>) =/= nomatch end, sent(Log))),
    gen_tcp:close(L).

%% PREAUTH on a connection that has to be protected: it is not used.
preauth_is_refused_under_starttls_test() ->
    {Port, Log, L} = serve(<<"* PREAUTH logged in\r\n">>, fun ok_all/2),
    C = start(Port, #{tls => starttls}),
    ?assertEqual({error, tls_failed}, noop(C)),
    ?assertEqual([], [S || S <- sent(Log), binary:match(S, <<"NOOP">>) =/= nomatch]),
    gen_tcp:close(L).

preauth_is_refused_by_default_test() ->
    {Port, _Log, L} = serve(<<"* PREAUTH logged in\r\n">>, fun ok_all/2),
    C = start(Port, #{}),
    ?assertEqual({error, tls_failed}, noop(C)),
    gen_tcp:close(L).

%% Plain text asked for by name: PREAUTH is the server's own way of logging in.
preauth_is_fine_without_tls_test() ->
    {Port, _Log, L} = serve(<<"* PREAUTH logged in\r\n">>, fun ok_all/2),
    C = start(Port, #{tls => false}),
    ?assertMatch({ok, _, {ok, _, _}}, noop(C)),
    gen_tcp:close(L).

%% A setting that is not understood is an error at start, not plain text.
an_unknown_tls_setting_is_refused_test() ->
    process_flag(trap_exit, true),
    Config = #{
        host => <<"127.0.0.1">>,
        port => 9,
        tls => 'maybe',
        credentials => {password, <<"u">>, <<"p">>}
    },
    ?assertMatch({error, {invalid_tls_option, 'maybe'}}, mailio_imap_conn:start_link(Config)).

certs() ->
    SAN = #'Extension'{extnID = ?'id-ce-subjectAltName', extnValue = [{dNSName, "localhost"}]},
    Key = {key, {namedCurve, secp256r1}},
    Dig = {digest, sha256},
    #{server_config := Server, client_config := Client} =
        public_key:pkix_test_data(#{
            server_chain => #{root => [Key, Dig], peer => [Key, Dig, {extensions, [SAN]}]},
            client_chain => #{root => [Key, Dig], peer => [Key, Dig]}
        }),
    {Server, Client}.

%% After a STARTTLS session was lost the new connection starts in plain text and
%% asks for STARTTLS again: it does not try TLS on the plain port at once.
a_lost_starttls_connection_starts_again_in_plain_text_test_() ->
    {timeout, 30, fun() ->
        {ServerOpts, Client} = certs(),
        {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
        {ok, Port} = inet:port(L),
        Self = self(),
        spawn_link(fun() ->
            %% first connection: a full STARTTLS session, then it is closed
            {ok, S1} = gen_tcp:accept(L),
            gen_tcp:send(S1, <<"* OK ready\r\n">>),
            {ok, St} = gen_tcp:recv(S1, 0, 5000),
            [T2 | _] = binary:split(St, <<" ">>),
            gen_tcp:send(S1, [T2, <<" OK begin\r\n">>]),
            {ok, SS} = ssl:handshake(S1, ServerOpts, 5000),
            {ok, Login} = ssl:recv(SS, 0, 5000),
            [T3 | _] = binary:split(Login, <<" ">>),
            ssl:send(SS, [T3, <<" OK logged in\r\n">>]),
            Self ! logged_in,
            ssl:close(SS),
            %% second connection: what does the client send first?
            {ok, S2} = gen_tcp:accept(L),
            gen_tcp:send(S2, <<"* OK ready\r\n">>),
            Self ! {second, gen_tcp:recv(S2, 1, 8000)},
            gen_tcp:close(S2)
        end),
        {ok, C} = mailio_imap_conn:start_link(#{
            host => <<"localhost">>,
            port => Port,
            tls => starttls,
            cacerts => proplists:get_value(cacerts, Client),
            credentials => {password, <<"u">>, <<"p">>},
            command_timeout => 3000
        }),
        _ = noop(C),
        receive
            logged_in -> ok
        after 5000 -> error(no_login)
        end,
        %% the first byte of a plain session is a tag; a TLS hello starts with 0x16
        {second, {ok, First}} =
            receive
                {second, _} = M -> M
            after 12000 -> error(no_second_connection)
            end,
        ?assertNotEqual(<<16#16>>, First),
        gen_tcp:close(L)
    end}.
