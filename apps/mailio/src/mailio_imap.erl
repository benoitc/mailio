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
    set_keywords/5,
    move/4,
    append/4,
    expunge/3,
    watch/3,
    unwatch/2,
    list_uids/2
]).

%% A connection handle: the FSM pid plus cached capabilities.
-type conn() :: #{pid := pid(), caps := #{atom() => boolean()}}.
-export_type([conn/0]).

%%====================================================================
%% Lifecycle
%%====================================================================

-spec connect(map()) -> {ok, conn()} | {error, mailio_error:error_map()}.
connect(Config) ->
    case mailio_imap_conn:start_link(Config) of
        {ok, Pid} ->
            %% Blocks (postponed) until the FSM reaches `ready' after login.
            case run(Pid, fun(T) -> {mailio_imap_proto:capability(T), undefined} end) of
                {ok, Untagged, {ok, _, _}} ->
                    Caps = caps_map(collect_caps(Untagged, Pid)),
                    maybe_enable_qresync(Pid, Caps),
                    {ok, #{pid => Pid, caps => Caps}};
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
close(#{pid := Pid}) ->
    try
        run(Pid, fun(T) -> {mailio_imap_proto:logout(T), undefined} end)
    catch
        _:_ -> ok
    end,
    mailio_imap_conn:close(Pid).

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
fetch_changes_since(#{pid := Pid, caps := Caps}, MailboxId, State, _Opts) ->
    Prev = mailio_imap_map:decode_state(State),
    case use_qresync(Caps, Prev) of
        true -> qresync_changes(Pid, MailboxId, Prev);
        false -> plain_changes(Pid, Caps, MailboxId, Prev)
    end.

use_qresync(Caps, Prev) ->
    maps:get(qresync, Caps, false) andalso
        maps:get(uidvalidity, Prev) =/= undefined andalso
        maps:get(highestmodseq, Prev) =/= undefined.

%% Plain / CONDSTORE path: SELECT, then UID-FETCH for new and (if CONDSTORE)
%% CHANGEDSINCE for flag updates. Removals are not detected here.
plain_changes(Pid, Caps, MailboxId, Prev) ->
    case do_examine(Pid, MailboxId) of
        {ok, SelInfo} ->
            New = sel_to_state(SelInfo),
            case uidvalidity_changed(Prev, New) of
                true ->
                    {ok, [reset], encode(New), done};
                false ->
                    Added = fetch_added(Pid, maps:get(uidnext, Prev)),
                    Updated = fetch_updated(Pid, Caps, maps:get(highestmodseq, Prev)),
                    {ok, Added ++ Updated, encode(New), done}
            end;
        Other ->
            command_error(Other)
    end.

%% QRESYNC path (RFC 7162): the QRESYNC SELECT volunteers VANISHED (EARLIER)
%% for expunged UIDs and FETCH for flag changes since our mod-sequence, so
%% we get removals and updates without extra round trips; new messages are
%% still fetched by UID range.
qresync_changes(Pid, MailboxId, Prev) ->
    UidValidity = maps:get(uidvalidity, Prev),
    ModSeq = maps:get(highestmodseq, Prev),
    case do_examine_qresync(Pid, MailboxId, UidValidity, ModSeq) of
        {ok, SelInfo, Vanished, Updated} ->
            New = sel_to_state(SelInfo),
            case {uidvalidity_changed(Prev, New), Vanished} of
                {true, _} ->
                    {ok, [reset], encode(New), done};
                {false, too_many} ->
                    %% a report too long to list: start over rather than hold it
                    {ok, [reset], encode(New), done};
                {false, {ok, Uids}} ->
                    Added = fetch_added(Pid, maps:get(uidnext, Prev)),
                    Removed = [{removed, U} || U <- Uids],
                    {ok, Added ++ Updated ++ Removed, encode(New), done}
            end;
        Other ->
            command_error(Other)
    end.

%% The most UIDs of one VANISHED report that are listed one by one.
-define(MAX_VANISHED, 100000).

vanished_uids(Ranges) ->
    case mailio_imap_proto:expand_uid_ranges(Ranges, ?MAX_VANISHED) of
        {ok, _} = Ok -> Ok;
        {error, too_many} -> too_many
    end.

do_examine_qresync(Pid, MailboxId, UidValidity, ModSeq) ->
    Builder = fun(T) ->
        {mailio_imap_proto:examine_qresync(T, MailboxId, UidValidity, ModSeq), undefined}
    end,
    case run(Pid, Builder) of
        {ok, Untagged, {ok, _, _}} ->
            SelInfo = parse_select(Untagged),
            Ranges = lists:append([R || {vanished, _Earlier, R} <- Untagged]),
            Vanished = vanished_uids(Ranges),
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

%% Added: messages with UID >= the previously seen UIDNEXT (or all, initially).
fetch_added(Pid, undefined) ->
    fetch_range(Pid, {range, 1, '*'});
fetch_added(Pid, PrevUidNext) ->
    %% `N:*' always includes the highest message, even when N is past it
    %% (RFC 3501, section 9), so drop what we have already seen.
    [
        Change
     || {added, #{uid := Uid}} = Change <- fetch_range(Pid, {range, PrevUidNext, '*'}),
        Uid >= PrevUidNext
    ].

fetch_range(Pid, SeqSet) ->
    Items = [<<"UID">>, <<"FLAGS">>, <<"INTERNALDATE">>, <<"RFC822.SIZE">>],
    case run(Pid, fun(T) -> {mailio_imap_proto:uid_fetch(T, SeqSet, Items), undefined} end) of
        {ok, Untagged, {ok, _, _}} ->
            [
                added_change(Items0)
             || {fetch, _Seq, Items0} <- Untagged,
                proplists:is_defined(uid, Items0)
            ];
        _ ->
            []
    end.

added_change(Items) ->
    {added, #{
        uid => proplists:get_value(uid, Items),
        keywords => keywords_of(Items),
        internal_date => internaldate_epoch(Items),
        size => proplists:get_value(size, Items, 0)
    }}.

%% Updated flags via CONDSTORE CHANGEDSINCE, when available.
fetch_updated(_Pid, _Caps, undefined) ->
    [];
fetch_updated(Pid, Caps, PrevModSeq) ->
    case maps:get(condstore, Caps, false) orelse maps:get(qresync, Caps, false) of
        false ->
            [];
        true ->
            %% CHANGEDSINCE is a FETCH modifier appended after the item list.
            Cmd = fun(T) ->
                {
                    [
                        T,
                        <<" UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE ">>,
                        integer_to_binary(PrevModSeq),
                        <<")\r\n">>
                    ],
                    undefined
                }
            end,
            case run(Pid, Cmd) of
                {ok, Untagged, {ok, _, _}} ->
                    [
                        {updated, #{
                            uid => proplists:get_value(uid, I),
                            keywords => keywords_of(I)
                        }}
                     || {fetch, _Seq, I} <- Untagged,
                        proplists:is_defined(uid, I)
                    ];
                _ ->
                    []
            end
    end.

%%====================================================================
%% Message fetch
%%====================================================================

-spec fetch_message(conn(), binary(), term(), mailio_adapter:fetch_sink()) ->
    {ok, #{size := non_neg_integer()}} | {error, term()}.
fetch_message(#{pid := Pid}, MailboxId, Uid, Sink) ->
    case do_examine(Pid, MailboxId) of
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

body_from(Untagged, Uid) ->
    Matches = [
        proplists:get_value(body, I)
     || {fetch, _Seq, I} <- Untagged,
        proplists:get_value(uid, I) =:= Uid,
        proplists:get_value(body, I) =/= undefined
    ],
    case Matches of
        [Body | _] when is_binary(Body) -> {ok, Body};
        _ ->
            %% Fall back to the first body returned (single-uid fetch).
            AnyBody = [
                B
             || {fetch, _S, I} <- Untagged,
                B <- [proplists:get_value(body, I)],
                is_binary(B)
            ],
            case AnyBody of
                [Body | _] -> {ok, Body};
                _ -> not_found
            end
    end.

%%====================================================================
%% Mutations
%%====================================================================

-spec set_keywords(conn(), binary(), term(), [binary()], [binary()]) ->
    ok | {error, term()}.
set_keywords(#{pid := Pid}, MailboxId, Uid, Add, Remove) ->
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
move(#{pid := Pid, caps := Caps}, FromMailbox, Uid, ToMailbox) ->
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
            fun() -> do_uid_expunge(Pid, Uid) end
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

-spec expunge(conn(), binary(), [term()]) -> ok | {error, term()}.
expunge(#{pid := Pid}, MailboxId, Uids) ->
    case do_select(Pid, MailboxId) of
        {ok, _} ->
            ok_chain([
                fun() -> store(Pid, format_set(Uids), add, [<<"\\Deleted">>]) end,
                fun() -> do_expunge(Pid) end
            ]);
        Other ->
            command_error(Other)
    end.

do_expunge(Pid) ->
    case run(Pid, fun(T) -> {mailio_imap_proto:expunge(T), undefined} end) of
        {ok, _, {ok, _, _}} -> ok;
        Other -> command_error(Other)
    end.

do_uid_expunge(Pid, Uid) ->
    case run(Pid, fun(T) -> {mailio_imap_proto:uid_expunge(T, Uid), undefined} end) of
        {ok, _, {ok, _, _}} -> ok;
        %% UIDPLUS unsupported: fall back to plain EXPUNGE.
        _ -> do_expunge(Pid)
    end.

%%====================================================================
%% Watch (IDLE)
%%====================================================================

-spec watch(conn(), binary(), pid()) -> {ok, term()} | {error, not_supported | term()}.
watch(#{pid := Pid, caps := Caps}, MailboxId, NotifyPid) ->
    case maps:get(idle, Caps, false) of
        false ->
            {error, not_supported};
        true ->
            case do_examine(Pid, MailboxId) of
                {ok, _} ->
                    case mailio_imap_conn:idle_start(Pid, NotifyPid) of
                        ok -> {ok, {idle, Pid}};
                        Other -> command_error(Other)
                    end;
                Other ->
                    command_error(Other)
            end
    end.

-spec unwatch(conn(), term()) -> ok.
unwatch(#{pid := Pid}, {idle, Pid}) ->
    mailio_imap_conn:idle_stop(Pid);
unwatch(_Conn, _Ref) ->
    ok.

%% List all uids currently present (UID SEARCH ALL).
-spec list_uids(conn(), binary()) -> {ok, [integer()]} | {error, term()}.
list_uids(#{pid := Pid}, MailboxId) ->
    case do_examine(Pid, MailboxId) of
        {ok, _} ->
            case run(Pid, fun(T) -> {mailio_imap_proto:uid_search(T, <<"ALL">>), undefined} end) of
                {ok, Untagged, {ok, _, _}} ->
                    Uids = lists:append([Us || {search, Us} <- Untagged]),
                    {ok, lists:usort(Uids)};
                Other ->
                    command_error(Other)
            end;
        Other ->
            command_error(Other)
    end.

%%====================================================================
%% Selection and cursor helpers
%%====================================================================

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
            exists => 0,
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
select_field({status_resp, ok, {<<"UIDNEXT">>, [{number, V}]}, _}, Acc) ->
    Acc#{uidnext => V};
select_field({status_resp, ok, {<<"HIGHESTMODSEQ">>, [{number, V}]}, _}, Acc) ->
    Acc#{highestmodseq => V};
select_field(_, Acc) ->
    Acc.

sel_to_state(#{uidvalidity := UV, uidnext := UN, highestmodseq := MS}) ->
    #{uidvalidity => UV, uidnext => UN, highestmodseq => MS}.

encode(#{uidvalidity := UV, uidnext := UN, highestmodseq := MS}) ->
    mailio_imap_map:encode_state(#{
        uidvalidity => UV,
        uidnext => UN,
        highestmodseq => MS
    }).

uidvalidity_changed(#{uidvalidity := undefined}, _New) -> false;
uidvalidity_changed(#{uidvalidity := Prev}, #{uidvalidity := New}) -> Prev =/= New.

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

format_set(Uids) when is_list(Uids) -> mailio_imap_proto:format_seqset(Uids);
format_set(Uid) -> Uid.

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
