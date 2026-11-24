%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_registry_tests).
-include_lib("eunit/include/eunit.hrl").

registry_test_() ->
    {setup,
        fun() ->
            {ok, Pid} = mailio_registry:start_link(),
            unlink(Pid),
            Pid
        end,
        fun(Pid) ->
            MRef = erlang:monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', MRef, _, _, _} -> ok
            end
        end,
        [
            fun stale_down_keeps_new_registration/0,
            fun down_removes_own_registration/0
        ]}.

spawn_idle() ->
    spawn(fun() ->
        receive
            stop -> ok
        end
    end).

kill(Pid) ->
    MRef = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', MRef, _, _, _} -> ok
    end,
    %% let the registry process its own DOWN
    _ = sys:get_state(mailio_registry),
    ok.

stale_down_keeps_new_registration() ->
    Name = {t, stale},
    A = spawn_idle(),
    ?assertEqual(yes, mailio_registry:register_name(Name, A)),
    ok = mailio_registry:unregister_name(Name),
    B = spawn_idle(),
    ?assertEqual(yes, mailio_registry:register_name(Name, B)),
    kill(A),
    ?assertEqual({ok, B}, mailio_registry:lookup(Name)),
    kill(B),
    ?assertEqual({error, not_found}, mailio_registry:lookup(Name)).

down_removes_own_registration() ->
    Name = {t, own},
    A = spawn_idle(),
    ?assertEqual(yes, mailio_registry:register_name(Name, A)),
    kill(A),
    ?assertEqual({error, not_found}, mailio_registry:lookup(Name)).
