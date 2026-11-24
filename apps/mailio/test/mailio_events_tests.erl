%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_events_tests).
-include_lib("eunit/include/eunit.hrl").

unsubscribe_releases_monitor_test() ->
    {ok, Pid} = mailio_events:start_link(),
    unlink(Pid),
    try
        Count = fun() ->
            {monitors, M} = process_info(Pid, monitors),
            length(M)
        end,
        Before = Count(),
        Refs = [element(2, mailio_events:subscribe(#{})) || _ <- lists:seq(1, 20)],
        ?assertEqual(Before + 20, Count()),
        [ok = mailio_events:unsubscribe(R) || R <- Refs],
        ?assertEqual(Before, Count())
    after
        exit(Pid, shutdown)
    end.
