%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Per-account sole writer.
%%%
%%% Every mutation to an account's database flows through this one process,
%%% which serializes the multi-document operations (threading, mailbox
%%% counters, keyword merges, blob refs) that would otherwise race. Reads
%%% go straight to the store from any process.
%%%
%%% Ingestion is idempotent by construction: the email id is the SHA-256 of
%%% the raw bytes, so re-ingesting the same message is a no-op merge and the
%%% same message delivered to a second mailbox simply gains a mailboxId.
%%% Because barrel `put_docs' is not atomic (established by the M1 spike),
%%% the email document is written last; consumers that see an email change
%%% will find its thread/text/blob already present, and a crash mid-write
%%% leaves a partial state that a re-ingest deterministically repairs.
%%%
%%% After each commit the writer pulls the changes it produced from the
%%% changes feed and emits them as live events, so the event stream is
%%% derived from the durable log rather than hand-built.
-module(mailio_account_writer).
-behaviour(gen_server).

-include("mailio_store.hrl").

-export([start_link/1, ingest/4, apply_flags/4, remove_member/3, remove_uid/3]).
-export([gc_blobs/2, migrate_blobs/2]).
-export([set_counters/4, patch/3]).
-export([uidmap_id/3, lookup_uid/3]).
-ifdef(TEST).
-export([deleted/1]).
-endif.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    account_id :: binary(),
    db :: binary(),
    emit_cursor :: barrel_hlc:timestamp() | first
}).

-define(PARSE_VERSION, 1).
%% An ingest has its own mark: the removal it may do inside it clears the other.
-define(INGEST_MARK, <<"counters_dirty_ingest">>).

%%====================================================================
%% API
%%====================================================================

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(AccountId) ->
    gen_server:start_link(via(AccountId), ?MODULE, AccountId, []).

%% @doc Ingest raw RFC 5322 bytes into a mailbox. Returns the email id.
-spec ingest(binary(), binary(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
ingest(AccountId, MailboxId, Raw, Opts) ->
    gen_server:call(via(AccountId), {ingest, MailboxId, Raw, Opts}, 30000).

%% @doc Apply a server-authoritative keyword set to an email (server wins
%% for IMAP-representable keywords; local-only keywords are preserved).
-spec apply_flags(binary(), binary(), binary(), [binary()]) -> ok | {error, term()}.
apply_flags(AccountId, MailboxId, EmailId, ServerKeywords) ->
    gen_server:call(via(AccountId), {apply_flags, MailboxId, EmailId, ServerKeywords}, 30000).

%% @doc Remove an email's membership in a mailbox (expunge/move source). If
%% it leaves no mailboxes, the email is destroyed.
-spec remove_member(binary(), binary(), binary()) -> ok | {error, term()}.
remove_member(AccountId, MailboxId, EmailId) ->
    gen_server:call(via(AccountId), {remove_member, MailboxId, EmailId}, 30000).

%% @doc One UID of a mailbox is gone: drop its mapping, and the email's
%% membership only if no other UID of the mailbox still refers to it.
-spec remove_uid(binary(), binary(), term()) -> ok | {error, not_found | term()}.
remove_uid(AccountId, MailboxId, Uid) ->
    gen_server:call(via(AccountId), {remove_uid, MailboxId, Uid}, 30000).

%% @doc Sweep blobs orphaned longer than `GraceSecs', in the writer process
%% so it cannot race a concurrent re-ingest. Returns the count swept.
%% @doc Move blob bytes from attachments to files, serialized with ingestion.
%% See mailio_blob:migrate_to_files/2.
-spec migrate_blobs(binary(), map()) -> {ok, map()}.
migrate_blobs(AccountId, Opts) ->
    gen_server:call(via(AccountId), {migrate_blobs, Opts}, infinity).

-spec gc_blobs(binary(), non_neg_integer()) -> {ok, non_neg_integer()}.
gc_blobs(AccountId, GraceSecs) ->
    gen_server:call(via(AccountId), {gc_blobs, GraceSecs}, 60000).

%% @doc Set a mailbox's counters to recomputed values (used by fsck repair).
-spec set_counters(binary(), binary(), non_neg_integer(), non_neg_integer()) -> ok.
set_counters(AccountId, MailboxId, Total, Unread) ->
    gen_server:call(via(AccountId), {set_counters, MailboxId, Total, Unread}, 30000).

%% @doc Patch an email in one transaction: add/remove keywords and mailbox
%% memberships. `Patch' keys (all optional, binary lists):
%% `add_keywords', `remove_keywords', `set_keywords' (full replace),
%% `add_mailboxes', `remove_mailboxes', `set_mailboxes'. Updates mailbox
%% counters and emits events. Destroys the email if it ends with no mailbox.
-spec patch(binary(), binary(), map()) -> ok | {error, term()}.
patch(AccountId, EmailId, Patch) ->
    gen_server:call(via(AccountId), {patch, EmailId, Patch}, 30000).

via(AccountId) ->
    {via, mailio_registry, {writer, AccountId}}.

%% @doc Document id of the uid->email mapping for a mailbox + uid. The id keeps
%% the type of the UID (the integer 1 and the text "1" are two messages for an
%% adapter with opaque UIDs) and lives in a namespace of its own, so it never
%% meets an id written by an older version.
-spec uidmap_id(binary(), binary(), term()) -> binary().
uidmap_id(_AccountId, MailboxId, Uid) ->
    <<?ID_UIDMAP2, MailboxId/binary, "/", (uid_key(Uid))/binary>>.

%% @doc Look up the email id mapped to a mailbox + uid.
-spec lookup_uid(binary(), binary(), term()) -> {ok, binary()} | {error, not_found}.
lookup_uid(AccountId, MailboxId, Uid) ->
    Db = mailio_account:db_name(AccountId),
    case existing_uidmap_id(Db, MailboxId, Uid) of
        {_, {ok, #{<<"emailId">> := EmailId}}} -> {ok, EmailId};
        {_, {error, not_found}} -> {error, not_found}
    end.

uid_key(Uid) when is_integer(Uid) -> <<"i:", (integer_to_binary(Uid))/binary>>;
uid_key(Uid) when is_binary(Uid) -> <<"b:", Uid/binary>>.

%% Mappings written by an older version: the UID as it is, in the old namespace,
%% or, from a build that ran for a while, a text UID after `b:'. Their document
%% holds the UID with its type, and only a document that holds this UID is this
%% UID's mapping.
legacy_uidmap_ids(MailboxId, Uid) ->
    Base = <<?ID_UIDMAP, MailboxId/binary, "/">>,
    case Uid of
        _ when is_integer(Uid) -> [<<Base/binary, (integer_to_binary(Uid))/binary>>];
        _ -> [<<Base/binary, Uid/binary>>, <<Base/binary, "b:", Uid/binary>>]
    end.

legacy_mappings(Db, MailboxId, Uid) ->
    [
        {Id, Found}
     || Id <- legacy_uidmap_ids(MailboxId, Uid),
        {ok, #{<<"uid">> := Stored}} = Found <- [mailio_db:get(Db, Id)],
        Stored =:= Uid
    ].

%% The mapping of a UID: the current one, or an older one that has not moved yet.
existing_uidmap_id(Db, MailboxId, Uid) ->
    Id = uidmap_id(<<>>, MailboxId, Uid),
    case mailio_db:get(Db, Id) of
        {ok, _} = Found ->
            {Id, Found};
        {error, not_found} = Missing ->
            case legacy_mappings(Db, MailboxId, Uid) of
                [{Old, Found} | _] -> {Old, Found};
                [] -> {Id, Missing}
            end
    end.

%% A UID has no mapping left, in either namespace.
delete_uidmap(Db, MailboxId, Uid) ->
    maybe
        ok ?= deleted(mailio_db:delete(Db, uidmap_id(<<>>, MailboxId, Uid))),
        drop_legacy(Db, MailboxId, Uid)
    end.

drop_legacy(Db, MailboxId, Uid) ->
    lists:foldl(
        fun
            ({Old, _}, ok) -> deleted(mailio_db:delete(Db, Old));
            (_, Error) -> Error
        end,
        ok,
        legacy_mappings(Db, MailboxId, Uid)
    ).

%% A mapping that is already gone is deleted; one the database refuses to delete
%% is not, and the caller is told.
deleted({ok, _}) -> ok;
deleted({error, not_found}) -> ok;
deleted({error, _} = Error) -> Error.

%%====================================================================
%% gen_server
%%====================================================================

init(AccountId) ->
    Db = mailio_account:db_name(AccountId),
    {ok, _} = mailio_db:ensure_db(Db),
    {ok, _Changes, Hlc} = mailio_db:changes(Db, first),
    ok = load_dirty(Db),
    {ok, #state{account_id = AccountId, db = Db, emit_cursor = Hlc}}.

handle_call({ingest, MailboxId, Raw, Opts}, _From, State) ->
    Result = safely(fun() ->
        %% the mailboxes the email is in too: an ingest rewrites their counters
        Members = email_mailboxes(State#state.db, mailio_id:email_id(Raw)),
        ok = repair_marked(State, [MailboxId | Members]),
        do_ingest(State#state.db, MailboxId, Raw, Opts)
    end),
    State1 = emit_events(State),
    {reply, Result, State1};
handle_call({apply_flags, MailboxId, EmailId, ServerKeywords}, _From, State) ->
    Result = safely(fun() ->
        ok = repair_marked(State, [MailboxId | email_mailboxes(State#state.db, EmailId)]),
        do_apply_flags(State#state.db, MailboxId, EmailId, ServerKeywords)
    end),
    State1 = emit_events(State),
    {reply, Result, State1};
handle_call({remove_uid, MailboxId, Uid}, _From, State) ->
    Result = safely(fun() ->
        ok = repair_marked(State, [MailboxId]),
        do_remove_uid(State#state.db, MailboxId, Uid)
    end),
    State1 = emit_events(State),
    {reply, Result, State1};
handle_call({remove_member, MailboxId, EmailId}, _From, State) ->
    Result = safely(fun() ->
        ok = repair_marked(State, [MailboxId]),
        do_remove_member(State#state.db, MailboxId, EmailId)
    end),
    State1 = emit_events(State),
    {reply, Result, State1};
handle_call({migrate_blobs, Opts}, _From, State) ->
    {reply, mailio_blob:migrate_to_files(State#state.db, Opts), State};
handle_call({gc_blobs, GraceSecs}, _From, State) ->
    Result = mailio_blob:sweep(State#state.db, erlang:system_time(second), GraceSecs),
    {reply, Result, State};
handle_call({set_counters, MailboxId, Total, Unread}, _From, State) ->
    Result = do_set_counters(State#state.db, MailboxId, Total, Unread),
    State1 = emit_events(State),
    {reply, Result, State1};
handle_call({patch, EmailId, Patch}, _From, State) ->
    Result = safely(fun() ->
        Named = lists:append([
            maps:get(K, Patch, [])
         || K <- [add_mailboxes, remove_mailboxes, set_mailboxes]
        ]),
        ok = repair_marked(State, Named ++ email_mailboxes(State#state.db, EmailId)),
        do_patch(State#state.db, EmailId, Patch)
    end),
    State1 = emit_events(State),
    {reply, Result, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% A write that the database refuses is an error to the caller, with the work
%% left in a state the next call repairs, not a crash that loses the reply.
safely(Fun) ->
    try
        Fun()
    catch
        error:{badmatch, {error, Reason}} -> {error, Reason};
        error:{badmatch, Other} -> {error, Other}
    end.

%% A removal marks the mailbox before it changes the email and clears the mark when
%% the counter is written. A mark that is still there means a removal stopped in
%% between and the counter may be wrong: it is counted again from the emails, once,
%% before anything else is written to the mailbox.
%% Every mailbox a write can change counters of is repaired first, and a mark is
%% only ever cleared by the write that counted it again or moved the counters.
repair_marked(State, Mailboxes) ->
    All = lists:usort(Mailboxes ++ maps:keys(get_dirty())),
    lists:foreach(fun(M) -> ok = repair_dirty(State, M) end, All).

%% the mailboxes an email is in, none if it is not stored
email_mailboxes(Db, EmailId) ->
    case mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>) of
        {ok, Email} -> mailio_email:mailbox_ids(Email);
        {error, not_found} -> []
    end.

repair_dirty(#state{db = Db, account_id = AccountId}, MailboxId) ->
    case mailio_db:get(Db, <<?ID_MAILBOX, MailboxId/binary>>) of
        {ok, Mbx} when
            is_map_key(<<"counters_dirty">>, Mbx); is_map_key(?INGEST_MARK, Mbx)
        ->
            {Total, Unread} = maps:get(MailboxId, mailio_fsck:recompute(AccountId), {0, 0}),
            do_set_counters(Db, MailboxId, Total, Unread);
        _ ->
            ok
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Ingestion
%%====================================================================

do_ingest(Db, MailboxId, Raw, Opts) ->
    EmailId = mailio_id:email_id(Raw),
    DocId = <<?ID_EMAIL, EmailId/binary>>,
    ensure_mailbox(Db, MailboxId),
    case mailio_db:get(Db, DocId) of
        {ok, Existing} ->
            merge_existing(Db, Existing, MailboxId, Opts),
            {ok, EmailId};
        {error, not_found} ->
            %% a new email changes the counters, and so may the UID it takes over
            ok = mark_ingesting(Db, [MailboxId]),
            full_ingest(Db, EmailId, DocId, MailboxId, Raw, Opts),
            ok = clear_ingesting(Db, [MailboxId]),
            {ok, EmailId}
    end.

%% Same content already stored: add the mailbox membership and merge
%% keywords, then bump the mailbox counter if this is a new membership.
merge_existing(Db, Existing, MailboxId, Opts) ->
    AlreadyMember = mailio_email:in_mailbox(Existing, MailboxId),
    WasSeen = mailio_email:is_seen(Existing),
    E1 = mailio_email:add_mailbox(Existing, MailboxId),
    E2 = apply_keywords(E1, maps:get(keywords, Opts, [])),
    E3 = add_imap_entry(E2, MailboxId, Opts),
    NowSeen = mailio_email:is_seen(E3),
    %% Counters change on a new membership, or when the email became read or
    %% unread. The mailboxes are marked first and cleared last, so that a stop
    %% in between is found and counted again by the next write to them.
    Touched =
        case {AlreadyMember, WasSeen =:= NowSeen} of
            {true, true} -> [];
            _ -> lists:usort([MailboxId | mailio_email:mailbox_ids(Existing)])
        end,
    ok = mark_ingesting(Db, Touched),
    {ok, _, _} = mailio_db:put(Db, E3),
    ok = maybe_write_uidmap(Db, MailboxId, Opts, mailio_email:id_of(Existing)),
    %% the mailboxes that held it already: merging keywords may have read it
    adjust_unread(Db, mailio_email:mailbox_ids(Existing), WasSeen, NowSeen),
    case AlreadyMember of
        true -> ok;
        %% a new membership is unread only if the email is, as it is now
        false -> bump_mailbox(Db, MailboxId, +1, seen_delta(NowSeen, false))
    end,
    ok = clear_ingesting(Db, Touched).

%%====================================================================
%% Server flag application and membership removal
%%====================================================================

do_apply_flags(Db, _MailboxId, EmailId, ServerKeywords) ->
    DocId = <<?ID_EMAIL, EmailId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, Email} ->
            WasSeen = mailio_email:is_seen(Email),
            Existing = mailio_email:keywords(Email),
            LocalOnly = [
                K
             || K <- Existing,
                not mailio_imap_map:is_representable_keyword(K)
            ],
            New = lists:usort(ServerKeywords ++ LocalOnly),
            Email1 = Email#{<<"keywords">> => keywords_map(New)},
            NowSeen = lists:member(?KW_SEEN, New),
            %% the counters move only when the email became read or unread: then the
            %% mailboxes are marked first and cleared once they are written
            Touched =
                case WasSeen =:= NowSeen of
                    true -> [];
                    false -> mailio_email:mailbox_ids(Email1)
                end,
            ok = mark_ingesting(Db, Touched),
            {ok, _, _} = mailio_db:put(Db, Email1),
            adjust_unread(Db, mailio_email:mailbox_ids(Email1), WasSeen, NowSeen),
            ok = clear_ingesting(Db, Touched),
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

%% One UID of a mailbox is gone from the server. Two UIDs can hold the same mail
%% (one email), so the email stays a member of the mailbox, with its counter,
%% for as long as another UID of that mailbox still refers to it.
%%
%% The mapping goes last. A removal that stops half way leaves it in place, so
%% the next one finds it and finishes, and it does not count the email out of
%% the mailbox twice (the email says whether it is still a member).
do_remove_uid(Db, MailboxId, Uid) ->
    {_MapId, Found} = existing_uidmap_id(Db, MailboxId, Uid),
    case Found of
        {ok, #{<<"emailId">> := EmailId}} ->
            case mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>) of
                {ok, Email} ->
                    Left = mailio_email:remove_imap_entry(Email, MailboxId, Uid),
                    case mailio_email:imap_entries(Left, MailboxId) of
                        [] ->
                            do_remove_member(Db, MailboxId, EmailId);
                        _ ->
                            {ok, _, _} = mailio_db:put(Db, Left),
                            ok
                    end;
                {error, not_found} ->
                    ok
            end,
            ok = delete_uidmap(Db, MailboxId, Uid);
        {error, not_found} ->
            {error, not_found}
    end.

do_remove_member(Db, MailboxId, EmailId) ->
    DocId = <<?ID_EMAIL, EmailId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, Email} ->
            %% leaving a mailbox also forgets its UIDs: a stale one would keep a
            %% later redelivery looking like a copy that is still there
            Email1 = mailio_email:clear_imap_entries(
                mailio_email:remove_mailbox(Email, MailboxId), MailboxId
            ),
            case mailio_email:in_mailbox(Email, MailboxId) of
                true ->
                    %% mark, change the email, write the counter and clear the
                    %% mark: a stop anywhere leaves the mark, and the next write
                    %% to the mailbox counts it again from the emails
                    WasSeen = mailio_email:is_seen(Email),
                    ok = mark_dirty(Db, MailboxId),
                    {ok, _, _} = mailio_db:put(Db, Email1),
                    ok = settle_counter(Db, MailboxId, -1, seen_delta(WasSeen, true) * -1);
                false ->
                    ok
            end,
            case mailio_email:mailbox_ids(Email1) of
                [] -> destroy_email(Db, Email1);
                _ -> ok
            end,
            ok = delete_first_uidmap(Db, Email, MailboxId),
            ok;
        {error, not_found} ->
            ok
    end.

%% Best-effort uidmap cleanup: derive any uid recorded for the mailbox.
delete_first_uidmap(Db, Email, MailboxId) ->
    case mailio_email:imap_entries(Email, MailboxId) of
        [#{<<"uid">> := Uid} | _] -> delete_uidmap(Db, MailboxId, Uid);
        _ -> ok
    end.

destroy_email(Db, Email) ->
    EmailId = mailio_email:id_of(Email),
    BlobId = mailio_email:blob_id(Email),
    _ = mailio_blob:remove_ref(Db, BlobId, <<?ID_EMAIL, EmailId/binary>>),
    _ = mailio_db:delete(Db, <<?ID_TEXT, EmailId/binary>>),
    {ok, _} = mailio_db:delete(Db, <<?ID_EMAIL, EmailId/binary>>),
    ok.

do_patch(Db, EmailId, Patch) ->
    DocId = <<?ID_EMAIL, EmailId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, Email} ->
            OldSeen = mailio_email:is_seen(Email),
            OldMbx = mailio_email:mailbox_ids(Email),
            NewKw = apply_set(
                mailio_email:keywords(Email),
                maps:get(set_keywords, Patch, undefined),
                maps:get(add_keywords, Patch, []),
                maps:get(remove_keywords, Patch, [])
            ),
            NewMbx = apply_set(
                OldMbx,
                maps:get(set_mailboxes, Patch, undefined),
                maps:get(add_mailboxes, Patch, []),
                maps:get(remove_mailboxes, Patch, [])
            ),
            NewSeen = lists:member(?KW_SEEN, NewKw),
            %% a patch that changes membership or the read state moves counters:
            %% the mailboxes are marked before anything is written and cleared
            %% after the counters are
            Touched =
                case {OldMbx =:= NewMbx, OldSeen =:= NewSeen} of
                    {true, true} -> [];
                    _ -> lists:usort(OldMbx ++ NewMbx)
                end,
            ok = mark_ingesting(Db, Touched),
            case NewMbx of
                [] ->
                    %% No mailboxes left -> destroy, undo its counters.
                    [bump_mailbox(Db, M, -1, seen_delta(OldSeen, true) * -1) || M <- OldMbx],
                    destroy_email(Db, Email);
                _ ->
                    Email1 = Email#{
                        <<"keywords">> => to_map(NewKw),
                        <<"mailboxIds">> => to_map(NewMbx)
                    },
                    {ok, _, _} = mailio_db:put(Db, Email1),
                    update_patch_counters(Db, OldMbx, NewMbx, OldSeen, NewSeen)
            end,
            ok = clear_ingesting(Db, Touched),
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

update_patch_counters(Db, OldMbx, NewMbx, OldSeen, NewSeen) ->
    Removed = OldMbx -- NewMbx,
    Added = NewMbx -- OldMbx,
    Retained = OldMbx -- Removed,
    %% Removed: drop total, and the unread it had contributed (if it was unread).
    [bump_mailbox(Db, M, -1, unread_of(OldSeen) * -1) || M <- Removed],
    %% Added: add total, and unread if the email is currently unseen.
    [bump_mailbox(Db, M, +1, unread_of(NewSeen)) || M <- Added],
    %% Retained: only the unread delta from a seen-state change.
    Delta = unread_of(NewSeen) - unread_of(OldSeen),
    [bump_mailbox(Db, M, 0, Delta) || M <- Retained],
    ok.

unread_of(true) -> 0;
unread_of(false) -> 1.

%% Apply set/add/remove to a list, returning a sorted unique list.
apply_set(Current, SetVal, Add, Remove) ->
    Base =
        case SetVal of
            undefined -> Current;
            L when is_list(L) -> L
        end,
    lists:usort((Base ++ Add) -- Remove).

to_map(List) -> maps:from_list([{K, true} || K <- List]).

do_set_counters(Db, MailboxId, Total, Unread) ->
    DocId = <<?ID_MAILBOX, MailboxId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, Doc} ->
            Doc1 = maps:without(
                [<<"counters_dirty">>, ?INGEST_MARK],
                Doc#{<<"totalEmails">> => Total, <<"unreadEmails">> => Unread}
            ),
            {ok, _, _} = mailio_db:put(Db, Doc1),
            track_dirty(MailboxId, Doc1);
        {error, not_found} ->
            {error, not_found}
    end.

%% no change
adjust_unread(_Db, _Mailboxes, Seen, Seen) ->
    ok;
%% became unread
adjust_unread(Db, Mailboxes, true, false) ->
    [bump_mailbox(Db, M, 0, +1) || M <- Mailboxes],
    ok;
%% became read
adjust_unread(Db, Mailboxes, false, true) ->
    [bump_mailbox(Db, M, 0, -1) || M <- Mailboxes],
    ok.

maybe_write_uidmap(Db, MailboxId, Opts, EmailId) ->
    case maps:get(uid, Opts, undefined) of
        undefined ->
            ok;
        Uid ->
            %% Enumerated by the `uidmap/<mailbox>/' id prefix, so no
            %% separate mailboxId field is needed for lookup.
            Id = uidmap_id(<<>>, MailboxId, Uid),
            Doc = #{<<"id">> => Id, <<"uid">> => Uid, <<"emailId">> => EmailId},
            {OldId, Found} = existing_uidmap_id(Db, MailboxId, Uid),
            case Found of
                %% the same message again (a replayed page): nothing to write,
                %% apart from moving an older mapping to the current key. A
                %% retry that finds both writes the current one and drops the old.
                {ok, #{<<"emailId">> := EmailId}} when OldId =:= Id ->
                    drop_legacy(Db, MailboxId, Uid);
                {ok, #{<<"emailId">> := EmailId}} ->
                    {ok, _, _} = mailio_db:put(Db, Doc),
                    drop_legacy(Db, MailboxId, Uid);
                %% The UID now belongs to another message: the one that held it
                %% loses it (and its place in the mailbox, if it had no other).
                {ok, #{<<"emailId">> := _Other}} ->
                    _ = do_remove_uid(Db, MailboxId, Uid),
                    {ok, _, _} = mailio_db:put(Db, Doc),
                    ok;
                {error, not_found} ->
                    {ok, _, _} = mailio_db:put(Db, Doc),
                    ok
            end
    end.

full_ingest(Db, EmailId, DocId, MailboxId, Raw, Opts) ->
    Part = mailio_mime:parse(Raw),
    Headers = headers_of(Part),
    {ok, BlobId} = mailio_blob:put(Db, Raw, DocId),

    Subject = mailio_rfc5322:decode_unstructured(
        mailio_rfc5322:header(<<"subject">>, Headers)
    ),
    From = addresses(<<"from">>, Headers),
    To = addresses(<<"to">>, Headers),
    Cc = addresses(<<"cc">>, Headers),
    Bcc = addresses(<<"bcc">>, Headers),
    ReplyTo = addresses(<<"reply-to">>, Headers),
    Sender = addresses(<<"sender">>, Headers),
    MessageId = mailio_rfc5322:parse_message_id(
        mailio_rfc5322:header(<<"message-id">>, Headers)
    ),
    References = mailio_rfc5322:parse_message_ids(
        mailio_rfc5322:header(<<"references">>, Headers)
    ),
    InReplyTo = mailio_rfc5322:parse_message_ids(
        mailio_rfc5322:header(<<"in-reply-to">>, Headers)
    ),
    ReceivedTs = received_ts(Opts, Headers),
    SentTs = sent_ts(Headers),
    SubjectNorm = mailio_threading:normalize_subject(Subject),

    {BodyText, Attachments} = extract_content(Part),
    HasAttachment = Attachments =/= [],
    Preview = preview(BodyText),
    Keywords = keywords_map(maps:get(keywords, Opts, [])),

    Participants = participant_addrs(From ++ To ++ Cc),
    {ThreadId, ThreadDoc, MsgidDocs} =
        mailio_threading:assign(Db, #{
            email_id => EmailId,
            message_id => MessageId,
            in_reply_to => InReplyTo,
            references => References,
            subject_norm => SubjectNorm,
            received_ts => ReceivedTs,
            participants => Participants
        }),

    TextDoc = #{
        <<"id">> => <<?ID_TEXT, EmailId/binary>>,
        <<"emailId">> => EmailId,
        <<"body_text">> => BodyText,
        <<"attachment_text">> => <<>>,
        <<"tokens_version">> => ?PARSE_VERSION
    },

    EmailDoc = #{
        <<"id">> => DocId,
        <<"blobId">> => BlobId,
        <<"threadId">> => ThreadId,
        <<"mailboxIds">> => #{MailboxId => true},
        <<"keywords">> => Keywords,
        <<"size">> => byte_size(Raw),
        <<"receivedAt">> => rfc3339(ReceivedTs),
        <<"messageId">> => null_or_list(maybe_list(MessageId)),
        <<"inReplyTo">> => null_or_list(InReplyTo),
        <<"references">> => null_or_list(References),
        <<"from">> => null_or_list(From),
        <<"sender">> => null_or_list(Sender),
        <<"to">> => null_or_list(To),
        <<"cc">> => null_or_list(Cc),
        <<"bcc">> => null_or_list(Bcc),
        <<"replyTo">> => null_or_list(ReplyTo),
        <<"subject">> => null_or(Subject),
        <<"sentAt">> => sent_at(SentTs),
        <<"hasAttachment">> => HasAttachment,
        <<"preview">> => Preview,
        <<"attachments">> => Attachments,
        ?MAILIO_NS => #{
            <<"imap">> => imap_map(MailboxId, Opts),
            <<"parse_version">> => ?PARSE_VERSION,
            <<"from_norm">> => norm_addrs(From),
            <<"to_norm">> => norm_addrs(To ++ Cc ++ Bcc),
            <<"subject_norm">> => SubjectNorm,
            <<"received_ts">> => ReceivedTs
        }
    },

    %% Write supporting docs first, the email doc LAST (see module note).
    Supporting = [ThreadDoc | MsgidDocs] ++ [TextDoc],
    _ = mailio_db:put_batch(Db, Supporting),
    {ok, _, _} = mailio_db:put(Db, EmailDoc),
    ok = maybe_write_uidmap(Db, MailboxId, Opts, EmailId),
    bump_mailbox(Db, MailboxId, +1, seen_delta(is_seen_kw(Keywords), false)).

%%====================================================================
%% Content extraction
%%====================================================================

extract_content(Part) ->
    Leaves = mailio_mime:leaves(Part),
    {Texts, Atts} = lists:foldl(fun collect_leaf/2, {[], []}, Leaves),
    BodyText = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Texts))),
    {BodyText, lists:reverse(Atts)}.

collect_leaf(Leaf, {Texts, Atts}) ->
    case mailio_mime:is_attachment(Leaf) of
        true ->
            {Texts, [attachment_summary(Leaf) | Atts]};
        false ->
            case {mailio_mime:type(Leaf), mailio_mime:subtype(Leaf)} of
                {<<"text">>, <<"plain">>} ->
                    {[text_utf8(Leaf) | Texts], Atts};
                {<<"text">>, <<"html">>} ->
                    Html = text_utf8(Leaf),
                    {[mailio_html_text:to_text(Html) | Texts], Atts};
                _ ->
                    {Texts, Atts}
            end
    end.

text_utf8(Leaf) ->
    mailio_mime_decode:to_utf8(mailio_mime:body(Leaf), mailio_mime:charset(Leaf)).

attachment_summary(Leaf) ->
    Body = mailio_mime:body(Leaf),
    #{
        <<"type">> => mailio_mime:content_type(Leaf),
        <<"name">> => null_or(mailio_mime:filename(Leaf)),
        <<"size">> => byte_size(Body)
    }.

preview(BodyText) ->
    Collapsed = collapse_ws(BodyText),
    case string:length(Collapsed) =< 200 of
        true -> Collapsed;
        false -> unicode:characters_to_binary(string:slice(Collapsed, 0, 200))
    end.

collapse_ws(Bin) ->
    Parts = [
        P
     || P <- binary:split(
            Bin,
            [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>],
            [global]
        ),
        P =/= <<>>
    ],
    iolist_to_binary(lists:join(<<" ">>, Parts)).

%%====================================================================
%% Mailbox docs and counters
%%====================================================================

%% Auto-create a minimal mailbox doc when first referenced. Real folder
%% metadata is filled in by the IMAP adapter in later milestones.
ensure_mailbox(Db, MailboxId) ->
    DocId = <<?ID_MAILBOX, MailboxId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            Doc = mailio_mailbox:new(MailboxId, #{name => MailboxId}),
            {ok, _, _} = mailio_db:put(Db, Doc),
            ok
    end.

bump_mailbox(Db, MailboxId, TotalDelta, UnreadDelta) ->
    case bumped_mailbox(Db, MailboxId, TotalDelta, UnreadDelta) of
        [Doc1] ->
            {ok, _, _} = mailio_db:put(Db, Doc1),
            ok;
        [] ->
            ok
    end.

mark_dirty(Db, MailboxId) ->
    mark_dirty(Db, MailboxId, <<"counters_dirty">>).

mark_dirty(Db, MailboxId, Key) ->
    DocId = <<?ID_MAILBOX, MailboxId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, Doc} ->
            Doc1 = Doc#{Key => true},
            {ok, _, _} = mailio_db:put(Db, Doc1),
            track_dirty(MailboxId, Doc1);
        {error, not_found} ->
            ok
    end.

%% The mailboxes that carry a mark are kept in the writer, so that a retry finds
%% them all: a write names only the mailboxes it is about, and a mark can be on
%% one that the retry no longer names (the one an email was moved out of). The
%% marks are on disk, and the writer reads them again when it starts.
-define(DIRTY_KEY, mailio_writer_dirty).

track_dirty(MailboxId, Doc) ->
    Known = get_dirty(),
    case is_map_key(<<"counters_dirty">>, Doc) orelse is_map_key(?INGEST_MARK, Doc) of
        true -> put(?DIRTY_KEY, Known#{MailboxId => true});
        false -> put(?DIRTY_KEY, maps:remove(MailboxId, Known))
    end,
    ok.

get_dirty() ->
    case get(?DIRTY_KEY) of
        undefined -> #{};
        Known -> Known
    end.

load_dirty(Db) ->
    {ok, Docs} = mailio_db:by_id_prefix(Db, <<?ID_MAILBOX>>),
    put(?DIRTY_KEY, #{}),
    lists:foreach(
        fun(#{<<"id">> := <<?ID_MAILBOX, M/binary>>} = Doc) -> track_dirty(M, Doc) end, Docs
    ).

mark_ingesting(Db, Mailboxes) ->
    lists:foreach(fun(M) -> ok = mark_dirty(Db, M, ?INGEST_MARK) end, Mailboxes).

clear_ingesting(Db, Mailboxes) ->
    lists:foreach(
        fun(M) ->
            DocId = <<?ID_MAILBOX, M/binary>>,
            case mailio_db:get(Db, DocId) of
                {ok, #{?INGEST_MARK := _} = Doc} ->
                    Doc1 = maps:remove(?INGEST_MARK, Doc),
                    {ok, _, _} = mailio_db:put(Db, Doc1),
                    track_dirty(M, Doc1);
                _ ->
                    ok
            end
        end,
        Mailboxes
    ).

%% The counters moved and the mark gone, in the one write of the mailbox.
settle_counter(Db, MailboxId, TotalDelta, UnreadDelta) ->
    case bumped_mailbox(Db, MailboxId, TotalDelta, UnreadDelta) of
        [Doc] ->
            Doc1 = maps:remove(<<"counters_dirty">>, Doc),
            {ok, _, _} = mailio_db:put(Db, Doc1),
            track_dirty(MailboxId, Doc1);
        [] ->
            ok
    end.

%% The mailbox document with its counters moved, to be written by the caller.
bumped_mailbox(Db, MailboxId, TotalDelta, UnreadDelta) ->
    DocId = <<?ID_MAILBOX, MailboxId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, Doc} ->
            Total = maps:get(<<"totalEmails">>, Doc, 0) + TotalDelta,
            Unread = maps:get(<<"unreadEmails">>, Doc, 0) + UnreadDelta,
            [
                Doc#{
                    <<"totalEmails">> => max(0, Total),
                    <<"unreadEmails">> => max(0, Unread)
                }
            ];
        {error, not_found} ->
            []
    end.

seen_delta(IsSeen, _Was) when IsSeen -> 0;
seen_delta(_IsSeen, _Was) -> 1.

is_seen_kw(Keywords) -> maps:is_key(?KW_SEEN, Keywords).

%%====================================================================
%% Keyword / imap helpers
%%====================================================================

keywords_map(List) ->
    maps:from_list([{K, true} || K <- List]).

apply_keywords(Email, []) -> Email;
apply_keywords(Email, [K | Rest]) -> apply_keywords(mailio_email:add_keyword(Email, K), Rest).

add_imap_entry(Email, MailboxId, Opts) ->
    case maps:get(uid, Opts, undefined) of
        undefined ->
            Email;
        Uid ->
            Entry = #{
                <<"uid">> => Uid,
                <<"uidvalidity">> => maps:get(uidvalidity, Opts, 0),
                <<"modseq">> => maps:get(modseq, Opts, 0)
            },
            mailio_email:add_imap_entry(Email, MailboxId, Entry)
    end.

imap_map(MailboxId, Opts) ->
    case maps:get(uid, Opts, undefined) of
        undefined ->
            #{};
        Uid ->
            #{
                MailboxId => [
                    #{
                        <<"uid">> => Uid,
                        <<"uidvalidity">> => maps:get(uidvalidity, Opts, 0),
                        <<"modseq">> => maps:get(modseq, Opts, 0)
                    }
                ]
            }
    end.

%%====================================================================
%% Header helpers
%%====================================================================

headers_of(Part) ->
    maps:get(headers, Part, []).

addresses(Name, Headers) ->
    Raw = mailio_rfc5322:header(Name, Headers),
    [to_jmap_addr(A) || A <- mailio_rfc5322:parse_addresses(Raw)].

to_jmap_addr(#{name := Name, email := Email}) ->
    #{<<"name">> => null_or(Name), <<"email">> => Email}.

participant_addrs(Addrs) ->
    lists:usort([E || #{<<"email">> := E} <- Addrs]).

norm_addrs(Addrs) ->
    lists:usort([mailio_ascii:lower(E) || #{<<"email">> := E} <- Addrs]).

received_ts(Opts, Headers) ->
    case maps:get(received_at, Opts, undefined) of
        Ts when is_integer(Ts) -> Ts;
        _ ->
            case mailio_rfc5322:parse_date(mailio_rfc5322:header(<<"date">>, Headers)) of
                {ok, Epoch} -> Epoch;
                error -> erlang:system_time(second)
            end
    end.

sent_ts(Headers) ->
    case mailio_rfc5322:parse_date(mailio_rfc5322:header(<<"date">>, Headers)) of
        {ok, Epoch} -> Epoch;
        error -> undefined
    end.

sent_at(undefined) -> null;
sent_at(Ts) -> rfc3339(Ts).

rfc3339(Ts) ->
    list_to_binary(calendar:system_time_to_rfc3339(Ts, [{offset, "Z"}])).

%%====================================================================
%% Small value helpers
%%====================================================================

maybe_list(undefined) -> [];
maybe_list(X) -> [X].

null_or(undefined) -> null;
null_or(X) -> X.

null_or_list([]) -> null;
null_or_list(L) when is_list(L) -> L.

%%====================================================================
%% Event emission
%%====================================================================

emit_events(#state{account_id = AccountId, emit_cursor = Cursor} = State) ->
    {ok, Envelopes, NewCursor, _More} =
        mailio_changes:since(AccountId, Cursor, #{}),
    lists:foreach(fun mailio_events:dispatch/1, Envelopes),
    State#state{emit_cursor = NewCursor}.
