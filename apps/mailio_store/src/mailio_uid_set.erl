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
    %% Hi => Lo, ordered by Hi: the integer UIDs
    ranges :: gb_trees:tree(integer(), integer()),
    %% anything else (an opaque id): kept as it is, by equality
    others = #{} :: #{term() => true},
    count = 0 :: non_neg_integer(),
    limit :: pos_integer()
}).

-opaque set() :: #set{}.
-opaque lookup() :: {tuple(), non_neg_integer(), #{term() => true}}.
-export_type([set/0, lookup/0]).

-spec new(pos_integer()) -> set().
new(Limit) -> #set{ranges = gb_trees:empty(), limit = Limit}.

-spec add(term(), set()) -> {ok, set()} | {error, too_many}.
add(Uid, #set{count = Count, limit = Limit} = S) ->
    case present(Uid, S) of
        true -> {ok, S};
        false when Count >= Limit -> {error, too_many};
        false -> {ok, insert(Uid, S#set{count = Count + 1})}
    end.

present(Uid, #set{ranges = Ranges}) when is_integer(Uid) -> in_ranges(Uid, Ranges);
present(Uid, #set{others = Others}) -> is_map_key(Uid, Others).

%% The range with the smallest Hi at or above the UID is the only one that can
%% hold it.
in_ranges(Uid, Ranges) ->
    case gb_trees:next(gb_trees:iterator_from(Uid, Ranges)) of
        {_Hi, Lo, _} -> Lo =< Uid;
        none -> false
    end.

%% Arriving in order, an integer extends the highest range; otherwise it is a
%% range of its own (merged when the set is made ready for lookup). Anything that
%% is not an integer has no neighbours: it is only remembered.
insert(Uid, #set{ranges = Ranges} = S) when is_integer(Uid) ->
    case gb_trees:is_empty(Ranges) of
        true ->
            S#set{ranges = gb_trees:insert(Uid, Uid, Ranges)};
        false ->
            {Hi, Lo} = gb_trees:largest(Ranges),
            case Uid =:= Hi + 1 of
                true -> S#set{ranges = gb_trees:insert(Uid, Lo, gb_trees:delete(Hi, Ranges))};
                false -> S#set{ranges = gb_trees:insert(Uid, Uid, Ranges)}
            end
    end;
insert(Uid, #set{others = Others} = S) ->
    S#set{others = Others#{Uid => true}}.

%% @doc Make the set ready for membership tests: sorted, merged, searchable.
-spec to_lookup(set()) -> lookup().
to_lookup(#set{ranges = Ranges, others = Others}) ->
    Sorted = merge([{Lo, Hi} || {Hi, Lo} <- gb_trees:to_list(Ranges)]),
    {list_to_tuple(Sorted), length(Sorted), Others}.

merge([{A, B}, {C, D} | Rest]) when C =< B + 1 -> merge([{A, max(B, D)} | Rest]);
merge([R | Rest]) -> [R | merge(Rest)];
merge([]) -> [].

-spec member(term(), lookup()) -> boolean().
member(Uid, {Tuple, N, _Others}) when is_integer(Uid) -> search(Uid, Tuple, 1, N);
member(Uid, {_Tuple, _N, Others}) -> is_map_key(Uid, Others).

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
