%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc A set of UIDs kept as ranges, for reading a whole mailbox without
%%% holding a list of every number. UIDs usually arrive in order and close
%%% together, so a mailbox of a million messages is a handful of ranges. The
%%% set counts distinct UIDs, in whatever order they come, and has a limit:
%%% past it, `add' returns `{error, too_many}'; a UID already in the set is
%%% always accepted.
-module(mailio_uid_set).

-export([new/1, add/2, to_lookup/1, member/2, size/1]).

-record(set, {
    %% Hi => Lo, ordered by Hi
    ranges :: gb_trees:tree(integer(), integer()),
    count = 0 :: non_neg_integer(),
    limit :: pos_integer()
}).

-opaque set() :: #set{}.
-opaque lookup() :: {tuple(), non_neg_integer()}.
-export_type([set/0, lookup/0]).

-spec new(pos_integer()) -> set().
new(Limit) -> #set{ranges = gb_trees:empty(), limit = Limit}.

-spec add(integer(), set()) -> {ok, set()} | {error, too_many}.
add(Uid, #set{ranges = Ranges, count = Count, limit = Limit} = S) ->
    case in_ranges(Uid, Ranges) of
        true ->
            {ok, S};
        false when Count >= Limit ->
            {error, too_many};
        false ->
            {ok, S#set{ranges = insert(Uid, Ranges), count = Count + 1}}
    end.

%% The range with the smallest Hi at or above the UID is the only one that can
%% hold it.
in_ranges(Uid, Ranges) ->
    case gb_trees:next(gb_trees:iterator_from(Uid, Ranges)) of
        {_Hi, Lo, _} -> Lo =< Uid;
        none -> false
    end.

%% Arriving in order, a UID extends the highest range; otherwise it is a range of
%% its own (merged when the set is made ready for lookup).
insert(Uid, Ranges) ->
    case gb_trees:is_empty(Ranges) of
        true ->
            gb_trees:insert(Uid, Uid, Ranges);
        false ->
            {Hi, Lo} = gb_trees:largest(Ranges),
            case Uid =:= Hi + 1 of
                true -> gb_trees:insert(Uid, Lo, gb_trees:delete(Hi, Ranges));
                false -> gb_trees:insert(Uid, Uid, Ranges)
            end
    end.

%% @doc Make the set ready for membership tests: sorted, merged, searchable.
-spec to_lookup(set()) -> lookup().
to_lookup(#set{ranges = Ranges}) ->
    Sorted = merge([{Lo, Hi} || {Hi, Lo} <- gb_trees:to_list(Ranges)]),
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
