%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
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

-export([
    start_link/1,
    sync_all/1,
    sync_mailbox/2,
    reconcile_mailbox/2,
    mailboxes/1,
    watch_inbox/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RETRY_MIN, 1000).
-define(RETRY_MAX, 300000).

-record(state, {
    account_id :: binary(),
    db :: binary(),
    adapter :: module(),
    adapter_config :: map(),
    conn :: term() | undefined,
    caps = #{} :: map(),
    %% imap mailbox name -> local mailbox id
    mailbox_map = #{} :: #{binary() => binary()},
    watch :: term() | undefined,
    watch_mailbox :: binary() | undefined,
    %% reconnect schedule while the server is unreachable
    retry_min = ?RETRY_MIN :: pos_integer(),
    retry_max = ?RETRY_MAX :: pos_integer(),
    retry_ms = ?RETRY_MIN :: pos_integer(),
    retry_timer :: reference() | undefined
}).

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
    State0 = #state{
        account_id = AccountId,
        db = Db,
        adapter = Adapter,
        adapter_config = Config,
        watch_mailbox = maps:get(watch_mailbox, Args, <<"INBOX">>),
        retry_min = maps:get(connect_retry_ms, Args, ?RETRY_MIN),
        retry_ms = maps:get(connect_retry_ms, Args, ?RETRY_MIN)
    },
    %% An unreachable server is not a reason to fail: the account stays up and
    %% the connection is retried with a growing delay.
    {ok, try_connect(State0)}.

handle_call(Req, _From, #state{conn = undefined} = State) when
    Req =:= sync_all;
    element(1, Req) =:= sync_mailbox;
    element(1, Req) =:= reconcile_mailbox;
    Req =:= watch_inbox
->
    {reply, {error, not_connected}, State};
handle_call(sync_all, _From, State) ->
    {Result, State1} = do_sync_all(State),
    {reply, Result, retire_dead_connection(Result, State1)};
handle_call({sync_mailbox, ImapName}, _From, State) ->
    {Result, State1} = do_sync_mailbox(ImapName, State),
    {reply, Result, retire_dead_connection(Result, State1)};
handle_call({reconcile_mailbox, ImapName}, _From, State) ->
    {Result, State1} = do_reconcile(ImapName, State),
    {reply, Result, retire_dead_connection(Result, State1)};
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
handle_info(reconnect, State) ->
    {noreply, try_connect(State#state{retry_timer = undefined})};
handle_info({imap_idle_event, _Pid, _Event}, #state{conn = undefined} = State) ->
    {noreply, State};
handle_info({imap_idle_event, _Pid, _Event}, State) ->
    State1 = stop_watch(State),
    {_Result, State2} = do_sync_mailbox(State1#state.watch_mailbox, State1),
    State3 = start_watch(State2),
    {noreply, State3};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{adapter = Adapter, conn = Conn}) when Conn =/= undefined ->
    try
        Adapter:close(Conn)
    catch
        _:_ -> ok
    end,
    ok;
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Connection and mailbox discovery
%%====================================================================

%% A connection that gave up for good (the server sent more than it may) answers
%% the same error to every later call. It is closed and a new one is made, so the
%% next sync is not refused for as long as the account lives.
retire_dead_connection(Result, #state{adapter = Adapter, conn = Conn} = State) when
    Conn =/= undefined
->
    case mentions(response_too_large, Result) of
        false ->
            State;
        true ->
            try
                Adapter:close(Conn)
            catch
                _:_ -> ok
            end,
            try_connect(State#state{conn = undefined, watch = undefined})
    end;
retire_dead_connection(_Result, State) ->
    State.

mentions(Atom, Atom) -> true;
mentions(Atom, T) when is_map(T) -> mentions(Atom, maps:to_list(T));
mentions(Atom, T) when is_tuple(T) -> mentions(Atom, tuple_to_list(T));
mentions(Atom, [H | T]) -> mentions(Atom, H) orelse mentions(Atom, T);
mentions(_, _) -> false.

%% Connect now; on failure schedule another attempt, doubling the delay.
try_connect(State) ->
    case connect(State) of
        {ok, State1} ->
            State1#state{retry_ms = State1#state.retry_min};
        {error, Reason} ->
            logger:warning(#{
                msg => "mail server unreachable, will retry",
                account => State#state.account_id,
                reason => Reason,
                retry_in_ms => State#state.retry_ms
            }),
            Timer = erlang:send_after(State#state.retry_ms, self(), reconnect),
            State#state{
                conn = undefined,
                retry_timer = Timer,
                retry_ms = min(State#state.retry_ms * 2, State#state.retry_max)
            }
    end.

connect(#state{adapter = Adapter, adapter_config = Config} = State) ->
    try Adapter:connect(Config) of
        {ok, Conn} ->
            Caps = Adapter:capabilities(Conn),
            State1 = State#state{conn = Conn, caps = Caps},
            {ok, discover_mailboxes(State1)};
        {error, Reason} ->
            {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

discover_mailboxes(#state{adapter = Adapter, conn = Conn, db = Db} = State) ->
    case Adapter:list_mailboxes(Conn) of
        {ok, Remotes} ->
            Map = lists:foldl(
                fun(Remote, Acc) ->
                    LocalId = ensure_mailbox_doc(Db, Remote),
                    maps:put(maps:get(id, Remote), LocalId, Acc)
                end,
                #{},
                Remotes
            ),
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
            Doc = mailio_mailbox:new(
                LocalId,
                #{
                    name => maps:get(name, Remote),
                    role => role_bin(maps:get(role, Remote, undefined)),
                    imap_name => ImapName,
                    imap_delimiter => maps:get(delimiter, Remote, <<"/">>)
                }
            ),
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
        lists:foldl(
            fun(Name, {Acc, S}) ->
                {R, S1} = do_sync_mailbox(Name, S),
                {[{Name, R} | Acc], S1}
            end,
            {[], State},
            ImapNames
        ),
    {{ok, #{mailboxes => Stats}}, State1}.

do_sync_mailbox(ImapName, #state{mailbox_map = Map} = State) ->
    case maps:get(ImapName, Map, undefined) of
        undefined ->
            {{error, unknown_mailbox}, State};
        LocalId ->
            run_sync(ImapName, LocalId, State)
    end.

run_sync(
    ImapName,
    LocalId,
    #state{adapter = Adapter, conn = Conn, db = Db} = State
) ->
    Stored = load_cursor(Db, LocalId),
    case Stored =:= initial orelse reset_pending(Db, LocalId) of
        true ->
            %% A first read is a full read, and it also brings in line what an
            %% earlier one that failed halfway left behind: what was stored then
            %% may have changed on the server since. So is a read that must
            %% replace the UIDs held because the mailbox was recreated.
            full_sync(resync, ImapName, LocalId, State);
        false ->
            RemoteState = Stored,
            Fetch = fun(Cursor) -> Adapter:fetch_changes_since(Conn, ImapName, Cursor, #{}) end,
            %% Each page is applied, and only then is the cursor it leads to kept: a
            %% page that cannot be applied leaves the cursor where it was, so it is
            %% tried again.
            Step = fun(Changes, Next, Stats) ->
                case resync_mode(Changes) of
                    none ->
                        case apply_changes(State, ImapName, LocalId, Changes, Stats) of
                            {ok, Stats1} ->
                                store_cursor(Db, LocalId, Next),
                                {ok, Stats1};
                            {error, _} = Error ->
                                {stop, Error}
                        end;
                    Mode ->
                        {stop, {signal, Mode}}
                end
            end,
            case mailio_sync_pages:walk(Fetch, RemoteState, page_opts(), new_stats(), Step) of
                {ok, Stats, _Final} ->
                    {{ok, Stats}, State};
                {stopped, {signal, Mode}} ->
                    full_sync(Mode, ImapName, LocalId, State);
                {stopped, {error, Reason}} ->
                    {{error, Reason}, State};
                {error, Reason} ->
                    {{error, Reason}, State}
            end
    end.

page_opts() ->
    #{max_pages => mailio_config:get(sync_max_pages, 100000)}.

new_stats() ->
    #{added => 0, updated => 0, removed => 0, reset => 0}.

%% `reset': the UIDs we hold mean other messages now (UIDVALIDITY changed).
%% `resync': there were too many changes to list.
resync_mode(Changes) ->
    case {lists:member(reset, Changes), lists:member(resync, Changes)} of
        {true, _} -> reset;
        {false, true} -> resync;
        {false, false} -> none
    end.

%% The mailbox is read in full and brought in line, and only then is the cursor
%% it leads to kept: a failure is retried, not skipped.
full_sync(Mode, ImapName, LocalId, #state{db = Db} = State) ->
    Mode =:= reset andalso mark_reset(Db, LocalId),
    case full_resync(Mode, ImapName, LocalId, State) of
        {ok, Stats, FullState} ->
            store_cursor(Db, LocalId, FullState),
            clear_reset(Db, LocalId),
            {{ok, Stats}, State};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

%% Pages are applied as they come and not kept, so the memory a full read needs
%% is the UIDs seen (as ranges, and with a limit), not the mailbox. When the
%% pages end, whatever the store holds that the server did not list is removed.
%% A page that says the mailbox was recreated (`reset') starts the read again
%% and, from then on, every UID held is replaced: nothing from two generations is
%% mixed, whatever the adapter said about identities.
full_resync(Mode, ImapName, LocalId, State) ->
    %% UIDs are replaced when the mailbox is known to have been recreated, now or
    %% in an earlier try that did not finish.
    Replace = Mode =:= reset orelse reset_pending(State#state.db, LocalId),
    full_resync(Mode, ImapName, LocalId, State, 3, Replace).

full_resync(_Mode, _ImapName, _LocalId, _State, 0, _Replace) ->
    {error, mailbox_keeps_changing};
full_resync(Mode, ImapName, LocalId, State, Attempts, Replace) ->
    #state{adapter = Adapter, conn = Conn} = State,
    Fetch = fun(Cursor) -> Adapter:fetch_changes_since(Conn, ImapName, Cursor, #{}) end,
    Limit = mailio_config:get(sync_max_listed_uids, 10000000),
    Acc0 = #{
        seen => mailio_uid_set:new(Limit), removed => #{}, stats => new_stats(), limit => Limit
    },
    Step = fun(Changes, _Next, Acc) ->
        case resync_mode(Changes) of
            none -> resync_page(State, ImapName, LocalId, Replace, Changes, Acc);
            Signal -> {stop, {signal, Signal}}
        end
    end,
    case mailio_sync_pages:walk(Fetch, initial, page_opts(), Acc0, Step) of
        {ok, #{seen := Seen, removed := Removed, stats := Stats}, Final} ->
            finish_resync(State, LocalId, Seen, Removed, Stats, Final);
        {stopped, {signal, Signal}} ->
            %% remembered on disk: a restart of this process must not forget it
            Signal =:= reset andalso mark_reset(State#state.db, LocalId),
            full_resync(
                Mode, ImapName, LocalId, State, Attempts - 1, Replace orelse Signal =:= reset
            );
        {stopped, {error, _} = Error} ->
            Error;
        {error, _} = Error ->
            Error
    end.

resync_page(State, ImapName, LocalId, Replace, Changes, #{seen := Seen, stats := Stats} = Acc) ->
    resync_page(State, ImapName, LocalId, Replace, Changes, Seen, Stats, Acc).

%% A UID the server reports gone after it was listed, on this page or an earlier
%% one, is gone: it leaves the store now and is not kept by the final cleanup. The
%% changes come in the order they happened, so one listed again later is back.
resync_removed(State, LocalId, Uid, Stats, #{removed := Removed, limit := Limit} = Acc) ->
    Stats1 =
        case remove_local_uid(State#state.account_id, LocalId, Uid) of
            ok -> bump(Stats, removed);
            already_gone -> Stats
        end,
    case map_size(Removed) >= Limit andalso not is_map_key(Uid, Removed) of
        true -> {error, mailbox_too_large_to_resync};
        false -> {ok, Stats1, Acc#{removed := Removed#{Uid => true}}}
    end.

%% The changes of a page in the order they came: an update for a message listed
%% before it (on this page or an earlier one) must land after it.
resync_page(_State, _ImapName, _LocalId, _Replace, [], Seen, Stats, Acc) ->
    {ok, Acc#{seen := Seen, stats := Stats}};
resync_page(State, ImapName, LocalId, Replace, [{added, Info} | Rest], Seen, Stats, Acc) ->
    case mailio_uid_set:add(maps:get(uid, Info), Seen) of
        {error, too_many} ->
            {stop, {error, mailbox_too_large_to_resync}};
        {ok, Seen1} ->
            case sync_one(State, ImapName, LocalId, Info, Replace) of
                {error, Why} ->
                    {stop, {error, {resync_incomplete, Why}}};
                Done ->
                    Acc1 = maps:update_with(
                        removed, fun(R) -> maps:remove(maps:get(uid, Info), R) end, Acc
                    ),
                    resync_page(
                        State, ImapName, LocalId, Replace, Rest, Seen1, bump(Stats, Done), Acc1
                    )
            end
    end;
resync_page(State, ImapName, LocalId, Replace, [{removed, Uid} | Rest], Seen, Stats, Acc) ->
    case resync_removed(State, LocalId, Uid, Stats, Acc) of
        {ok, Stats1, Acc1} ->
            resync_page(State, ImapName, LocalId, Replace, Rest, Seen, Stats1, Acc1);
        {error, _} = Error ->
            {stop, Error}
    end;
resync_page(State, ImapName, LocalId, Replace, [{updated, Info} | Rest], Seen, Stats, Acc) ->
    #state{account_id = AccountId} = State,
    Uid = maps:get(uid, Info),
    case mailio_account_writer:lookup_uid(AccountId, LocalId, Uid) of
        {ok, EmailId} ->
            case
                mailio_account_writer:apply_flags(
                    AccountId, LocalId, EmailId, maps:get(keywords, Info, [])
                )
            of
                ok ->
                    resync_page(
                        State, ImapName, LocalId, Replace, Rest, Seen, bump(Stats, updated), Acc
                    );
                {error, Why} ->
                    {stop, {error, {resync_incomplete, Why}}}
            end;
        {error, not_found} ->
            resync_page(State, ImapName, LocalId, Replace, Rest, Seen, Stats, Acc)
    end;
resync_page(State, ImapName, LocalId, Replace, [_Other | Rest], Seen, Stats, Acc) ->
    resync_page(State, ImapName, LocalId, Replace, Rest, Seen, Stats, Acc).

%% What the server listed is in line. What is held and was not listed is gone.
finish_resync(State, LocalId, Seen, Gone, Stats, Final) ->
    Listed = mailio_uid_set:to_lookup(Seen),
    case remove_unlisted(State, LocalId, Listed, Gone) of
        {ok, N} -> {ok, Stats#{removed => maps:get(removed, Stats) + N, reset => 1}, Final};
        {error, _} = Error -> Error
    end.

%% Remove every local UID that is not in `Listed', walking the local ones batch
%% by batch to the last, so that a mailbox of any size is cleaned and not its first
%% thousand. The cursor is only kept when this has reached the end.
remove_unlisted(State, LocalId, Listed) ->
    remove_unlisted(State, LocalId, Listed, #{}).

%% `Gone' holds the UIDs the server reported removed after listing them: they
%% are not kept even though the listing holds them.
remove_unlisted(#state{account_id = AccountId, db = Db}, LocalId, Listed, Gone0) ->
    Fun = fun(Maps, N) ->
        Gone = [
            Uid
         || {Uid, _, _} <- Maps,
            not mailio_uid_set:member(Uid, Listed) orelse is_map_key(Uid, Gone0)
        ],
        {ok, N + length([ok || Uid <- Gone, remove_local_uid(AccountId, LocalId, Uid) =:= ok])}
    end,
    fold_local_uidmaps(Db, LocalId, Fun, 0).

remove_local_uid(AccountId, LocalId, Uid) ->
    case mailio_account_writer:remove_uid(AccountId, LocalId, Uid) of
        ok -> ok;
        {error, not_found} -> already_gone
    end.

%% One message of a full read. A UID we already know is only the same message if
%% it was seen under the same UIDVALIDITY: a recreated mailbox reuses numbers
%% for other messages, so an old mapping is dropped and the message fetched.
sync_one(State, ImapName, LocalId, Info, Replace) ->
    #state{account_id = AccountId, db = Db} = State,
    Uid = maps:get(uid, Info),
    case mailio_account_writer:lookup_uid(AccountId, LocalId, Uid) of
        {ok, _EmailId} when Replace ->
            replace_one(State, ImapName, LocalId, Info);
        {ok, EmailId} ->
            case same_generation(Db, EmailId, LocalId, Uid, Info) of
                true ->
                    case
                        mailio_account_writer:apply_flags(
                            AccountId, LocalId, EmailId, maps:get(keywords, Info, [])
                        )
                    of
                        ok -> updated;
                        {error, _} -> replace_one(State, ImapName, LocalId, Info)
                    end;
                false ->
                    replace_one(State, ImapName, LocalId, Info)
            end;
        {error, not_found} ->
            fetch_one(State, ImapName, LocalId, Info)
    end.

replace_one(State, ImapName, LocalId, Info) ->
    _ = mailio_account_writer:remove_uid(State#state.account_id, LocalId, maps:get(uid, Info)),
    fetch_one(State, ImapName, LocalId, Info).

fetch_one(State, ImapName, LocalId, Info) ->
    case ingest_added(State, ImapName, LocalId, Info) of
        ok -> added;
        {error, _} = Error -> Error
    end.

same_generation(Db, EmailId, LocalId, Uid, Info) ->
    case maps:find(uidvalidity, Info) of
        error ->
            true;
        {ok, Validity} ->
            case mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>) of
                {ok, Email} ->
                    lists:any(
                        fun(E) ->
                            maps:get(<<"uid">>, E, undefined) =:= Uid andalso
                                maps:get(<<"uidvalidity">>, E, undefined) =:= Validity
                        end,
                        mailio_email:imap_entries(Email, LocalId)
                    );
                {error, not_found} ->
                    false
            end
    end.

apply_changes(State, ImapName, LocalId, Changes, Stats0) ->
    {Stats, Failures} = lists:foldl(
        fun(Change, {Stats, Failed}) ->
            case apply_change(State, ImapName, LocalId, Change, Stats) of
                {error, _} = Error -> {Stats, [Error | Failed]};
                Stats1 -> {Stats1, Failed}
            end
        end,
        {Stats0, []},
        Changes
    ),
    case Failures of
        [] -> {ok, Stats};
        [{error, Why} | _] -> {error, {sync_incomplete, length(Failures), Why}}
    end.

apply_change(State, ImapName, LocalId, {added, Info}, Stats) ->
    case ingest_added(State, ImapName, LocalId, Info) of
        ok -> bump(Stats, added);
        {error, _} = Error -> Error
    end;
apply_change(State, _ImapName, LocalId, {updated, Info}, Stats) ->
    #state{account_id = AccountId} = State,
    Uid = maps:get(uid, Info),
    case mailio_account_writer:lookup_uid(AccountId, LocalId, Uid) of
        {ok, EmailId} ->
            case
                mailio_account_writer:apply_flags(
                    AccountId, LocalId, EmailId, maps:get(keywords, Info, [])
                )
            of
                ok -> bump(Stats, updated);
                {error, _} = Error -> Error
            end;
        {error, not_found} ->
            Stats
    end;
apply_change(State, _ImapName, LocalId, {removed, Uid}, Stats) ->
    #state{account_id = AccountId} = State,
    case mailio_account_writer:remove_uid(AccountId, LocalId, Uid) of
        ok -> bump(Stats, removed);
        {error, not_found} -> Stats
    end;
apply_change(_State, _ImapName, _LocalId, Signal, Stats) when
    Signal =:= reset; Signal =:= resync
->
    %% handled by run_sync before any change is applied
    bump(Stats, reset).

ingest_added(State, ImapName, LocalId, Info) ->
    #state{adapter = Adapter, conn = Conn, account_id = AccountId} = State,
    Uid = maps:get(uid, Info),
    case fetch_raw(Adapter, Conn, ImapName, Uid, maps:get(uidvalidity, Info, undefined)) of
        {ok, Raw} ->
            Opts = #{
                keywords => maps:get(keywords, Info, []),
                uid => Uid,
                uidvalidity => maps:get(uidvalidity, Info, 0),
                received_at => maps:get(internal_date, Info, undefined)
            },
            case mailio_account_writer:ingest(AccountId, LocalId, Raw, drop_undefined(Opts)) of
                {ok, _} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

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

run_reconcile(
    ImapName,
    LocalId,
    #state{adapter = Adapter, conn = Conn, db = Db, account_id = AccountId} = State
) ->
    case erlang:function_exported(Adapter, list_uids, 2) of
        false ->
            {{error, not_supported}, State};
        true ->
            maybe
                {ok, ServerUids} ?= list_remote_uids(Adapter, Conn, ImapName),
                {ok, Listed} ?= uid_lookup(ServerUids),
                {ok, Removed} ?= remove_unlisted(State, LocalId, Listed),
                {{ok, #{removed => Removed}}, State}
            else
                {error, Reason} -> {{error, Reason}, State}
            end
    end.

%% With the limit given to the adapter that can use it, so that a mailbox beyond
%% it is refused as it is read and not after every number is held.
list_remote_uids(Adapter, Conn, ImapName) ->
    case adapter_has(Adapter, list_uids, 3) of
        true ->
            Limit = mailio_config:get(sync_max_listed_uids, 10000000),
            Adapter:list_uids(Conn, ImapName, #{max => Limit});
        false ->
            Adapter:list_uids(Conn, ImapName)
    end.

uid_lookup(Uids) ->
    Limit = mailio_config:get(sync_max_listed_uids, 10000000),
    Add = fun
        (U, {ok, Set}) -> mailio_uid_set:add(U, Set);
        (_, Error) -> Error
    end,
    case lists:foldl(Add, {ok, mailio_uid_set:new(Limit)}, Uids) of
        {ok, Set} -> {ok, mailio_uid_set:to_lookup(Set)};
        {error, too_many} -> {error, mailbox_too_large_to_resync}
    end.

%% The {Uid, EmailId, UidmapDocId} the store knows for a local mailbox,
%% enumerated by the `uidmap/<mailbox>/' id namespace, a batch at a time. A
%% listing that fails is an error, never an empty one: an empty one would read as
%% "everything is gone".
fold_local_uidmaps(Db, LocalId, Fun, Acc) ->
    Batch = fun(Docs, A) ->
        Maps = [
            {maps:get(<<"uid">>, D), maps:get(<<"emailId">>, D), maps:get(<<"id">>, D)}
         || D <- Docs, maps:is_key(<<"uid">>, D)
        ],
        Fun(Maps, A)
    end,
    %% the current namespace, then the mappings an older version wrote
    maybe
        {ok, Acc1} ?=
            mailio_db:fold_id_prefix(Db, <<?ID_UIDMAP2, LocalId/binary, "/">>, 500, Batch, Acc),
        mailio_db:fold_id_prefix(Db, <<?ID_UIDMAP, LocalId/binary, "/">>, 500, Batch, Acc1)
    end.

%% The marker that the UIDs held for a mailbox may mean other messages: it stays
%% until a full read has replaced them, whatever happens in between.
mark_reset(Db, LocalId) ->
    Id = <<?ID_SYNC_RESET, LocalId/binary>>,
    case mailio_db:get(Db, Id) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            {ok, _, _} = mailio_db:put(Db, #{<<"id">> => Id}),
            ok
    end.

reset_pending(Db, LocalId) ->
    case mailio_db:get(Db, <<?ID_SYNC_RESET, LocalId/binary>>) of
        {ok, _} -> true;
        {error, not_found} -> false
    end.

clear_reset(Db, LocalId) ->
    _ = mailio_db:delete(Db, <<?ID_SYNC_RESET, LocalId/binary>>),
    ok.

fetch_raw(Adapter, Conn, ImapName, Uid, Validity) ->
    Self = self(),
    Ref = make_ref(),
    Max = mailio_config:get(sync_max_message_bytes, 268435456),
    Total = atomics:new(1, []),
    %% Every chunk is kept, in the order it came, up to a limit: a message that
    %% is longer than that is refused as it arrives, not after it is held.
    Sink = fun(Bytes) ->
        Bin = iolist_to_binary(Bytes),
        case atomics:add_get(Total, 1, byte_size(Bin)) =< Max of
            true ->
                Self ! {Ref, Bin},
                ok;
            false ->
                {error, message_too_large}
        end
    end,
    Result =
        case {Validity, adapter_has(Adapter, fetch_message, 5)} of
            %% A UID listed under a UIDVALIDITY is only the same message under it
            %% (RFC 3501, section 2.3.1.1). An adapter that cannot check that
            %% cannot be trusted with the message: it is an error, and the cursor
            %% stays, so a retry still sees the message.
            {undefined, _} ->
                Adapter:fetch_message(Conn, ImapName, Uid, Sink);
            {_, true} ->
                Adapter:fetch_message(Conn, ImapName, Uid, Sink, #{uidvalidity => Validity});
            {_, false} ->
                {error, {adapter_cannot_check_uidvalidity, Adapter}}
        end,
    Chunks = collect_chunks(Ref, []),
    Size = atomics:get(Total, 1),
    case Result of
        {ok, _} when Size > Max ->
            {error, message_too_large};
        %% what the adapter says it sent must be what arrived: a message with a
        %% part missing is not the message
        {ok, #{size := Told}} when Told =/= Size ->
            {error, {message_incomplete, Told, Size}};
        {ok, _} when Chunks =:= [] ->
            {error, no_data};
        {ok, _} ->
            {ok, iolist_to_binary(Chunks)};
        {error, _} = Err ->
            Err
    end.

collect_chunks(Ref, Acc) ->
    receive
        {Ref, Bin} -> collect_chunks(Ref, [Bin | Acc])
    after 0 -> lists:reverse(Acc)
    end.

adapter_has(Adapter, Fun, Arity) ->
    _ = code:ensure_loaded(Adapter),
    erlang:function_exported(Adapter, Fun, Arity).

%%====================================================================
%% Cursor persistence
%%====================================================================

load_cursor(Db, LocalId) ->
    case mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>) of
        {ok, #{<<"remote_state">> := S}} when is_binary(S), S =/= <<>> -> S;
        _ -> initial
    end.

store_cursor(Db, LocalId, RemoteState) ->
    Doc = #{
        <<"id">> => <<?ID_SYNC_IMAP, LocalId/binary>>,
        <<"mailboxId">> => LocalId,
        <<"remote_state">> => state_bin(RemoteState),
        <<"lastSyncAt">> => erlang:system_time(second)
    },
    Doc1 =
        case mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>) of
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

start_watch(
    #state{
        adapter = Adapter,
        conn = Conn,
        watch = undefined,
        watch_mailbox = ImapName
    } = State
) ->
    case Adapter:watch(Conn, ImapName, self()) of
        {ok, Ref} -> State#state{watch = Ref};
        {error, _} -> State
    end;
start_watch(State) ->
    State.

stop_watch(#state{adapter = Adapter, conn = Conn, watch = Ref} = State) when
    Ref =/= undefined
->
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
