%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Durable state: occurrences, sync checkpoints, drafts, send records
%%% and the signing secret. Backed by dets under the data directory. It is
%%% independent of the evictable cache in mailio_mcp_cache.
-module(mailio_mcp_store).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, terminate/2]).
-export([
    secret/0,
    observe/2,
    purge_mailbox/3,
    put/3,
    get/2,
    delete/2,
    insert_new/3,
    fold/3,
    all/1
]).

-define(TABLES, [occ, ckpt, draft, send, meta, pop3idx]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Dir = mailio_mcp_config:data_dir(),
    ok = filelib:ensure_path(Dir),
    lists:foreach(
        fun(T) ->
            File = filename:join(Dir, atom_to_list(T) ++ ".dets"),
            {ok, T} = dets:open_file(T, [{file, File}, {type, set}, {auto_save, 1000}])
        end,
        ?TABLES
    ),
    ensure_secret(),
    {ok, #{}}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

terminate(_, _) ->
    lists:foreach(fun dets:close/1, ?TABLES).

ensure_secret() ->
    case dets:lookup(meta, secret) of
        [{secret, _}] -> ok;
        [] -> ok = dets:insert(meta, {secret, crypto:strong_rand_bytes(32)})
    end.

secret() ->
    [{secret, S}] = dets:lookup(meta, secret),
    S.

%% @doc Record that a message occurrence was seen. The key is the
%% adapter-native identity with its scope, so a retry or restart returns
%% the original first_seen_at and never creates a second record.
-spec observe(term(), map()) -> {new | known, integer()}.
observe(Key, Info) ->
    Now = erlang:system_time(second),
    case dets:insert_new(occ, {Key, Now, Info}) of
        true ->
            {new, Now};
        false ->
            [{Key, First, _}] = dets:lookup(occ, Key),
            {known, First}
    end.

%% @doc Drop occurrences of a mailbox recorded under another UIDVALIDITY.
purge_mailbox(Account, Mailbox, UidValidity) ->
    MS = [
        {
            {{imap, Account, Mailbox, '$1', '_'}, '_', '_'},
            [{'=/=', '$1', UidValidity}],
            [true]
        }
    ],
    dets:select_delete(occ, MS).

put(Table, Key, Value) -> ok = dets:insert(Table, {Key, Value}).

get(Table, Key) ->
    case dets:lookup(Table, Key) of
        [{Key, V}] -> {ok, V};
        [] -> error
    end.

delete(Table, Key) -> dets:delete(Table, Key).

insert_new(Table, Key, Value) -> dets:insert_new(Table, {Key, Value}).

fold(Table, Fun, Acc) ->
    dets:foldl(
        fun
            ({K, V}, A) -> Fun(K, V, A);
            ({K, T, I}, A) -> Fun(K, {T, I}, A)
        end,
        Acc,
        Table
    ).

all(Table) -> fold(Table, fun(K, V, A) -> [{K, V} | A] end, []).
