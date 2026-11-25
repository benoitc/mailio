%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
-module(mailio_sync_pages_tests).
-include_lib("eunit/include/eunit.hrl").

%% A source of N pages of one change each: cursor k gives change k and cursor k+1.
pages(N) ->
    fun(K) ->
        case K >= N of
            true -> {ok, [{added, K}], K + 1, done};
            false -> {ok, [{added, K}], K + 1, more}
        end
    end.

pages_come_back_in_order_test() ->
    ?assertEqual(
        {ok, [{added, 0}, {added, 1}, {added, 2}, {added, 3}], 4},
        mailio_sync_pages:collect(pages(3), 0, #{})
    ).

a_single_page_is_enough_test() ->
    ?assertEqual({ok, [{added, 0}], 1}, mailio_sync_pages:collect(pages(0), 0, #{})).

a_cursor_that_does_not_move_is_refused_test() ->
    Stuck = fun(K) -> {ok, [], K, more} end,
    ?assertEqual({error, repeated_cursor}, mailio_sync_pages:collect(Stuck, 7, #{})).

a_cursor_seen_before_is_refused_test() ->
    Loop = fun
        (a) -> {ok, [], b, more};
        (b) -> {ok, [], c, more};
        (c) -> {ok, [], a, more}
    end,
    ?assertEqual({error, repeated_cursor}, mailio_sync_pages:collect(Loop, a, #{})).

an_endless_walk_with_new_cursors_is_bounded_test() ->
    Endless = fun(K) -> {ok, [], K + 1, more} end,
    {T, R} = timer:tc(fun() -> mailio_sync_pages:collect(Endless, 0, #{max_pages => 500}) end),
    ?assertEqual({error, too_many_pages}, R),
    ?assert(T < 1000000).

an_adapter_error_ends_the_walk_test() ->
    Fail = fun
        (0) -> {ok, [{added, 0}], 1, more};
        (1) -> {error, boom}
    end,
    ?assertEqual({error, boom}, mailio_sync_pages:collect(Fail, 0, #{})).

%% A reset on a later page means what came before is not to be used.
a_reset_on_a_later_page_stops_the_walk_test() ->
    Pages = fun
        (0) -> {ok, [{added, 0}], 1, more};
        (1) -> {ok, [reset], 2, more}
    end,
    ?assertEqual({stopped, {signal, reset}}, mailio_sync_pages:collect(Pages, 0, #{})).

%% Many small pages are put together in linear work.
many_small_pages_are_collected_in_linear_work_test() ->
    N = 20000,
    {reductions, R0} = process_info(self(), reductions),
    {ok, Changes, _} = mailio_sync_pages:collect(pages(N), 0, #{max_pages => N + 10}),
    {reductions, R1} = process_info(self(), reductions),
    ?assertEqual(N + 1, length(Changes)),
    ?assert(R1 - R0 < N * 200).
