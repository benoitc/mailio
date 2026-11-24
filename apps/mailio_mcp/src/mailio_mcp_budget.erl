%%% @doc Result budget. A search result is serialized once; if it exceeds
%%% the byte budget, long strings are cut first and then trailing hits are
%%% dropped, with truncation and continuation info returned.
-module(mailio_mcp_budget).
-compile({no_auto_import, [size/1]}).
-export([max_bytes/0, page_size/1, size/1, shorten/2, fit/4, fit/5]).

-define(MAX_BYTES, 8192).
-define(PAGE, 20).

max_bytes() -> mailio_mcp_config:limit(max_result_bytes, ?MAX_BYTES).

page_size(undefined) ->
    mailio_mcp_config:limit(page_size, ?PAGE);
page_size(N) when is_integer(N), N >= 1 ->
    min(N, mailio_mcp_config:limit(page_size, ?PAGE));
page_size(_) ->
    mailio_mcp_config:limit(page_size, ?PAGE).

size(Term) -> iolist_size(json:encode(Term)).

%% @doc Cut a binary to at most Max characters, marking the cut.
-spec shorten(term(), non_neg_integer()) -> term().
shorten(Bin, Max) when is_binary(Bin) ->
    case string:length(Bin) =< Max of
        true -> Bin;
        false -> iolist_to_binary([string:slice(Bin, 0, Max - 1), <<"…"/utf8>>])
    end;
shorten(Other, _) ->
    Other.

%% @doc Fit Hits into the budget.
%% Envelope is the result map without hits. Cursor is called with the last
%% included hit and the count of dropped hits and returns the next cursor
%% (or undefined). Returns the final result map.
-spec fit(map(), [map()], fun((map()) -> binary() | undefined), boolean()) -> map().
fit(Envelope, Hits0, CursorFun, MoreAfter) ->
    fit(Envelope, Hits0, CursorFun, MoreAfter, <<"hits">>).

%% @doc As fit/4 with a chosen key for the list.
fit(Envelope, Hits0, CursorFun, MoreAfter, Key) ->
    Max = max_bytes(),
    Hits = [shorten_hit(H, 120, 160) || H <- Hits0],
    fit_loop(Envelope, Hits, length(Hits), CursorFun, MoreAfter, Max, Key).

fit_loop(Env, Hits, N, CursorFun, More, Max, Key) ->
    Kept = lists:sublist(Hits, N),
    Truncated = N < length(Hits),
    HasMore = Truncated orelse More,
    Cursor =
        case {HasMore, Kept} of
            {true, [_ | _]} -> CursorFun(lists:last(Kept));
            _ -> undefined
        end,
    R0 = Env#{Key => Kept, <<"returned">> => length(Kept)},
    R1 =
        case Truncated of
            true ->
                R0#{
                    <<"truncated">> => #{
                        <<"reason">> => <<"result_budget">>,
                        <<"dropped">> => length(Hits) - N
                    }
                };
            false ->
                R0
        end,
    R =
        case Cursor of
            undefined -> R1;
            C -> R1#{<<"next_cursor">> => C}
        end,
    case size(R) =< Max orelse N =< 1 of
        true -> R;
        false -> fit_loop(Env, Hits, N - 1, CursorFun, More, Max, Key)
    end.

shorten_hit(H, SubjMax, ExMax) ->
    maps:map(
        fun
            (<<"subject">>, V) -> shorten(V, SubjMax);
            (<<"excerpt">>, V) -> shorten(V, ExMax);
            (<<"from">>, V) -> shorten(V, 100);
            (<<"to">>, V) when is_binary(V) -> shorten(V, 100);
            (_, V) -> V
        end,
        H
    ).
