%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
-module(mailio_uid_set_tests).
-include_lib("eunit/include/eunit.hrl").

fill(Uids, Limit) ->
    lists:foldl(
        fun(U, {ok, S}) -> mailio_uid_set:add(U, S) end,
        {ok, mailio_uid_set:new(Limit)},
        Uids
    ).

membership_test() ->
    {ok, S} = fill([100, 101, 102, 110, 200, 201], 100),
    L = mailio_uid_set:to_lookup(S),
    [?assert(mailio_uid_set:member(U, L)) || U <- [100, 101, 102, 110, 200, 201]],
    [?assertNot(mailio_uid_set:member(U, L)) || U <- [1, 99, 103, 109, 111, 199, 202, 9999]].

order_does_not_matter_test() ->
    {ok, S} = fill([201, 100, 102, 101, 200, 110], 100),
    L = mailio_uid_set:to_lookup(S),
    [?assert(mailio_uid_set:member(U, L)) || U <- [100, 101, 102, 110, 200, 201]],
    ?assertNot(mailio_uid_set:member(103, L)).

a_dense_mailbox_is_a_few_ranges_test() ->
    {ok, S} = fill(lists:seq(1, 50000), 1000000),
    {Tuple, N} = mailio_uid_set:to_lookup(S),
    ?assertEqual(1, N),
    ?assertEqual({1, 50000}, element(1, Tuple)).

the_limit_is_kept_test() ->
    {ok, S} = fill([1, 2, 3], 3),
    ?assertEqual({error, too_many}, mailio_uid_set:add(10, S)).

the_empty_set_has_no_members_test() ->
    L = mailio_uid_set:to_lookup(mailio_uid_set:new(10)),
    ?assertNot(mailio_uid_set:member(1, L)).

%% The limit is on distinct UIDs, whatever order they arrive in.
duplicates_do_not_use_the_limit_test() ->
    {ok, S} = fill([2, 4, 4], 2),
    ?assertEqual(2, mailio_uid_set:size(S)),
    %% a duplicate at the limit is fine, a new one is not
    ?assertMatch({ok, _}, mailio_uid_set:add(4, S)),
    ?assertMatch({ok, _}, mailio_uid_set:add(2, S)),
    ?assertEqual({error, too_many}, mailio_uid_set:add(9, S)).

out_of_order_duplicates_are_counted_once_test() ->
    {ok, S} = fill([2, 4, 2], 100),
    ?assertEqual(2, mailio_uid_set:size(S)),
    {ok, S2} = fill([5, 1, 3, 5, 1, 3, 4, 2], 100),
    ?assertEqual(5, mailio_uid_set:size(S2)),
    L = mailio_uid_set:to_lookup(S2),
    [?assert(mailio_uid_set:member(U, L)) || U <- [1, 2, 3, 4, 5]],
    ?assertNot(mailio_uid_set:member(6, L)).

a_shuffled_mailbox_is_still_compact_test() ->
    Uids = [U || {_, U} <- lists:sort([{rand:uniform(), U} || U <- lists:seq(1, 5000)])],
    {ok, S} = fill(Uids, 100000),
    ?assertEqual(5000, mailio_uid_set:size(S)),
    {Tuple, N} = mailio_uid_set:to_lookup(S),
    ?assertEqual(1, N),
    ?assertEqual({1, 5000}, element(1, Tuple)).
