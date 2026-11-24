%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Counters for backend requests and bytes per account. Used to
%%% show the network cost of a tool call. Holds no mail content.
-module(mailio_mcp_stats).
-export([init/0, bump/4, snapshot/0, reset/0]).

-define(T, mailio_mcp_stats_tab).

init() ->
    _ =
        case ets:whereis(?T) of
            undefined -> ets:new(?T, [named_table, public, set, {write_concurrency, true}]);
            _ -> ok
        end,
    ok.

%% Kind is a short label such as imap_cmd, smtp_cmd or pop3_cmd.
bump(Account, Kind, Requests, Bytes) ->
    try
        _ = ets:update_counter(?T, {Account, Kind, req}, Requests, {{Account, Kind, req}, 0}),
        _ = ets:update_counter(?T, {Account, Kind, bytes}, Bytes, {{Account, Kind, bytes}, 0}),
        ok
    catch
        error:badarg -> ok
    end.

snapshot() ->
    maps:from_list(ets:tab2list(?T)).

reset() ->
    ets:delete_all_objects(?T),
    ok.
