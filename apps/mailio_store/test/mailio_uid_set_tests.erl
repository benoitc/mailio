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
