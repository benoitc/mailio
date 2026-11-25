%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc A set of UIDs kept as ranges, for reading a whole mailbox without
%%% holding a list of every number. UIDs usually arrive in order and close
%%% together, so a mailbox of a million messages is a handful of ranges.
%%% The set has a limit: past it, `add' returns `{error, too_many}'.
-module(mailio_uid_set).

-export([new/1, add/2, to_lookup/1, member/2, size/1]).

-record(set, {
    %% reversed list of {Lo, Hi}, newest first
    ranges = [] :: [{integer(), integer()}],
    count = 0 :: non_neg_integer(),
    limit :: pos_integer()
}).

-opaque set() :: #set{}.
-opaque lookup() :: {tuple(), non_neg_integer()}.
-export_type([set/0, lookup/0]).

-spec new(pos_integer()) -> set().
new(Limit) -> #set{limit = Limit}.

-spec add(integer(), set()) -> {ok, set()} | {error, too_many}.
add(_Uid, #set{count = C, limit = L}) when C >= L ->
    {error, too_many};
add(Uid, #set{ranges = [{Lo, Hi} | Rest], count = C} = S) when Uid =:= Hi + 1 ->
    {ok, S#set{ranges = [{Lo, Uid} | Rest], count = C + 1}};
add(Uid, #set{ranges = [{Lo, Hi} | _], count = C} = S) when Uid >= Lo, Uid =< Hi ->
    %% already in it
    _ = C,
    {ok, S};
add(Uid, #set{ranges = Ranges, count = C} = S) ->
    {ok, S#set{ranges = [{Uid, Uid} | Ranges], count = C + 1}}.

%% @doc Make the set ready for membership tests: sorted, merged, searchable.
-spec to_lookup(set()) -> lookup().
to_lookup(#set{ranges = Ranges}) ->
    Sorted = merge(lists:sort(Ranges)),
    {list_to_tuple(Sorted), length(Sorted)}.

merge([{A, B}, {C, D} | Rest]) when C =< B + 1 -> merge([{A, max(B, D)} | Rest]);
merge([R | Rest]) -> [R | merge(Rest)];
merge([]) -> [].

-spec member(integer(), lookup()) -> boolean().
member(Uid, {Tuple, N}) -> search(Uid, Tuple, 1, N).

search(_Uid, _T, Lo, Hi) when Lo > Hi ->
    false;
search(Uid, T, Lo, Hi) ->
    Mid = (Lo + Hi) div 2,
    case element(Mid, T) of
        {A, _} when Uid < A -> search(Uid, T, Lo, Mid - 1);
        {_, B} when Uid > B -> search(Uid, T, Mid + 1, Hi);
        _ -> true
    end.

-spec size(set()) -> non_neg_integer().
size(#set{count = C}) -> C.
