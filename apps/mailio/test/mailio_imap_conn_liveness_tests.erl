%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% A stuck server or a bad caller must never freeze or kill an IMAP
%%% connection, and a call must never run after its caller gave up.
-module(mailio_imap_conn_liveness_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% A raw server: greeting, login, then Script(Cmd, Socket) for each command.
%% Every command it receives is sent to the test as {cmd, Binary}.
%%====================================================================

serve(Script) ->
    Test = self(),
    flush(),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {packet, line}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        gen_tcp:send(S, <<"* OK ready\r\n">>),
        loop(S, Test, Script),
        gen_tcp:close(S),
        gen_tcp:close(L)
    end),
    Port.

loop(S, Test, Script) ->
    case gen_tcp:recv(S, 0, 10000) of
        {ok, <<"DONE\r\n">>} ->
            Test ! {cmd, <<"DONE">>},
            Script({done, S}),
            loop(S, Test, Script);
        {ok, Line} ->
            [Tag, Cmd | _] = binary:split(binary:replace(Line, <<"\r\n">>, <<>>), <<" ">>, [global]),
            case string:uppercase(Cmd) of
                <<"LOGIN">> ->
                    gen_tcp:send(S, [Tag, <<" OK logged in\r\n">>]),
                    loop(S, Test, Script);
                Upper ->
                    Test ! {cmd, Upper},
                    case Script({cmd, Upper, Tag, S}) of
                        stop -> ok;
                        _ -> loop(S, Test, Script)
                    end
            end;
        {error, _} ->
            ok
    end.

%% Commands that earlier tests' servers sent to this process are not ours.
flush() ->
    receive
        {cmd, _} -> flush()
    after 0 -> ok
    end.

connect(Port, Extra) ->
    {ok, C} = mailio_imap_conn:start_link(
        maps:merge(
            #{
                host => <<"127.0.0.1">>,
                port => Port,
                tls => false,
                credentials => {password, <<"user">>, <<"hunter2-secret">>}
            },
            Extra
        )
    ),
    C.

noop(C, Timeout) ->
    mailio_imap_conn:run(C, fun(T) -> {[T, <<" NOOP\r\n">>], undefined} end, Timeout).

received() ->
    receive
        {cmd, C} -> [C | received()]
    after 200 -> []
    end.

%%====================================================================
%% Deadlines
%%====================================================================

a_silent_server_does_not_stall_the_caller_test() ->
    Port = serve(fun({cmd, <<"NOOP">>, _, _}) -> ok end),
    C = connect(Port, #{}),
    {T, R} = timer:tc(fun() -> noop(C, 500) end),
    ?assertEqual({error, imap_timeout}, R),
    ?assert(T < 2500000),
    ?assert(is_process_alive(C)),
    mailio_imap_conn:close(C).

%% After a lost reply the tags no longer line up, so the connection is dropped
%% and later calls are refused, not sent on the old stream.
calls_after_a_timeout_do_not_use_the_old_connection_test() ->
    Port = serve(fun({cmd, <<"NOOP">>, _, _}) -> ok end),
    C = connect(Port, #{}),
    ?assertEqual({error, imap_timeout}, noop(C, 400)),
    R = noop(C, 400),
    ?assert(lists:member(R, [{error, not_connected}, {error, imap_timeout}])),
    %% the server saw one command only
    ?assertEqual([<<"NOOP">>], received()),
    mailio_imap_conn:close(C).

%% A call queued behind a slow command, whose caller has given up by the time
%% the connection is free, must not be sent.
a_queued_call_is_not_run_after_its_caller_gave_up_test() ->
    Port = serve(fun({cmd, <<"NOOP">>, Tag, S}) ->
        timer:sleep(700),
        gen_tcp:send(S, [Tag, <<" OK done\r\n">>])
    end),
    C = connect(Port, #{}),
    Parent = self(),
    spawn_link(fun() -> Parent ! {first, noop(C, 5000)} end),
    timer:sleep(100),
    Second = noop(C, 200),
    ?assertEqual({error, imap_timeout}, Second),
    receive
        {first, R1} -> ?assertMatch({ok, _, {ok, _, _}}, R1)
    after 5000 -> ?assert(false)
    end,
    timer:sleep(300),
    ?assertEqual([<<"NOOP">>], received()),
    mailio_imap_conn:close(C).

%%====================================================================
%% IDLE
%%====================================================================

idle_server() ->
    serve(fun
        ({cmd, <<"EXAMINE">>, Tag, S}) ->
            gen_tcp:send(S, [<<"* 0 EXISTS\r\n">>, Tag, <<" OK [READ-ONLY] done\r\n">>]);
        ({cmd, <<"IDLE">>, _Tag, S}) ->
            gen_tcp:send(S, <<"+ idling\r\n">>);
        ({done, S}) ->
            timer:sleep(300),
            %% the tag of the IDLE command is A2 (LOGIN is A1)
            gen_tcp:send(S, <<"A3 OK idle done\r\n">>)
    end).

idle_ready(Port) ->
    C = connect(Port, #{}),
    {ok, _, _} = mailio_imap_conn:run(
        C, fun(T) -> {mailio_imap_proto:examine(T, <<"INBOX">>), undefined} end, 3000
    ),
    C.

a_second_idle_stop_is_refused_test() ->
    C = idle_ready(idle_server()),
    ok = mailio_imap_conn:idle_start(C, self()),
    Parent = self(),
    spawn_link(fun() -> Parent ! {stop1, mailio_imap_conn:idle_stop(C)} end),
    timer:sleep(100),
    ?assertEqual({error, already_stopping}, mailio_imap_conn:idle_stop(C)),
    receive
        {stop1, R} -> ?assertEqual(ok, R)
    after 5000 -> ?assert(false)
    end,
    mailio_imap_conn:close(C).

a_disconnect_during_idle_answers_the_stopper_test() ->
    Port = serve(fun
        ({cmd, <<"EXAMINE">>, Tag, S}) ->
            gen_tcp:send(S, [<<"* 0 EXISTS\r\n">>, Tag, <<" OK done\r\n">>]);
        ({cmd, <<"IDLE">>, _, S}) ->
            gen_tcp:send(S, <<"+ idling\r\n">>);
        ({done, S}) ->
            gen_tcp:close(S)
    end),
    C = idle_ready(Port),
    ok = mailio_imap_conn:idle_start(C, self()),
    ?assertEqual({error, imap_disconnected}, mailio_imap_conn:idle_stop(C)),
    mailio_imap_conn:close(C).

a_disconnect_before_idle_starts_answers_the_starter_test() ->
    Port = serve(fun
        ({cmd, <<"EXAMINE">>, Tag, S}) ->
            gen_tcp:send(S, [<<"* 0 EXISTS\r\n">>, Tag, <<" OK done\r\n">>]);
        ({cmd, <<"IDLE">>, _, S}) ->
            gen_tcp:close(S),
            stop
    end),
    C = idle_ready(Port),
    ?assertEqual({error, imap_disconnected}, mailio_imap_conn:idle_start(C, self())),
    mailio_imap_conn:close(C).

idle_calls_have_a_finite_default_wait_test() ->
    %% a server that never accepts IDLE: the default wait must end
    Port = serve(fun
        ({cmd, <<"EXAMINE">>, Tag, S}) ->
            gen_tcp:send(S, [<<"* 0 EXISTS\r\n">>, Tag, <<" OK done\r\n">>]);
        ({cmd, <<"IDLE">>, _, _}) ->
            ok
    end),
    C = connect(Port, #{command_timeout => 600}),
    {ok, _, _} = mailio_imap_conn:run(
        C, fun(T) -> {mailio_imap_proto:examine(T, <<"INBOX">>), undefined} end, 3000
    ),
    {T, R} = timer:tc(fun() -> mailio_imap_conn:idle_start(C, self()) end),
    ?assertEqual({error, imap_timeout}, R),
    ?assert(T < 3000000),
    mailio_imap_conn:close(C).

%%====================================================================
%% Isolation
%%====================================================================

a_crashing_builder_does_not_kill_the_connection_test() ->
    Port = serve(fun({cmd, <<"NOOP">>, Tag, S}) -> gen_tcp:send(S, [Tag, <<" OK\r\n">>]) end),
    C = connect(Port, #{}),
    ?assertMatch(
        {error, {builder_failed, _}}, mailio_imap_conn:run(C, fun(_) -> error(boom) end, 2000)
    ),
    ?assert(is_process_alive(C)),
    ?assertMatch({ok, _, {ok, _, _}}, noop(C, 2000)),
    mailio_imap_conn:close(C).

state_does_not_expose_credentials_test() ->
    Port = serve(fun({cmd, <<"NOOP">>, Tag, S}) -> gen_tcp:send(S, [Tag, <<" OK\r\n">>]) end),
    C = connect(Port, #{token => <<"tok-abc-123">>}),
    ?assertMatch({ok, _, _}, noop(C, 2000)),
    Text = lists:flatten(io_lib:format("~p", [sys:get_status(C)])),
    ?assertEqual(nomatch, re:run(Text, "hunter2-secret|tok-abc-123")),
    mailio_imap_conn:close(C).
