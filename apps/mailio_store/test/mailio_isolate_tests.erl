-module(mailio_isolate_tests).
-include_lib("eunit/include/eunit.hrl").

result_test() ->
    ?assertEqual({ok, 3}, mailio_isolate:run(fun() -> 1 + 2 end, 1000)).

crash_does_not_reach_the_caller_test() ->
    process_flag(trap_exit, false),
    ?assertMatch(
        {error, {crashed, {error, boom, _}}}, mailio_isolate:run(fun() -> error(boom) end, 1000)
    ),
    ?assertMatch(
        {error, {crashed, {exit, bye, _}}}, mailio_isolate:run(fun() -> exit(bye) end, 1000)
    ).

hang_is_killed_test() ->
    Me = self(),
    F = fun() ->
        Me ! {worker, self()},
        timer:sleep(infinity)
    end,
    {T, R} = timer:tc(fun() -> mailio_isolate:run(F, 100) end),
    ?assertEqual({error, timeout}, R),
    ?assert(T < 1000000),
    receive
        {worker, W} ->
            timer:sleep(20),
            ?assertNot(is_process_alive(W))
    end.
