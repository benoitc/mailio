%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% An IMAP connection is protected unless it is said not to be, and a server that
%%% greets with PREAUTH is not a way around that (RFC 9051, section 7.1.4).
-module(mailio_imap_tls_default_tests).
-include_lib("eunit/include/eunit.hrl").

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
