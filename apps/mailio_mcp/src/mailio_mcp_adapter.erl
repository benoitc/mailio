%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Adapter behaviour and dispatch. Each protocol module implements
%%% the same functions over an account map. Jmap and API-based adapters can
%%% be added behind this module without changing the tools.
-module(mailio_mcp_adapter).

-callback capabilities(map()) -> map().
-callback list_mailboxes(map(), boolean()) -> {ok, [map()]} | {error, term()}.
-callback search(map(), map()) -> {ok, [map()], map()} | {error, term()}.
-callback read_message(map(), map(), map()) -> {ok, map()} | {error, term()}.
-callback fetch_part(map(), map(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
-callback thread(map(), map(), pos_integer()) -> {ok, [map()], boolean()} | {error, term()}.
-callback changes(map(), binary(), map() | undefined) -> {ok, map()} | {error, term()}.
-callback fingerprint(map(), map(), pos_integer()) -> {ok, binary()} | {error, term()}.
-callback excerpts(map(), [map()], binary() | undefined) -> map().

-optional_callbacks([wait_for_change/4]).

%% Wait until the mailbox differs from the checkpoint, without polling.
-callback wait_for_change(map(), binary(), map() | undefined, non_neg_integer()) ->
    changed | timeout | unsupported | {error, term()}.

-export([module/1, call/3, wait_for_change/4]).

module(#{incoming := #{protocol := imap}}) -> mailio_mcp_imap;
module(#{incoming := #{protocol := pop3}}) -> mailio_mcp_pop3;
module(_) -> error(unsupported_protocol).

call(Account, Fun, Args) ->
    apply(module(Account), Fun, [Account | Args]).

%% @doc Wait for a change on adapters that can be told about one (IMAP with
%% IDLE). Others report `unsupported'.
-spec wait_for_change(map(), binary(), map() | undefined, non_neg_integer()) ->
    changed | timeout | unsupported | {error, term()}.
wait_for_change(Account, Box, Prev, Timeout) ->
    Mod = module(Account),
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, wait_for_change, 4) of
        true -> Mod:wait_for_change(Account, Box, Prev, Timeout);
        false -> unsupported
    end.
