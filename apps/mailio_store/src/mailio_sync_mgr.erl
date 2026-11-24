%%% @doc Per-account sync engine.
%%%
%%% Owns the protocol adapter connection for an account, discovers and maps
%%% remote mailboxes to local mailbox documents, and drives the normalized
%%% adapter changes into the account writer. All cursoring lives here: each
%%% mailbox's `remote_state' is persisted in a `sync/imap/<mailboxId>'
%%% document and advanced only after the changes it describes are ingested,
%%% so a crash re-fetches and idempotently re-ingests.
%%%
%%% The adapter is dumb (see {@link mailio_adapter}); this module decides
%%% what to fetch, dedups via content-addressed ids in the writer, and
%%% reconciles flag updates and removals.
-module(mailio_sync_mgr).
-behaviour(gen_server).

-include("mailio_store.hrl").

-export([start_link/1, sync_all/1, sync_mailbox/2, reconcile_mailbox/2,
         mailboxes/1, watch_inbox/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {account_id :: binary(),
                db :: binary(),
                adapter :: module(),
                adapter_config :: map(),
                conn :: term() | undefined,
                caps = #{} :: map(),
                %% imap mailbox name -> local mailbox id
                mailbox_map = #{} :: #{binary() => binary()},
                watch :: term() | undefined,
                watch_mailbox :: binary() | undefined}).

%%====================================================================
%% API
%%====================================================================

%% Args: #{account_id, adapter => module(), adapter_config => map(),
%%         watch_mailbox => binary() | undefined}.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    AccountId = maps:get(account_id, Args),
    gen_server:start_link(via(AccountId), ?MODULE, Args, []).

-spec sync_all(binary()) -> {ok, map()} | {error, term()}.
sync_all(AccountId) ->
    gen_server:call(via(AccountId), sync_all, 60000).

-spec sync_mailbox(binary(), binary()) -> {ok, map()} | {error, term()}.
sync_mailbox(AccountId, ImapName) ->
    gen_server:call(via(AccountId), {sync_mailbox, ImapName}, 60000).

%% @doc Reconcile expunges for servers without QRESYNC: list the server's
%% current uids and remove any locally-known uid that is gone. This is a
%% full-mailbox pass, intended to run periodically (throttled), not on every
%% sync.
-spec reconcile_mailbox(binary(), binary()) -> {ok, map()} | {error, term()}.
reconcile_mailbox(AccountId, ImapName) ->
    gen_server:call(via(AccountId), {reconcile_mailbox, ImapName}, 60000).

-spec mailboxes(binary()) -> {ok, [binary()]}.
mailboxes(AccountId) ->
    gen_server:call(via(AccountId), mailboxes).

-spec watch_inbox(binary()) -> ok | {error, term()}.
watch_inbox(AccountId) ->
    gen_server:call(via(AccountId), watch_inbox).

via(AccountId) ->
    {via, mailio_registry, {sync, AccountId}}.

%%====================================================================
%% gen_server
%%====================================================================

init(Args) ->
    AccountId = maps:get(account_id, Args),
    Adapter = maps:get(adapter, Args),
    Config = maps:get(adapter_config, Args, #{}),
    Db = mailio_account:db_name(AccountId),
    {ok, _} = mailio_db:ensure_db(Db),
    State0 = #state{account_id = AccountId, db = Db, adapter = Adapter,
                    adapter_config = Config,
                    watch_mailbox = maps:get(watch_mailbox, Args, <<"INBOX">>)},
    case connect(State0) of
        {ok, State1} -> {ok, State1};
        {error, Reason} -> {stop, Reason}
    end.

handle_call(sync_all, _From, State) ->
    {Result, State1} = do_sync_all(State),
    {reply, Result, State1};
handle_call({sync_mailbox, ImapName}, _From, State) ->
    {Result, State1} = do_sync_mailbox(ImapName, State),
    {reply, Result, State1};
handle_call({reconcile_mailbox, ImapName}, _From, State) ->
    {Result, State1} = do_reconcile(ImapName, State),
    {reply, Result, State1};
handle_call(mailboxes, _From, State) ->
    {reply, {ok, maps:keys(State#state.mailbox_map)}, State};
handle_call(watch_inbox, _From, State) ->
    {Result, State1} = do_watch(State),
    {reply, Result, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% IDLE nudge: something changed in the watched mailbox. The watch holds the
%% only connection in IDLE, which cannot also run commands, so stop the
%% watch, resync, and resume watching.
handle_info({imap_idle_event, _Pid, _Event}, State) ->
    State1 = stop_watch(State),
    {_Result, State2} = do_sync_mailbox(State1#state.watch_mailbox, State1),
    State3 = start_watch(State2),
    {noreply, State3};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{adapter = Adapter, conn = Conn}) when Conn =/= undefined ->
    try Adapter:close(Conn) catch _:_ -> ok end,
    ok;
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Connection and mailbox discovery
%%====================================================================

connect(#state{adapter = Adapter, adapter_config = Config} = State) ->
    case Adapter:connect(Config) of
        {ok, Conn} ->
            Caps = Adapter:capabilities(Conn),
            State1 = State#state{conn = Conn, caps = Caps},
            {ok, discover_mailboxes(State1)};
        {error, Reason} ->
            {error, Reason}
    end.

discover_mailboxes(#state{adapter = Adapter, conn = Conn, db = Db} = State) ->
    case Adapter:list_mailboxes(Conn) of
        {ok, Remotes} ->
            Map = lists:foldl(
                fun(Remote, Acc) ->
                    LocalId = ensure_mailbox_doc(Db, Remote),
                    maps:put(maps:get(id, Remote), LocalId, Acc)
                end, #{}, Remotes),
            State#state{mailbox_map = Map};
        {error, _} ->
            State
    end.

%% Find-or-create a local mailbox doc for a remote folder, keyed by its
%% IMAP name (now queryable since the internal namespace is index-visible).
ensure_mailbox_doc(Db, Remote) ->
    ImapName = maps:get(id, Remote),
    case find_mailbox_by_imap_name(Db, ImapName) of
        {ok, LocalId} ->
            LocalId;
        not_found ->
            LocalId = mailio_id:mailbox_id(),
            Doc = mailio_mailbox:new(LocalId,
                    #{name => maps:get(name, Remote),
                      role => role_bin(maps:get(role, Remote, undefined)),
                      imap_name => ImapName,
                      imap_delimiter => maps:get(delimiter, Remote, <<"/">>)}),
            {ok, _, _} = mailio_db:put(Db, Doc),
            LocalId
    end.

find_mailbox_by_imap_name(Db, ImapName) ->
    Query = #{where => [{path, [?MAILIO_NS, <<"imap_name">>], ImapName}], limit => 1},
    case mailio_db:find(Db, Query, #{include_docs => true}) of
        {ok, [#{<<"id">> := <<?ID_MAILBOX, LocalId/binary>>} | _], _} -> {ok, LocalId};
        _ -> not_found
    end.

role_bin(undefined) -> null;
role_bin(Role) when is_atom(Role) -> atom_to_binary(Role, utf8).

%%====================================================================
%% Sync
%%====================================================================

do_sync_all(State) ->
    ImapNames = maps:keys(State#state.mailbox_map),
    {Stats, State1} =
        lists:foldl(fun(Name, {Acc, S}) ->
                        {R, S1} = do_sync_mailbox(Name, S),
                        {[{Name, R} | Acc], S1}
                    end, {[], State}, ImapNames),
    {{ok, #{mailboxes => Stats}}, State1}.

do_sync_mailbox(ImapName, #state{mailbox_map = Map} = State) ->
    case maps:get(ImapName, Map, undefined) of
        undefined ->
            {{error, unknown_mailbox}, State};
        LocalId ->
            run_sync(ImapName, LocalId, State)
    end.

run_sync(ImapName, LocalId,
         #state{adapter = Adapter, conn = Conn, db = Db} = State) ->
    RemoteState = load_cursor(Db, LocalId),
    case Adapter:fetch_changes_since(Conn, ImapName, RemoteState, #{}) of
        {ok, Changes, NewState, _More} ->
            Stats = apply_changes(State, ImapName, LocalId, Changes),
            store_cursor(Db, LocalId, NewState),
            {{ok, Stats}, State};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

apply_changes(State, ImapName, LocalId, Changes) ->
    lists:foldl(fun(Change, Stats) ->
                    apply_change(State, ImapName, LocalId, Change, Stats)
                end, #{added => 0, updated => 0, removed => 0, reset => 0}, Changes).

apply_change(State, ImapName, LocalId, {added, Info}, Stats) ->
    #state{adapter = Adapter, conn = Conn, account_id = AccountId} = State,
    Uid = maps:get(uid, Info),
    case fetch_raw(Adapter, Conn, ImapName, Uid) of
        {ok, Raw} ->
            Opts = #{keywords => maps:get(keywords, Info, []),
                     uid => Uid,
                     uidvalidity => maps:get(uidvalidity, Info, 0),
                     received_at => maps:get(internal_date, Info, undefined)},
            _ = mailio_account_writer:ingest(AccountId, LocalId, Raw, drop_undefined(Opts)),
            bump(Stats, added);
        {error, _} ->
            Stats
    end;
apply_change(State, _ImapName, LocalId, {updated, Info}, Stats) ->
    #state{account_id = AccountId} = State,
    Uid = maps:get(uid, Info),
    case mailio_account_writer:lookup_uid(AccountId, LocalId, Uid) of
        {ok, EmailId} ->
            _ = mailio_account_writer:apply_flags(AccountId, LocalId, EmailId,
                                                  maps:get(keywords, Info, [])),
            bump(Stats, updated);
        {error, not_found} ->
            Stats
    end;
apply_change(State, _ImapName, LocalId, {removed, Uid}, Stats) ->
    #state{account_id = AccountId} = State,
    case mailio_account_writer:lookup_uid(AccountId, LocalId, Uid) of
        {ok, EmailId} ->
            _ = mailio_account_writer:remove_member(AccountId, LocalId, EmailId),
            bump(Stats, removed);
        {error, not_found} ->
            Stats
    end;
apply_change(_State, _ImapName, _LocalId, reset, Stats) ->
    %% Full-resync signalling: handled by the next fetch returning all
    %% messages as `added' (content-addressed ids make this idempotent).
    bump(Stats, reset).

%%====================================================================
%% Reconcile (no-QRESYNC expunge detection)
%%====================================================================

do_reconcile(ImapName, #state{mailbox_map = Map} = State) ->
    case maps:get(ImapName, Map, undefined) of
        undefined ->
            {{error, unknown_mailbox}, State};
        LocalId ->
            run_reconcile(ImapName, LocalId, State)
    end.

run_reconcile(ImapName, LocalId,
              #state{adapter = Adapter, conn = Conn, db = Db,
                     account_id = AccountId} = State) ->
    case erlang:function_exported(Adapter, list_uids, 2) of
        false ->
            {{error, not_supported}, State};
        true ->
            case Adapter:list_uids(Conn, ImapName) of
                {ok, ServerUids} ->
                    ServerSet = sets:from_list(ServerUids),
                    Local = local_uidmaps(Db, LocalId),
                    Removed = lists:foldl(
                        fun({Uid, EmailId, DocId}, N) ->
                            case sets:is_element(Uid, ServerSet) of
                                true -> N;
                                false ->
                                    _ = mailio_account_writer:remove_member(
                                          AccountId, LocalId, EmailId),
                                    _ = mailio_db:delete(Db, DocId),
                                    N + 1
                            end
                        end, 0, Local),
                    {{ok, #{removed => Removed}}, State};
                {error, Reason} ->
                    {{error, Reason}, State}
            end
    end.

%% All {Uid, EmailId, UidmapDocId} the store knows for a local mailbox,
%% enumerated by the `uidmap/<mailbox>/' id namespace.
local_uidmaps(Db, LocalId) ->
    Prefix = <<?ID_UIDMAP, LocalId/binary, "/">>,
    case mailio_db:by_id_prefix(Db, Prefix) of
        {ok, Docs} ->
            [{maps:get(<<"uid">>, D), maps:get(<<"emailId">>, D), maps:get(<<"id">>, D)}
             || D <- Docs, maps:is_key(<<"uid">>, D)];
        _ ->
            []
    end.

fetch_raw(Adapter, Conn, ImapName, Uid) ->
    Self = self(),
    Ref = make_ref(),
    Sink = fun(Bytes) -> Self ! {Ref, iolist_to_binary(Bytes)}, ok end,
    case Adapter:fetch_message(Conn, ImapName, Uid, Sink) of
        {ok, _} ->
            receive {Ref, Raw} -> {ok, Raw} after 0 -> {error, no_data} end;
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Cursor persistence
%%====================================================================

load_cursor(Db, LocalId) ->
    case mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>) of
        {ok, #{<<"remote_state">> := S}} when is_binary(S), S =/= <<>> -> S;
        _ -> initial
    end.

store_cursor(Db, LocalId, RemoteState) ->
    Doc = #{<<"id">> => <<?ID_SYNC_IMAP, LocalId/binary>>,
            <<"mailboxId">> => LocalId,
            <<"remote_state">> => state_bin(RemoteState),
            <<"lastSyncAt">> => erlang:system_time(second)},
    Doc1 = case mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>) of
               {ok, #{<<"_rev">> := Rev}} -> Doc#{<<"_rev">> => Rev};
               _ -> Doc
           end,
    {ok, _, _} = mailio_db:put(Db, Doc1),
    ok.

state_bin(initial) -> initial_marker();
state_bin(Bin) when is_binary(Bin) -> Bin.

initial_marker() -> <<>>.

%%====================================================================
%% IDLE watch
%%====================================================================

do_watch(#state{caps = Caps} = State) ->
    case maps:get(idle, Caps, false) of
        false ->
            {{error, idle_not_supported}, State};
        true ->
            State1 = start_watch(State),
            case State1#state.watch of
                undefined -> {{error, watch_failed}, State1};
                _ -> {ok, State1}
            end
    end.

start_watch(#state{adapter = Adapter, conn = Conn, watch = undefined,
                   watch_mailbox = ImapName} = State) ->
    case Adapter:watch(Conn, ImapName, self()) of
        {ok, Ref} -> State#state{watch = Ref};
        {error, _} -> State
    end;
start_watch(State) ->
    State.

stop_watch(#state{adapter = Adapter, conn = Conn, watch = Ref} = State)
  when Ref =/= undefined ->
    _ = Adapter:unwatch(Conn, Ref),
    State#state{watch = undefined};
stop_watch(State) ->
    State.

%%====================================================================
%% Helpers
%%====================================================================

bump(Stats, Key) -> maps:update_with(Key, fun(N) -> N + 1 end, 1, Stats).

drop_undefined(Map) ->
    maps:filter(fun(_K, V) -> V =/= undefined end, Map).
