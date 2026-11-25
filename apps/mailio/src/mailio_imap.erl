%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc IMAP protocol adapter.
%%%
%%% Implements {@link mailio_adapter} on top of {@link mailio_imap_conn},
%%% turning the sync engine's normalized calls into IMAP command sequences
%%% and interpreting the untagged responses. Capability-gated: QRESYNC /
%%% CONDSTORE / MOVE are used when the server advertises them, with a
%%% UID-FETCH fallback otherwise.
-module(mailio_imap).
-behaviour(mailio_adapter).

-export([
    connect/1,
    close/1,
    capabilities/1,
    list_mailboxes/1,
    fetch_changes_since/4,
    fetch_message/4,
    fetch_message/5,
    set_keywords/5,
    move/4,
    append/4,
    expunge/3,
    watch/3,
    unwatch/2,
    list_uids/2,
    list_uids/3,
    mailbox_info/2
]).

%% A connection handle: the FSM pid plus cached capabilities.
-type conn() :: #{
    pid := pid(),
    caps := #{atom() => boolean()},
    max_vanished => pos_integer(),
    listing_window => pos_integer(),
    max_untagged => pos_integer(),
    max_line => pos_integer(),
    max_list_commands => pos_integer()
}.
-export_type([conn/0]).

%%====================================================================
%% Lifecycle
%%====================================================================

%% The most UIDs of one VANISHED report that are listed one by one. The config
%% key `max_vanished' can only lower it.
-define(MAX_VANISHED, 100000).
%% The UIDs one listing command covers, and the commands one call may send.
%% Config: `listing_window'.
-define(LISTING_WINDOW, 10000).
-define(MAX_COMMANDS, 50).
%% What one listing may cost in commands in all, whatever the UIDs are: a
%% mailbox whose UIDs are far apart costs windows, not messages. Config:
%% `max_list_commands'.
-define(MAX_LIST_COMMANDS, 100000).
%% The connection's own defaults (see mailio_imap_conn), for sizing a window.
-define(CONN_MAX_UNTAGGED, 100000).
-define(CONN_MAX_LINE, 65536).
-define(LISTING_ATTEMPTS, 3).
%% how long a caller waits for its turn on a shared connection
-define(SESSION_WAIT, 120000).

-spec connect(map()) -> {ok, conn()} | {error, mailio_error:error_map()}.
connect(Config) ->
    case mailio_imap_conn:start_link(Config) of
        {ok, Pid} ->
            %% Blocks (postponed) until the FSM reaches `ready' after login.
            case run(Pid, fun(T) -> {mailio_imap_proto:capability(T), undefined} end) of
                {ok, Untagged, {ok, _, _}} ->
                    Caps = caps_map(collect_caps(Untagged, Pid)),
                    maybe_enable_qresync(Pid, Caps),
                    {ok, Lock} = mailio_imap_lock:start_link(Pid),
                    {ok, #{
                        pid => Pid,
                        lock => Lock,
                        caps => Caps,
                        max_vanished => min(
                            maps:get(max_vanished, Config, ?MAX_VANISHED), ?MAX_VANISHED
                        ),
                        listing_window => max(1, maps:get(listing_window, Config, ?LISTING_WINDOW)),
                        max_untagged => maps:get(max_untagged, Config, ?CONN_MAX_UNTAGGED),
                        max_line => maps:get(max_line, Config, ?CONN_MAX_LINE),
                        max_list_commands => maps:get(max_list_commands, Config, ?MAX_LIST_COMMANDS)
                    }};
                {ok, _Untagged, {Status, _, Text}} ->
                    mailio_imap_conn:close(Pid),
                    {error, conn_error(Status, Text)};
                {error, Reason} ->
                    mailio_imap_conn:close(Pid),
                    {error, mailio_error_map(imap_disconnected, Reason)}
            end;
        {error, Reason} ->
            {error, mailio_error_map(imap_disconnected, Reason)}
    end.

-spec close(conn()) -> ok.
close(#{pid := Pid} = Conn) ->
    stop_lock(Conn),
    try
        run(Pid, fun(T) -> {mailio_imap_proto:logout(T), undefined} end)
    catch
        _:_ -> ok
    end,
    mailio_imap_conn:close(Pid).

stop_lock(#{lock := Lock}) -> mailio_imap_lock:stop(Lock);
stop_lock(_) -> ok.

%% One session at a time on a connection: what selects a mailbox and then acts on
%% it holds the connection for the whole sequence, so a command never lands on the
%% mailbox another caller selected in between.
session(#{lock := Lock}, Fun) ->
    case mailio_imap_lock:with_session(Lock, ?SESSION_WAIT, fun() -> {done, Fun()} end) of
        {done, Result} -> Result;
        {error, _} = Error -> command_error(Error)
    end;
session(_Conn, Fun) ->
    Fun().

-spec capabilities(conn()) -> #{atom() => boolean()}.
capabilities(#{caps := Caps}) -> Caps.

%% QRESYNC requires an explicit ENABLE (RFC 7162) before the QRESYNC SELECT
%% parameter may be used.
maybe_enable_qresync(Pid, #{qresync := true}) ->
    _ = run(Pid, fun(T) -> {mailio_imap_proto:enable(T, [<<"QRESYNC">>]), undefined} end),
    ok;
maybe_enable_qresync(_Pid, _Caps) ->
    ok.

%%====================================================================
%% Mailboxes
%%====================================================================

-spec list_mailboxes(conn()) -> {ok, [mailio_adapter:remote_mailbox()]} | {error, term()}.
list_mailboxes(#{pid := Pid}) ->
    case run(Pid, fun(T) -> {mailio_imap_proto:list(T, <<>>, <<"*">>), undefined} end) of
        {ok, Untagged, {ok, _, _}} ->
            Mailboxes = [to_mailbox(L) || {list, _, _, _} = L <- Untagged],
            {ok, Mailboxes};
        Other ->
            command_error(Other)
    end.

to_mailbox({list, Attrs, Delim, Name}) ->
    DelimBin =
        case Delim of
            nil -> <<"/">>;
            D -> D
        end,
    #{
        id => Name,
        name => Name,
        role => mailio_imap_map:role_of(Attrs, Name),
        parent_id => null,
        delimiter => DelimBin,
        attrs => Attrs
    }.

%%====================================================================
%% Changes
%%====================================================================

-spec fetch_changes_since(conn(), binary(), mailio_adapter:remote_state(), map()) ->
    {ok, [mailio_adapter:change()], mailio_adapter:remote_state(), more | done}
    | {error, term()}.
fetch_changes_since(Conn, MailboxId, State, Opts) ->
    session(Conn, fun() -> do_fetch_changes(Conn, MailboxId, State, Opts) end).

do_fetch_changes(#{caps := Caps} = Conn, MailboxId, State, _Opts) ->
    %% only the literal `initial' is a first read; a saved cursor, even one that
    %% decodes to nothing, is compared with the mailbox
    Prev = (mailio_imap_map:decode_state(State))#{first_read => State =:= initial},
    case maps:get(page, Prev, undefined) of
        undefined ->
            case use_qresync(Caps, Prev) of
                true ->
                    qresync_changes(
                        Conn, maps:get(max_vanished, Conn, ?MAX_VANISHED), MailboxId, Prev
                    );
                false ->
                    plain_changes(Conn, MailboxId, Prev)
            end;
        Page ->
            continue_listing(Conn, MailboxId, Prev, Page)
    end.

use_qresync(Caps, Prev) ->
    maps:get(qresync, Caps, false) andalso
        maps:get(uidvalidity, Prev) =/= undefined andalso
        maps:get(highestmodseq, Prev) =/= undefined.

%% Plain / CONDSTORE path: EXAMINE, then UID FETCH for new mail and (with
%% CONDSTORE) CHANGEDSINCE for flag updates. Removals are not detected here.
plain_changes(#{pid := Pid} = Conn, MailboxId, Prev) ->
    case examine_listing(Pid, MailboxId) of
        {ok, #{uidvalidity := undefined}} ->
            command_error({error, uidvalidity_invalid});
        {ok, SelInfo} ->
            New = sel_to_state(SelInfo),
            case uidvalidity_changed(Prev, New) of
                true ->
                    {ok, [reset], encode(New), done};
                false ->
                    From = first_uid(maps:get(uidnext, Prev)),
                    list_windows(Conn, New, {added, From}, maps:get(highestmodseq, Prev), [])
            end;
        Other ->
            command_error(Other)
    end.

%% QRESYNC path (RFC 7162): the QRESYNC EXAMINE volunteers VANISHED (EARLIER)
%% for expunged UIDs and FETCH for flag changes since our mod-sequence, so
%% we get removals and updates without extra round trips; new messages are
%% still listed by UID range.
qresync_changes(#{pid := Pid} = Conn, MaxVanished, MailboxId, Prev) ->
    UidValidity = maps:get(uidvalidity, Prev),
    ModSeq = maps:get(highestmodseq, Prev),
    case do_examine_qresync(Pid, MaxVanished, MailboxId, UidValidity, ModSeq) of
        {ok, SelInfo0, Vanished, Updated} ->
            case ensure_uidnext(Pid, SelInfo0) of
                {ok, SelInfo} -> qresync_listing(Conn, Prev, SelInfo, Vanished, Updated);
                Failed -> command_error(Failed)
            end;
        Other ->
            command_error(Other)
    end.

qresync_listing(_Conn, _Prev, #{uidvalidity := undefined}, _Vanished, _Updated) ->
    command_error({error, uidvalidity_invalid});
qresync_listing(Conn, Prev, SelInfo, Vanished, Updated) ->
    New = sel_to_state(SelInfo),
    case {uidvalidity_changed(Prev, New), Vanished} of
        {true, _} ->
            {ok, [reset], encode(New), done};
        {false, too_many} ->
            %% A report too long to list: the caller re-reads the mailbox
            %% and compares it with what it has.
            {ok, [resync], encode(New), done};
        {false, {ok, Uids}} ->
            Removed = [{removed, U} || U <- Uids],
            %% the updates are in the EXAMINE answer: only new mail is listed
            list_windows(
                Conn,
                New,
                {added, first_uid(maps:get(uidnext, Prev))},
                undefined,
                lists:reverse(Updated ++ Removed)
            )
    end.

%% The next call of a listing that did not fit in one: the state says where it
%% stopped. The mailbox must still be the one it started on.
continue_listing(#{pid := Pid} = Conn, MailboxId, Prev, {Phase, Next, PrevModSeq}) ->
    case examine_listing(Pid, MailboxId) of
        {ok, #{uidvalidity := undefined}} ->
            command_error({error, uidvalidity_invalid});
        {ok, SelInfo} ->
            Now = sel_to_state(SelInfo),
            case maps:get(uidvalidity, Now) =:= maps:get(uidvalidity, Prev) of
                false ->
                    {ok, [reset], encode(Now), done};
                true ->
                    %% the target of the listing is the state it started with
                    New = maps:with([uidvalidity, uidnext, highestmodseq], Prev),
                    list_windows(Conn, New, {Phase, Next}, PrevModSeq, [])
            end;
        Other ->
            command_error(Other)
    end.

%% List windows of at most `listing_window' UIDs, so that no command answers with
%% more than the connection will collect, however large the mailbox is. A call
%% stops once it holds about a window of changes, or has sent `?MAX_COMMANDS'
%% commands, and answers `more' with the state to continue from.
%% Phases: `added' (new messages) then `updated' (flags changed since
%% `PrevModSeq', only when it is known and the server has CONDSTORE).
list_windows(Conn, New, Where, PrevModSeq, AccRev) ->
    case listing_cost(Conn, New, Where, PrevModSeq) of
        Windows when Windows > map_get(max_list_commands, Conn) ->
            {error, listing_too_sparse_error()};
        _ ->
            list_windows(Conn, New, Where, PrevModSeq, AccRev, length(AccRev), 0)
    end.

%% The windows a listing still needs from where it stands: what it costs is the
%% span of UIDs it must look at, not the number of messages in it.
listing_cost(#{caps := Caps} = Conn, New, {Phase, Next}, PrevModSeq) ->
    Upto = maps:get(uidnext, New) - 1,
    W = fetch_window(Conn),
    Flags = maps:get(condstore, Caps, false) orelse maps:get(qresync, Caps, false),
    Added =
        case Phase of
            added -> windows(Next, Upto, W);
            updated -> 0
        end,
    Updated =
        case PrevModSeq =/= undefined andalso Flags of
            true ->
                windows(
                    case Phase of
                        updated -> Next;
                        _ -> 1
                    end,
                    Upto,
                    W
                );
            false ->
                0
        end,
    Added + Updated.

windows(From, Upto, _W) when From > Upto -> 0;
windows(From, Upto, W) -> (Upto - From + W) div W.

listing_too_sparse_error() ->
    mailio_error_map(imap_listing_too_sparse, listing_too_sparse).

%% A window is as wide as the setting says, but no wider than one command's
%% answer may be: FETCH answers one line per message, and a SEARCH answer is a
%% single line of at most eleven bytes per UID.
fetch_window(Conn) ->
    Setting = maps:get(listing_window, Conn, ?LISTING_WINDOW),
    Cap = max(1, maps:get(max_untagged, Conn, ?CONN_MAX_UNTAGGED) div 2),
    max(1, min(Setting, Cap)).

search_window(Conn) ->
    Setting = maps:get(listing_window, Conn, ?LISTING_WINDOW),
    Cap = max(1, (maps:get(max_line, Conn, ?CONN_MAX_LINE) - 64) div 11),
    max(1, min(Setting, Cap)).

list_windows(#{caps := Caps} = Conn, New, {Phase, Next}, PrevModSeq, AccRev, Count, Cmds) ->
    Upto = maps:get(uidnext, New) - 1,
    Window = fetch_window(Conn),
    Validity = maps:get(uidvalidity, New),
    Flags = maps:get(condstore, Caps, false) orelse maps:get(qresync, Caps, false),
    case {Phase, Next > Upto} of
        {added, true} ->
            list_windows(Conn, New, {updated, 1}, PrevModSeq, AccRev, Count, Cmds);
        {updated, _} when PrevModSeq =:= undefined; not Flags ->
            finish_listing(New, AccRev);
        {updated, true} ->
            finish_listing(New, AccRev);
        _ when Count >= Window; Cmds >= ?MAX_COMMANDS ->
            more_listing(New, {Phase, Next, PrevModSeq}, AccRev);
        _ ->
            To = min(Upto, Next + Window - 1),
            case list_window(Conn, Phase, Next, To, Validity, PrevModSeq) of
                {ok, Changes} ->
                    list_windows(
                        Conn,
                        New,
                        {Phase, To + 1},
                        PrevModSeq,
                        lists:reverse(Changes, AccRev),
                        Count + length(Changes),
                        Cmds + 1
                    );
                {error, _} = Error ->
                    Error
            end
    end.

finish_listing(New, AccRev) ->
    {ok, lists:reverse(AccRev), encode(New), done}.

more_listing(New, Where, AccRev) ->
    {ok, lists:reverse(AccRev), encode(New, Where), more}.

first_uid(undefined) -> 1;
first_uid(N) -> N.

%% One window: messages A to B, with explicit ends, so a window past the last
%% message is empty (an `N:*' range always holds the last message).
list_window(#{pid := Pid}, added, From, To, Validity, _ModSeq) ->
    Items = [<<"UID">>, <<"FLAGS">>, <<"INTERNALDATE">>, <<"RFC822.SIZE">>],
    Cmd = fun(T) ->
        {mailio_imap_proto:uid_fetch(T, {range, From, To}, Items), undefined}
    end,
    case run(Pid, Cmd) of
        {ok, Untagged, {ok, _, _}} ->
            {ok, classify_fetches(Untagged, From, To, Validity)};
        Other ->
            command_error(Other)
    end;
list_window(#{pid := Pid}, updated, From, To, _Validity, PrevModSeq) ->
    %% CHANGEDSINCE is a FETCH modifier appended after the item list.
    Cmd = fun(T) ->
        {
            [
                T,
                <<" UID FETCH ">>,
                integer_to_binary(From),
                <<":">>,
                integer_to_binary(To),
                <<" (UID FLAGS) (CHANGEDSINCE ">>,
                integer_to_binary(PrevModSeq),
                <<")\r\n">>
            ],
            undefined
        }
    end,
    case run(Pid, Cmd) of
        {ok, Untagged, {ok, _, _}} ->
            {ok, [
                {updated, #{uid => proplists:get_value(uid, I), keywords => keywords_of(I)}}
             || {fetch, _Seq, I} <- Untagged,
                proplists:is_defined(uid, I)
            ]};
        Other ->
            command_error(Other)
    end.

vanished_uids(Ranges, Max) ->
    case mailio_imap_proto:expand_uid_ranges(Ranges, Max) of
        {ok, _} = Ok -> Ok;
        {error, too_many} -> too_many
    end.

do_examine_qresync(Pid, MaxVanished, MailboxId, UidValidity, ModSeq) ->
    Builder = fun(T) ->
        {mailio_imap_proto:examine_qresync(T, MailboxId, UidValidity, ModSeq), undefined}
    end,
    case run(Pid, Builder) of
        {ok, Untagged, {ok, _, _}} ->
            SelInfo = parse_select(Untagged),
            Ranges = lists:append([R || {vanished, _Earlier, R} <- Untagged]),
            Vanished =
                case [Raw || {other, <<"VANISHED", _/binary>> = Raw} <- Untagged] of
                    [] -> vanished_uids(Ranges, MaxVanished);
                    %% a report we cannot read may hide removals: read it all again
                    _ -> too_many
                end,
            Updated = [
                {updated, #{
                    uid => proplists:get_value(uid, I),
                    keywords => keywords_of(I)
                }}
             || {fetch, _Seq, I} <- Untagged,
                proplists:is_defined(uid, I)
            ],
            {ok, SelInfo, Vanished, Updated};
        Other ->
            Other
    end.

%% What a window asked for is new mail. A FETCH for another UID is a flag update
%% the server volunteered (RFC 3501, section 7): it is that, not new mail, and
%% one without a UID cannot be matched to anything and is dropped.
classify_fetches(Untagged, From, To, Validity) ->
    lists:filtermap(
        fun
            ({fetch, _Seq, Items}) ->
                case proplists:get_value(uid, Items) of
                    Uid when is_integer(Uid), Uid >= From, Uid =< To ->
                        {true, added_change(Items, Validity)};
                    Uid when is_integer(Uid) ->
                        case proplists:is_defined(flags, Items) of
                            true ->
                                {true, {updated, #{uid => Uid, keywords => keywords_of(Items)}}};
                            false ->
                                false
                        end;
                    _ ->
                        false
                end;
            (_) ->
                false
        end,
        Untagged
    ).

added_change(Items, Validity) ->
    {added, #{
        uid => proplists:get_value(uid, Items),
        uidvalidity => Validity,
        keywords => keywords_of(Items),
        internal_date => internaldate_epoch(Items),
        size => proplists:get_value(size, Items, 0)
    }}.

%%====================================================================
%% Message fetch
%%====================================================================

-spec fetch_message(conn(), binary(), term(), mailio_adapter:fetch_sink()) ->
    {ok, #{size := non_neg_integer()}} | {error, term()}.
fetch_message(Conn, MailboxId, Uid, Sink) ->
    fetch_message(Conn, MailboxId, Uid, Sink, #{}).

%% @doc Like fetch_message/4. With `uidvalidity' in `Opts' the message is only
%% fetched when the mailbox still has that UIDVALIDITY; a UID means nothing
%% under another one (RFC 3501, section 2.3.1.1), so the answer is
%% `{error, uidvalidity_changed}'.
-spec fetch_message(conn(), binary(), term(), mailio_adapter:fetch_sink(), map()) ->
    {ok, #{size := non_neg_integer()}} | {error, term()}.
fetch_message(#{pid := Pid} = Conn, MailboxId, Uid, Sink, Opts) ->
    session(Conn, fun() -> do_fetch_message(Pid, MailboxId, Uid, Sink, Opts) end).

do_fetch_message(Pid, MailboxId, Uid, Sink, Opts) ->
    case do_examine(Pid, MailboxId) of
        {ok, Sel} when
            is_map_key(uidvalidity, Opts),
            map_get(uidvalidity, Opts) =/= map_get(uidvalidity, Sel)
        ->
            {error, mailio_error_map(imap_uidvalidity_changed, uidvalidity_changed)};
        {ok, _} ->
            Items = [<<"BODY.PEEK[]">>],
            case run(Pid, fun(T) -> {mailio_imap_proto:uid_fetch(T, Uid, Items), undefined} end) of
                {ok, Untagged, {ok, _, _}} ->
                    case body_from(Untagged, Uid) of
                        {ok, Body} ->
                            Sink(Body),
                            {ok, #{size => byte_size(Body)}};
                        not_found ->
                            {error, mailio_error_map(imap_fetch_failed, not_found)}
                    end;
                Other ->
                    command_error(Other)
            end;
        Other ->
            command_error(Other)
    end.

%% Only the body of the UID that was asked for. Another message's body, or one with
%% no UID to say whose it is, is not this message: it must not be stored as it.
body_from(Untagged, Uid) ->
    Matches = [
        Body
     || {fetch, _Seq, I} <- Untagged,
        proplists:get_value(uid, I) =:= Uid,
        Body <- [proplists:get_value(body, I)],
        is_binary(Body)
    ],
    case Matches of
        [Body] -> {ok, Body};
        _ -> not_found
    end.

%%====================================================================
%% Mutations
%%====================================================================

-spec set_keywords(conn(), binary(), term(), [binary()], [binary()]) ->
    ok | {error, term()}.
set_keywords(#{pid := Pid} = Conn, MailboxId, Uid, Add, Remove) ->
    session(Conn, fun() -> do_set_keywords(Pid, MailboxId, Uid, Add, Remove) end).

do_set_keywords(Pid, MailboxId, Uid, Add, Remove) ->
    case do_select(Pid, MailboxId) of
        {ok, _} ->
            AddFlags = mailio_imap_map:keywords_to_flags(Add),
            RemFlags = mailio_imap_map:keywords_to_flags(Remove),
            ok_chain([
                fun() -> store(Pid, Uid, add, AddFlags) end,
                fun() -> store(Pid, Uid, remove, RemFlags) end
            ]);
        Other ->
            command_error(Other)
    end.

store(_Pid, _Uid, _Action, []) ->
    ok;
store(Pid, Uid, Action, Flags) ->
    case
        run(Pid, fun(T) ->
            {mailio_imap_proto:uid_store(T, Uid, {Action, true}, Flags), undefined}
        end)
    of
        {ok, _, {ok, _, _}} -> ok;
        Other -> command_error(Other)
    end.

-spec move(conn(), binary(), term(), binary()) ->
    {ok, term() | undefined} | {error, term()}.
move(#{pid := Pid, caps := Caps} = Conn, FromMailbox, Uid, ToMailbox) ->
    case maps:get(move, Caps, false) orelse maps:get(uidplus, Caps, false) of
        true ->
            session(Conn, fun() -> do_move(Pid, Caps, FromMailbox, Uid, ToMailbox) end);
        false ->
            %% neither MOVE nor UIDPLUS: a copy would be followed by an expunge that
            %% can take other messages, so nothing is copied
            {error, uidplus_required_error()}
    end.

do_move(Pid, Caps, FromMailbox, Uid, ToMailbox) ->
    case do_select(Pid, FromMailbox) of
        {ok, _} ->
            case maps:get(move, Caps, false) of
                true ->
                    case
                        run(Pid, fun(T) ->
                            {mailio_imap_proto:uid_move(T, Uid, ToMailbox), undefined}
                        end)
                    of
                        {ok, _, {ok, _, _}} -> {ok, undefined};
                        Other -> command_error(Other)
                    end;
                false ->
                    move_by_copy(Pid, Uid, ToMailbox)
            end;
        Other ->
            command_error(Other)
    end.

move_by_copy(Pid, Uid, ToMailbox) ->
    ok_chain(
        [
            fun() -> copy(Pid, Uid, ToMailbox) end,
            fun() -> store(Pid, Uid, add, [<<"\\Deleted">>]) end,
            fun() -> expunge_targets(Pid, Uid) end
        ],
        {ok, undefined}
    ).

copy(Pid, Uid, Dest) ->
    case run(Pid, fun(T) -> {mailio_imap_proto:uid_copy(T, Uid, Dest), undefined} end) of
        {ok, _, {ok, _, _}} -> ok;
        Other -> command_error(Other)
    end.

-spec append(conn(), binary(), binary(), [binary()]) ->
    {ok, term() | undefined} | {error, term()}.
append(#{pid := Pid}, MailboxId, Raw, Keywords) ->
    Flags = mailio_imap_map:keywords_to_flags(Keywords),
    Builder = fun(T) ->
        {Prefix, Data} = mailio_imap_proto:append(T, MailboxId, Flags, Raw),
        {Prefix, Data}
    end,
    case run(Pid, Builder) of
        {ok, _Untagged, {ok, Code, _}} -> {ok, appenduid(Code)};
        Other -> command_error(Other)
    end.

appenduid({<<"APPENDUID">>, [_Validity, {number, Uid}]}) -> Uid;
appenduid(_) -> undefined.

%% Removes the messages named and no others, with `UID EXPUNGE' (UIDPLUS, RFC 4315).
%% Without it the only command is `EXPUNGE', which also takes every message
%% flagged \\Deleted, and another client can flag one at any moment, so a check
%% beforehand would not hold. The call is refused before anything is changed.
-spec expunge(conn(), binary(), [term()]) -> ok | {error, term()}.
expunge(#{pid := Pid, caps := Caps} = Conn, MailboxId, Uids) ->
    case maps:get(uidplus, Caps, false) of
        true -> session(Conn, fun() -> do_expunge_set(Pid, MailboxId, Uids) end);
        false -> {error, uidplus_required_error()}
    end.

uidplus_required_error() ->
    mailio_error_map(imap_operation_unsupported, uidplus_required).

%% The UIDs go to each command as they are: every builder encodes them once.
do_expunge_set(Pid, MailboxId, Uids) ->
    case do_select(Pid, MailboxId) of
        {ok, _} ->
            ok_chain([
                fun() -> store(Pid, Uids, add, [<<"\\Deleted">>]) end,
                fun() -> expunge_targets(Pid, Uids) end
            ]);
        Other ->
            command_error(Other)
    end.

expunge_targets(Pid, Uids) ->
    case run(Pid, fun(T) -> {mailio_imap_proto:uid_expunge(T, Uids), undefined} end) of
        {ok, _, {ok, _, _}} -> ok;
        Other -> command_error(Other)
    end.

%%====================================================================
%% Watch (IDLE)
%%====================================================================

-spec watch(conn(), binary(), pid()) -> {ok, term()} | {error, not_supported | term()}.
watch(#{pid := Pid, caps := Caps} = Conn, MailboxId, NotifyPid) ->
    case maps:get(idle, Caps, false) of
        false ->
            {error, not_supported};
        true ->
            session(Conn, fun() ->
                case do_examine(Pid, MailboxId) of
                    {ok, _} ->
                        case mailio_imap_conn:idle_start(Pid, NotifyPid) of
                            ok -> {ok, {idle, Pid}};
                            Other -> command_error(Other)
                        end;
                    Other ->
                        command_error(Other)
                end
            end)
    end.

-spec unwatch(conn(), term()) -> ok.
unwatch(#{pid := Pid}, {idle, Pid}) ->
    mailio_imap_conn:idle_stop(Pid);
unwatch(_Conn, _Ref) ->
    ok.

%% List all uids currently present (UID SEARCH ALL).
-spec list_uids(conn(), binary()) -> {ok, [integer()]} | {error, term()}.
list_uids(Conn, MailboxId) ->
    list_uids(Conn, MailboxId, #{}).

%% How many messages the server says the mailbox holds, and under which UIDVALIDITY.
-spec mailbox_info(conn(), binary()) ->
    {ok, #{exists := non_neg_integer(), uidvalidity := pos_integer() | undefined}}
    | {error, term()}.
mailbox_info(#{pid := Pid} = Conn, MailboxId) ->
    session(Conn, fun() -> do_mailbox_info(Pid, MailboxId) end).

do_mailbox_info(Pid, MailboxId) ->
    case do_examine(Pid, MailboxId) of
        {ok, #{exists := Exists} = Sel} when is_integer(Exists) ->
            {ok, #{exists => Exists, uidvalidity => maps:get(uidvalidity, Sel, undefined)}};
        {ok, _} ->
            command_error({error, mailbox_size_unknown});
        Other ->
            command_error(Other)
    end.

%% A listing is only an inventory if it agrees with the mailbox: the number of
%% UIDs found must be the number of messages the server said it holds when it
%% was opened. When they differ the mailbox may have changed while it was read,
%% so it is read again, a few times; after that it is an error, and whoever asked
%% keeps what it has. `max' stops a listing that grows past it as it is read.
-spec list_uids(conn(), binary(), #{max => pos_integer()}) ->
    {ok, [integer()]} | {error, term()}.
list_uids(Conn, MailboxId, Opts) ->
    session(Conn, fun() -> list_uids(Conn, MailboxId, Opts, ?LISTING_ATTEMPTS) end).

list_uids(#{pid := Pid} = Conn, MailboxId, Opts, Attempts) ->
    case examine_listing(Pid, MailboxId) of
        {ok, #{uidvalidity := undefined}} ->
            command_error({error, uidvalidity_invalid});
        {ok, #{exists := Exists}} when not is_integer(Exists) ->
            command_error({error, mailbox_size_unknown});
        {ok, #{uidnext := UidNext, exists := Exists}} ->
            Upto = UidNext - 1,
            Window = search_window(Conn),
            case windows(1, Upto, Window) > maps:get(max_list_commands, Conn, ?MAX_LIST_COMMANDS) of
                true ->
                    {error, listing_too_sparse_error()};
                false ->
                    Max = maps:get(max, Opts, infinity),
                    case list_uid_windows(Pid, 1, Upto, Window, Max, 0, []) of
                        {ok, Uids} when length(Uids) =:= Exists ->
                            {ok, Uids};
                        {ok, _} when Attempts > 1 ->
                            list_uids(Conn, MailboxId, Opts, Attempts - 1);
                        {ok, _} ->
                            command_error({error, listing_inconsistent});
                        Other ->
                            Other
                    end
            end;
        Other ->
            command_error(Other)
    end.

%% UID SEARCH answers one line of numbers: a mailbox is listed in windows, so
%% that no line is longer than the connection allows.
list_uid_windows(_Pid, From, Upto, _Window, _Max, _Count, AccRev) when From > Upto ->
    {ok, lists:usort(lists:append(AccRev))};
list_uid_windows(Pid, From, Upto, Window, Max, Count, AccRev) ->
    To = min(Upto, From + Window - 1),
    Criteria = [<<"UID ">>, integer_to_binary(From), <<":">>, integer_to_binary(To)],
    case run(Pid, fun(T) -> {mailio_imap_proto:uid_search(T, Criteria), undefined} end) of
        {ok, Untagged, {ok, _, _}} ->
            %% The server must have answered: an OK with no SEARCH line, or one
            %% that is not all numbers, says nothing about the mailbox. Only an
            %% explicit, empty `* SEARCH' is a window with no mail in it.
            Answers = [Us || {search, Us} <- Untagged],
            Unreadable = [R || {other, <<"SEARCH", _/binary>> = R} <- Untagged],
            Uids = lists:append(Answers),
            InWindow = lists:all(fun(U) -> U >= From andalso U =< To end, Uids),
            case {Answers, Unreadable, InWindow} of
                {[_ | _], [], true} when Max =/= infinity, Count + length(Uids) > Max ->
                    %% a mailbox with more than the caller accepts is not read on
                    command_error({error, mailbox_too_large_to_resync});
                {[_ | _], [], true} ->
                    list_uid_windows(
                        Pid, To + 1, Upto, Window, Max, Count + length(Uids), [Uids | AccRev]
                    );
                _ ->
                    %% a UID outside the window was not asked for: the answer is
                    %% not about this window
                    command_error({error, search_answer_invalid})
            end;
        Other ->
            command_error(Other)
    end.

%%====================================================================
%% Selection and cursor helpers
%%====================================================================

%% EXAMINE for a listing, with a UIDNEXT: RFC 3501 lets a server leave it out.
examine_listing(Pid, MailboxId) ->
    case do_examine(Pid, MailboxId) of
        {ok, Sel} -> ensure_uidnext(Pid, Sel);
        Other -> Other
    end.

ensure_uidnext(Pid, Sel) ->
    case find_uidnext(Pid, Sel) of
        {ok, #{uidnext := Next, exists := Exists}} when
            is_integer(Exists), Next - 1 < Exists
        ->
            %% every message has a UID of its own from 1, so the highest is at
            %% least their number: a bound below it is not true, and a listing
            %% under it would leave messages out
            {error, uidnext_below_exists};
        Other ->
            Other
    end.

find_uidnext(_Pid, #{uidnext := N} = Sel) when is_integer(N) ->
    {ok, Sel};
find_uidnext(Pid, Sel) ->
    case maps:get(exists, Sel, undefined) of
        0 ->
            {ok, Sel#{uidnext => 1}};
        undefined ->
            %% neither UIDNEXT nor EXISTS: nothing says whether the mailbox is
            %% empty, and a listing of nothing would be taken for the truth
            {error, mailbox_size_unknown};
        _ ->
            %% One past the highest UID present. It can be lower than the real
            %% UIDNEXT (the highest message may have been expunged), but every
            %% message in the mailbox is at or below the highest, so none is
            %% missed; the UIDs in between were never delivered to anyone.
            case max_uid(Pid) of
                {ok, Highest} -> {ok, Sel#{uidnext => Highest + 1}};
                Other -> Other
            end
    end.

max_uid(Pid) ->
    Cmd = fun(T) -> {mailio_imap_proto:uid_fetch(T, <<"*">>, [<<"UID">>]), undefined} end,
    case run(Pid, Cmd) of
        {ok, Untagged, {ok, _, _}} ->
            %% The server may volunteer updates for other messages in the same
            %% answer, so the highest is the largest of them; but every UID in
            %% it must be one (RFC 3501, section 2.3.1.1: 1 to 2^32-1), or the
            %% answer cannot be trusted about the last message.
            Uids = [proplists:get_value(uid, I) || {fetch, _, I} <- Untagged],
            Valid = fun(U) -> is_integer(U) andalso U >= 1 andalso U =< 4294967295 end,
            case Uids =/= [] andalso lists:all(Valid, Uids) of
                true -> {ok, lists:max(Uids)};
                false -> {error, no_highest_uid}
            end;
        Other ->
            Other
    end.

%% Read-write: only for commands that change the mailbox.
do_select(Pid, MailboxId) ->
    open_mailbox(Pid, fun(T) -> mailio_imap_proto:select(T, MailboxId) end).

%% Read-only (EXAMINE): for everything that only reads.
do_examine(Pid, MailboxId) ->
    open_mailbox(Pid, fun(T) -> mailio_imap_proto:examine(T, MailboxId) end).

open_mailbox(Pid, Cmd) ->
    case run(Pid, fun(T) -> {Cmd(T), undefined} end) of
        {ok, Untagged, {ok, _Code, _Text}} ->
            {ok, parse_select(Untagged)};
        Other ->
            Other
    end.

parse_select(Untagged) ->
    lists:foldl(
        fun select_field/2,
        #{
            uidvalidity => undefined,
            uidnext => undefined,
            highestmodseq => undefined,
            %% not known until the server says: no EXISTS is not an empty mailbox
            exists => undefined,
            flags => []
        },
        Untagged
    ).

select_field({exists, N}, Acc) ->
    Acc#{exists => N};
select_field({flags, F}, Acc) ->
    Acc#{flags => F};
select_field({status_resp, ok, {<<"UIDVALIDITY">>, [{number, V}]}, _}, Acc) ->
    Acc#{uidvalidity => V};
select_field({status_resp, ok, {<<"UIDNEXT">>, [{number, V}]}, _}, Acc) when V >= 1 ->
    Acc#{uidnext => V};
select_field({status_resp, ok, {<<"HIGHESTMODSEQ">>, [{number, V}]}, _}, Acc) ->
    Acc#{highestmodseq => V};
select_field(_, Acc) ->
    Acc.

sel_to_state(#{uidvalidity := UV, uidnext := UN, highestmodseq := MS}) ->
    #{uidvalidity => UV, uidnext => UN, highestmodseq => MS}.

encode(New) ->
    encode(New, undefined).

%% `Where' is where a listing that did not fit in one call goes on: the phase,
%% the next UID and the mod-sequence the flag updates are counted from.
encode(#{uidvalidity := UV, uidnext := UN, highestmodseq := MS}, Where) ->
    mailio_imap_map:encode_state(#{
        uidvalidity => UV,
        uidnext => UN,
        highestmodseq => MS,
        page => Where
    }).

%% A cursor that never knew a UIDVALIDITY cannot say its UIDs are still the same
%% messages (RFC 3501, section 2.3.1.1): unless it is the very first read, the
%% mailbox is read again in full.
uidvalidity_changed(#{uidvalidity := undefined} = Prev, _New) ->
    not maps:get(first_read, Prev, false);
uidvalidity_changed(#{uidvalidity := Prev}, #{uidvalidity := New}) ->
    Prev =/= New.

%%====================================================================
%% Item helpers
%%====================================================================

keywords_of(Items) ->
    Flags = proplists:get_value(flags, Items, []),
    maps:keys(mailio_imap_map:flags_to_keywords(Flags)).

internaldate_epoch(Items) ->
    case proplists:get_value(internaldate, Items) of
        undefined -> erlang:system_time(second);
        Bin -> parse_internaldate(Bin)
    end.

%% INTERNALDATE: "DD-Mon-YYYY HH:MM:SS +ZZZZ"
parse_internaldate(Bin) ->
    case mailio_rfc5322:parse_date(Bin) of
        {ok, Epoch} -> Epoch;
        error -> erlang:system_time(second)
    end.

%%====================================================================
%% Capabilities
%%====================================================================

collect_caps(Untagged, Pid) ->
    case [Caps || {capability, Caps} <- Untagged] of
        [Caps | _] -> Caps;
        [] -> mailio_imap_conn:capabilities(Pid)
    end.

caps_map(CapList) ->
    Has = fun(Name) -> lists:any(fun(C) -> mailio_ascii:upper(C) =:= Name end, CapList) end,
    #{
        idle => Has(<<"IDLE">>),
        condstore => Has(<<"CONDSTORE">>),
        qresync => Has(<<"QRESYNC">>),
        move => Has(<<"MOVE">>),
        uidplus => Has(<<"UIDPLUS">>),
        'special-use' => Has(<<"SPECIAL-USE">>)
    }.

%%====================================================================
%% Result helpers
%%====================================================================

run(Pid, Builder) -> mailio_imap_conn:run(Pid, Builder).

ok_chain(Funs) -> ok_chain(Funs, ok).
ok_chain([], Result) ->
    Result;
ok_chain([F | Rest], Result) ->
    case F() of
        ok -> ok_chain(Rest, Result);
        {error, _} = Err -> Err
    end.

command_error({ok, _Untagged, {Status, _Code, Text}}) ->
    {error, conn_error(Status, Text)};
command_error({error, Reason}) ->
    {error, mailio_error_map(imap_command_failed, Reason)};
command_error(Other) ->
    {error, mailio_error_map(imap_command_failed, Other)}.

conn_error(no, Text) -> mailio_error_map(imap_command_rejected, Text);
conn_error(bad, Text) -> mailio_error_map(imap_protocol_error, Text);
conn_error(Status, Text) -> mailio_error_map(imap_command_failed, {Status, Text}).

mailio_error_map(Code, Detail) ->
    {error, M} = mailio_error:new(Code, #{detail => Detail}),
    M.
