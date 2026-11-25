%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% The lock that makes callers of one IMAP connection take turns.
-module(mailio_imap_lock_tests).
-include_lib("eunit/include/eunit.hrl").

with_lock(Fun) ->
    Conn = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, Lock} = mailio_imap_lock:start_link(Conn),
    try
        Fun(Lock, Conn)
    after
        mailio_imap_lock:stop(Lock),
        Conn ! stop
    end.

%% Two sessions never overlap, and they run in the order they asked.
sessions_do_not_overlap_and_keep_their_order_test() ->
    with_lock(fun(Lock, _Conn) ->
        Self = self(),
        First = spawn_link(fun() ->
            mailio_imap_lock:with_session(Lock, 5000, fun() ->
                Self ! {in, 1},
                receive
                    go -> ok
                end,
                Self ! {out, 1}
            end)
        end),
        receive
            {in, 1} -> ok
        after 2000 -> error(no_first)
        end,
        [
            begin
                spawn_link(fun() ->
                    mailio_imap_lock:with_session(Lock, 5000, fun() ->
                        Self ! {in, N},
                        Self ! {out, N}
                    end)
                end),
                timer:sleep(20)
            end
         || N <- [2, 3]
        ],
        First ! go,
        ?assertEqual([{out, 1}, {in, 2}, {out, 2}, {in, 3}, {out, 3}], drain(5))
    end).

drain(0) ->
    [];
drain(N) ->
    receive
        M -> [M | drain(N - 1)]
    after 2000 -> [timeout]
    end.

a_holder_that_dies_gives_up_its_turn_test() ->
    with_lock(fun(Lock, _Conn) ->
        Holder = spawn(fun() ->
            mailio_imap_lock:with_session(Lock, 5000, fun() -> timer:sleep(infinity) end)
        end),
        timer:sleep(50),
        Waiter = self(),
        spawn_link(fun() ->
            Waiter ! {got, mailio_imap_lock:with_session(Lock, 5000, fun() -> mine end)}
        end),
        timer:sleep(50),
        exit(Holder, kill),
        ?assertEqual(
            mine,
            receive
                {got, R} -> R
            after 2000 -> timeout
            end
        )
    end).

a_caller_that_gives_up_waiting_does_not_get_a_later_turn_test() ->
    with_lock(fun(Lock, _Conn) ->
        Self = self(),
        Holder = spawn_link(fun() ->
            mailio_imap_lock:with_session(Lock, 5000, fun() ->
                Self ! held,
                receive
                    release -> ok
                end
            end)
        end),
        receive
            held -> ok
        after 2000 -> error(no_hold)
        end,
        ?assertEqual(
            {error, imap_timeout}, mailio_imap_lock:with_session(Lock, 50, fun() -> x end)
        ),
        Holder ! release,
        timer:sleep(50),
        %% the one that gave up left no turn behind
        ?assertEqual(ok, mailio_imap_lock:with_session(Lock, 500, fun() -> ok end))
    end).

waiting_callers_are_told_when_the_connection_goes_test() ->
    Conn = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, Lock} = mailio_imap_lock:start_link(Conn),
    Self = self(),
    spawn_link(fun() ->
        mailio_imap_lock:with_session(Lock, 5000, fun() -> timer:sleep(infinity) end)
    end),
    timer:sleep(50),
    spawn_link(fun() ->
        Self ! {waiter, mailio_imap_lock:with_session(Lock, 5000, fun() -> ok end)}
    end),
    timer:sleep(50),
    Conn ! stop,
    ?assertEqual(
        {error, imap_disconnected},
        receive
            {waiter, R} -> R
        after 2000 -> timeout
        end
    ).
