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
-export([get/2, put/3, invalidate_account/1, invalidate_mailbox/2, stats/0]).

-define(T, mailio_mcp_cache_tab).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = ets:new(?T, [named_table, public, set, {read_concurrency, true}]),
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

put(Account, Key, Value) ->
    Max = mailio_mcp_config:limit(cache_max_entries, 2000),
    case ets:info(?T, size) >= Max of
        true ->
            sweep(),
            evict(Max);
        false ->
            ok
    end,
    ets:insert(?T, {{Account, Key}, Value, erlang:system_time(second)}),
    ok.

invalidate_account(Account) ->
    ets:match_delete(?T, {{Account, '_'}, '_', '_'}),
    ok.

invalidate_mailbox(Account, Mailbox) ->
    ets:match_delete(?T, {{Account, {'_', Mailbox, '_'}}, '_', '_'}),
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
