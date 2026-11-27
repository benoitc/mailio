%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Evictable metadata and body cache. Entries are scoped by
%%% account, capped by count and age, and invalidated per account when mail
%%% changes. Nothing here is the source of truth: durable state is in
%%% mailio_mcp_store.
-module(mailio_mcp_cache).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([get/2, put/3, put/4, epoch/1, invalidate_account/1, invalidate_mailbox/2, stats/0]).

-define(T, mailio_mcp_cache_tab).
-define(GEN, mailio_mcp_cache_gen).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = ets:new(?T, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?GEN, [named_table, public, set]),
    ok = mailio_mcp_stats:init(),
    erlang:send_after(60000, self(), sweep),
    {ok, #{}}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(sweep, S) ->
    sweep(),
    erlang:send_after(60000, self(), sweep),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

%% @doc Look up Key for Account. Returns the value and its age in seconds.
-spec get(binary(), term()) -> {ok, term(), non_neg_integer()} | miss.
get(Account, Key) ->
    Now = erlang:system_time(second),
    case ets:lookup(?T, {Account, Key}) of
        [{_, V, At}] ->
            Age = Now - At,
            case Age =< mailio_mcp_config:limit(cache_ttl, 300) of
                true -> {ok, V, Age};
                false -> miss
            end;
        [] ->
            miss
    end.

%% @doc The account's cache generation. Every invalidation bumps it.
-spec epoch(binary()) -> non_neg_integer().
epoch(Account) ->
    case ets:lookup(?GEN, Account) of
        [{_, N}] -> N;
        [] -> 0
    end.

bump(Account) ->
    _ = ets:update_counter(?GEN, Account, 1, {Account, 0}),
    ok.

put(Account, Key, Value) ->
    put(Account, Key, Value, epoch(Account)).

%% @doc Insert only if the account's generation is still Epoch. A search that
%% captured the generation before an invalidation must never land its stale
%% result after the invalidation deleted the entries.
-spec put(binary(), term(), term(), non_neg_integer()) -> ok | stale.
put(Account, Key, Value, Epoch) ->
    case epoch(Account) of
        Epoch ->
            Max = mailio_mcp_config:limit(cache_max_entries, 2000),
            case ets:info(?T, size) >= Max of
                true ->
                    sweep(),
                    evict(Max);
                false ->
                    ok
            end,
            ets:insert(?T, {{Account, Key}, Value, erlang:system_time(second)}),
            ok;
        _ ->
            stale
    end.

invalidate_account(Account) ->
    ets:match_delete(?T, {{Account, '_'}, '_', '_'}),
    bump(Account),
    ok.

invalidate_mailbox(Account, Mailbox) ->
    ets:match_delete(?T, {{Account, {'_', Mailbox, '_'}}, '_', '_'}),
    %% Search entries cover a set of mailboxes; drop the ones that include
    %% this one so changed mail are never served from a stale search result.
    [
        ets:delete(?T, {Account, {search, Boxes, Hash}})
     || [Boxes, Hash] <- ets:match(?T, {{Account, {search, '$1', '$2'}}, '_', '_'}),
        lists:member(Mailbox, Boxes)
    ],
    bump(Account),
    ok.

stats() -> #{entries => ets:info(?T, size)}.

sweep() ->
    Cut = erlang:system_time(second) - mailio_mcp_config:limit(cache_ttl, 300),
    ets:select_delete(?T, [{{'_', '_', '$1'}, [{'<', '$1', Cut}], [true]}]),
    ok.

evict(Max) ->
    case ets:info(?T, size) >= Max of
        false ->
            ok;
        true ->
            Oldest = lists:sublist(lists:keysort(3, ets:tab2list(?T)), Max div 4 + 1),
            [ets:delete(?T, K) || {K, _, _} <- Oldest],
            ok
    end.
