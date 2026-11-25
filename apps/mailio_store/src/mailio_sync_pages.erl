%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Reading a mailbox page by page.
%%%
%%% An adapter answers a read with `done' or, when there is more to read, with
%%% `more' and the cursor to continue from. This module walks those pages with
%%% three guarantees the adapter cannot give: the walk ends (a bound on the
%%% number of pages), a cursor that is handed back unchanged or seen before is
%%% refused (the adapter is not making progress), and the pages are put together
%%% in linear work, however many there are.
-module(mailio_sync_pages).

-export([walk/5, collect/3]).
-export_type([cursor/0, fetch/0, step/1]).

-type cursor() :: term().
-type fetch() :: fun((cursor()) -> {ok, [term()], cursor(), done | more} | {error, term()}).
-type step(Acc) :: fun(([term()], cursor(), Acc) -> {ok, Acc} | {stop, term()}).

-define(DEFAULT_MAX_PAGES, 100000).

%% @doc Fetch pages from `Cursor' until the adapter says `done'. Each page goes
%% through `Step', which keeps what it needs in an accumulator or stops the walk.
%% Result: `{ok, Acc, FinalCursor}', `{stopped, Why}', or `{error, Reason}'
%% where Reason is the adapter's own, `repeated_cursor' or `too_many_pages'.
-spec walk(fetch(), cursor(), #{max_pages => pos_integer()}, Acc, step(Acc)) ->
    {ok, Acc, cursor()} | {stopped, term()} | {error, term()}.
walk(Fetch, Cursor, Opts, Acc, Step) ->
    Max = maps:get(max_pages, Opts, ?DEFAULT_MAX_PAGES),
    walk(Fetch, Cursor, Max, 0, #{Cursor => true}, Acc, Step).

walk(_Fetch, _Cursor, Max, Pages, _Seen, _Acc, _Step) when Pages >= Max ->
    {error, too_many_pages};
walk(Fetch, Cursor, Max, Pages, Seen, Acc, Step) ->
    case Fetch(Cursor) of
        {ok, Changes, Next, done} ->
            case Step(Changes, Next, Acc) of
                {ok, Acc1} -> {ok, Acc1, Next};
                {stop, Why} -> {stopped, Why}
            end;
        {ok, Changes, Next, more} ->
            case is_map_key(Next, Seen) of
                true ->
                    {error, repeated_cursor};
                false ->
                    case Step(Changes, Next, Acc) of
                        {ok, Acc1} ->
                            walk(Fetch, Next, Max, Pages + 1, Seen#{Next => true}, Acc1, Step);
                        {stop, Why} ->
                            {stopped, Why}
                    end
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc All the changes of a read, in order. A page that holds `reset' or
%% `resync' stops the collection, since what came before it is not to be used:
%% the answer is then `{stopped, {signal, reset | resync}}'.
-spec collect(fetch(), cursor(), map()) ->
    {ok, [term()], cursor()} | {stopped, term()} | {error, term()}.
collect(Fetch, Cursor, Opts) ->
    Step = fun(Changes, _Next, Pages) ->
        case [S || S <- [reset, resync], lists:member(S, Changes)] of
            [] -> {ok, [Changes | Pages]};
            [Signal | _] -> {stop, {signal, Signal}}
        end
    end,
    case walk(Fetch, Cursor, Opts, [], Step) of
        {ok, Pages, Final} -> {ok, lists:append(lists:reverse(Pages)), Final};
        Other -> Other
    end.
