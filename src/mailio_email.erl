%%% @doc Email model and JMAP Email facade.
%%%
%%% An email document mirrors JMAP Email (RFC 8621 s4): immutable
%%% content-addressed id, `mailboxIds' and `keywords' as `#{Key => true}'
%%% maps, header convenience properties, and a body structure. Mailio
%%% internals (IMAP uid lists, normalized index fields, parse version)
%%% live under the `mailio' sub-map.
%%%
%%% The accessor functions are pure (they inspect maps). The JMAP facade
%%% ({@link get/3}, {@link query/2}, {@link changes/3}) reads the account
%%% database to serve RFC 8621 Email/get, Email/query, and Email/changes.
-module(mailio_email).

-compile({no_auto_import, [size/1]}).

-include("mailio.hrl").

-export([doc_id/1, id_of/1]).
-export([blob_id/1, thread_id/1, subject/1, received_at/1, size/1]).
-export([mailbox_ids/1, in_mailbox/2, add_mailbox/2, remove_mailbox/2]).
-export([keywords/1, has_keyword/2, add_keyword/2, remove_keyword/2,
         set_keyword/3, is_seen/1]).
-export([imap_entries/2, add_imap_entry/3]).

%% JMAP Email facade
-export([get/3, query/2, changes/3]).

-export_type([email/0, address/0]).

-type email() :: map().
-type address() :: #{binary() => binary()}.   %% #{<<"name">> => _, <<"email">> => _}

%%====================================================================
%% Ids
%%====================================================================

-spec doc_id(binary()) -> binary().
doc_id(EmailId) when is_binary(EmailId) ->
    <<?ID_EMAIL, EmailId/binary>>.

-spec id_of(email()) -> binary().
id_of(#{<<"id">> := <<?ID_EMAIL, Id/binary>>}) -> Id.

%%====================================================================
%% Simple accessors
%%====================================================================

-spec blob_id(email()) -> binary().
blob_id(#{<<"blobId">> := B}) -> B.

-spec thread_id(email()) -> binary() | undefined.
thread_id(Email) -> maps:get(<<"threadId">>, Email, undefined).

-spec subject(email()) -> binary() | null.
subject(Email) -> maps:get(<<"subject">>, Email, null).

-spec received_at(email()) -> binary() | undefined.
received_at(Email) -> maps:get(<<"receivedAt">>, Email, undefined).

-spec size(email()) -> non_neg_integer().
size(#{<<"size">> := S}) -> S.

%%====================================================================
%% Mailbox membership (#{MailboxId => true})
%%====================================================================

-spec mailbox_ids(email()) -> [binary()].
mailbox_ids(Email) ->
    maps:keys(maps:get(<<"mailboxIds">>, Email, #{})).

-spec in_mailbox(email(), binary()) -> boolean().
in_mailbox(Email, MailboxId) ->
    maps:is_key(MailboxId, maps:get(<<"mailboxIds">>, Email, #{})).

-spec add_mailbox(email(), binary()) -> email().
add_mailbox(Email, MailboxId) ->
    M = maps:get(<<"mailboxIds">>, Email, #{}),
    Email#{<<"mailboxIds">> => M#{MailboxId => true}}.

-spec remove_mailbox(email(), binary()) -> email().
remove_mailbox(Email, MailboxId) ->
    M = maps:get(<<"mailboxIds">>, Email, #{}),
    Email#{<<"mailboxIds">> => maps:remove(MailboxId, M)}.

%%====================================================================
%% Keywords (#{Keyword => true})
%%====================================================================

-spec keywords(email()) -> [binary()].
keywords(Email) ->
    maps:keys(maps:get(<<"keywords">>, Email, #{})).

-spec has_keyword(email(), binary()) -> boolean().
has_keyword(Email, Keyword) ->
    maps:is_key(Keyword, maps:get(<<"keywords">>, Email, #{})).

-spec add_keyword(email(), binary()) -> email().
add_keyword(Email, Keyword) ->
    set_keyword(Email, Keyword, true).

-spec remove_keyword(email(), binary()) -> email().
remove_keyword(Email, Keyword) ->
    set_keyword(Email, Keyword, false).

-spec set_keyword(email(), binary(), boolean()) -> email().
set_keyword(Email, Keyword, true) ->
    K = maps:get(<<"keywords">>, Email, #{}),
    Email#{<<"keywords">> => K#{Keyword => true}};
set_keyword(Email, Keyword, false) ->
    K = maps:get(<<"keywords">>, Email, #{}),
    Email#{<<"keywords">> => maps:remove(Keyword, K)}.

-spec is_seen(email()) -> boolean().
is_seen(Email) -> has_keyword(Email, ?KW_SEEN).

%%====================================================================
%% IMAP uid entries: _mailio.imap is #{MailboxId => [Entry]} where each
%% entry is #{uid, uidvalidity, modseq, flags}. The list handles
%% byte-identical duplicate delivery within one mailbox.
%%====================================================================

-spec imap_entries(email(), binary()) -> [map()].
imap_entries(Email, MailboxId) ->
    Imap = maps:get(<<"imap">>, maps:get(?MAILIO_NS, Email, #{}), #{}),
    maps:get(MailboxId, Imap, []).

%% @doc Append a uid entry for a mailbox, de-duplicating by uid+uidvalidity.
-spec add_imap_entry(email(), binary(), map()) -> email().
add_imap_entry(Email, MailboxId, Entry) ->
    Ns = maps:get(?MAILIO_NS, Email, #{}),
    Imap = maps:get(<<"imap">>, Ns, #{}),
    Existing = maps:get(MailboxId, Imap, []),
    Key = {maps:get(<<"uid">>, Entry), maps:get(<<"uidvalidity">>, Entry)},
    Pruned = [E || E <- Existing,
                   {maps:get(<<"uid">>, E), maps:get(<<"uidvalidity">>, E)} =/= Key],
    Imap2 = Imap#{MailboxId => [Entry | Pruned]},
    Email#{?MAILIO_NS => Ns#{<<"imap">> => Imap2}}.

%%====================================================================
%% JMAP Email/get
%%====================================================================

%% @doc RFC 8621 Email/get. `Properties' is `all' or a list of JMAP
%% property names; the pseudo-property `<<"bodyValues">>' includes the
%% extracted plain-text body. Returns the standard get response shape.
-spec get(binary(), [binary()], all | [binary()]) -> {ok, map()}.
get(Account, Ids, Properties) ->
    Db = mailio_account:db_name(Account),
    {Found, NotFound} = lists:foldr(
        fun(Id, {Acc, NF}) ->
            case mailio_db:get(Db, doc_id(Id)) of
                {ok, Doc} -> {[project(Db, Doc, Properties) | Acc], NF};
                {error, not_found} -> {Acc, [Id | NF]}
            end
        end, {[], []}, Ids),
    {ok, #{<<"accountId">> => Account,
           <<"state">> => mailio_account:state_token(Account),
           <<"list">> => Found,
           <<"notFound">> => NotFound}}.

%% Strip internal fields, expose the bare JMAP id, and project to the
%% requested properties.
project(Db, Doc, Properties) ->
    Clean0 = maps:remove(?MAILIO_NS, maps:remove(<<"_rev">>, Doc)),
    Clean = Clean0#{<<"id">> => id_of(Doc)},
    WithBody = maybe_body_values(Db, Doc, Clean, Properties),
    case Properties of
        all -> WithBody;
        Props ->
            Keep = [<<"id">> | Props],
            maps:with(lists:usort(Keep ++ extra_props(Props)), WithBody)
    end.

extra_props(Props) ->
    case lists:member(<<"bodyValues">>, Props) of
        true -> [<<"bodyValues">>];
        false -> []
    end.

maybe_body_values(Db, Doc, Clean, Properties) ->
    Want = Properties =:= all orelse lists:member(<<"bodyValues">>, Properties),
    case Want of
        false -> Clean;
        true ->
            EmailId = id_of(Doc),
            Text = body_text(Db, EmailId),
            Clean#{<<"bodyValues">> => #{<<"text">> =>
                       #{<<"value">> => Text, <<"isTruncated">> => false}}}
    end.

%%====================================================================
%% JMAP Email/query
%%====================================================================

%% @doc RFC 8621 Email/query. Request keys: `filter', `sort', `position',
%% `limit', `collapseThreads'. Structural filter conditions are pushed to an
%% indexed `barrel' query; the remainder (substring/text) is evaluated in
%% Erlang. Returns the standard query response shape.
-spec query(binary(), map()) -> {ok, map()}.
query(Account, Request) ->
    Db = mailio_account:db_name(Account),
    Filter = maps:get(filter, Request, maps:get(<<"filter">>, Request, #{})),
    Sort = maps:get(sort, Request, maps:get(<<"sort">>, Request, default_sort())),
    Position = maps:get(position, Request, maps:get(<<"position">>, Request, 0)),
    Limit = maps:get(limit, Request, maps:get(<<"limit">>, Request, undefined)),
    Collapse = maps:get(collapseThreads, Request,
                        maps:get(<<"collapseThreads">>, Request, false)),

    Candidates = candidates(Db, Filter),
    NeedBody = mailio_filter:needs_body(Filter),
    Matched = [E || E <- Candidates,
                    mailio_filter:matches(E, body_getter(Db, E, NeedBody), Filter)],
    Sorted = sort_emails(Matched, Sort),
    Collapsed = case Collapse of true -> collapse_threads(Sorted); false -> Sorted end,
    Total = length(Collapsed),
    Page = paginate(Collapsed, Position, Limit),
    Ids = [id_of(E) || E <- Page],
    {ok, #{<<"accountId">> => Account,
           <<"queryState">> => mailio_account:state_token(Account),
           <<"canCalculateChanges">> => false,
           <<"position">> => Position,
           <<"total">> => Total,
           <<"ids">> => Ids,
           <<"collapseThreads">> => Collapse}}.

candidates(Db, Filter) ->
    case mailio_filter:index_query(Filter) of
        all ->
            all_emails(Db);
        {where, Wheres} ->
            case mailio_db:find(Db, #{where => Wheres},
                                #{include_docs => true, limit => 1000000}) of
                {ok, Docs, _} -> Docs;
                {error, _} -> []
            end
    end.

all_emails(Db) ->
    case mailio_db:by_id_prefix(Db, <<?ID_EMAIL>>) of
        {ok, Docs} -> Docs;
        {error, _} -> []
    end.

%% Lazy body-text getter (only fetched if a body/text condition needs it).
body_getter(_Db, _Email, false) ->
    fun() -> <<>> end;
body_getter(Db, Email, true) ->
    fun() -> body_text(Db, id_of(Email)) end.

body_text(Db, EmailId) ->
    case mailio_db:get(Db, <<?ID_TEXT, EmailId/binary>>) of
        {ok, #{<<"body_text">> := T}} -> T;
        _ -> <<>>
    end.

%%====================================================================
%% Sorting / collapsing / pagination
%%====================================================================

default_sort() ->
    [#{<<"property">> => <<"receivedAt">>, <<"isAscending">> => false}].

sort_emails(Emails, Comparators) ->
    lists:sort(fun(A, B) -> compare_chain(A, B, Comparators) =< 0 end, Emails).

compare_chain(_A, _B, []) -> 0;
compare_chain(A, B, [Comp | Rest]) ->
    {Prop, Asc} = comparator(Comp),
    case cmp(sort_key(A, Prop), sort_key(B, Prop)) of
        0 -> compare_chain(A, B, Rest);
        N when Asc -> N;
        N -> -N
    end.

comparator(Comp) ->
    Prop = maps:get(property, Comp, maps:get(<<"property">>, Comp, <<"receivedAt">>)),
    Asc = maps:get(isAscending, Comp, maps:get(<<"isAscending">>, Comp, true)),
    {Prop, Asc}.

sort_key(E, <<"receivedAt">>) -> maps:get(<<"received_ts">>, maps:get(?MAILIO_NS, E, #{}), 0);
sort_key(E, <<"size">>) -> size(E);
sort_key(E, <<"sentAt">>) -> null_low(maps:get(<<"sentAt">>, E, null));
sort_key(E, <<"subject">>) -> null_low(maps:get(<<"subject">>, E, null));
sort_key(E, <<"from">>) -> first_addr(maps:get(<<"from">>, E, null));
sort_key(E, _) -> maps:get(<<"received_ts">>, maps:get(?MAILIO_NS, E, #{}), 0).

null_low(null) -> <<>>;
null_low(V) -> V.

first_addr([#{<<"email">> := Em} | _]) -> Em;
first_addr(_) -> <<>>.

cmp(X, X) -> 0;
cmp(X, Y) when X < Y -> -1;
cmp(_X, _Y) -> 1.

collapse_threads(Emails) ->
    {Out, _Seen} = lists:foldl(
        fun(E, {Acc, Seen}) ->
            Tid = thread_id(E),
            case sets:is_element(Tid, Seen) of
                true -> {Acc, Seen};
                false -> {[E | Acc], sets:add_element(Tid, Seen)}
            end
        end, {[], sets:new()}, Emails),
    lists:reverse(Out).

paginate(Emails, Position, Limit) ->
    Dropped = lists:nthtail(min(Position, length(Emails)), Emails),
    case Limit of
        undefined -> Dropped;
        N -> lists:sublist(Dropped, N)
    end.

%%====================================================================
%% JMAP Email/changes
%%====================================================================

%% @doc RFC 8621 Email/changes since an opaque state token.
-spec changes(binary(), binary(), map()) -> {ok, map()} | {error, cannot_calculate_changes}.
changes(Account, SinceState, Opts) ->
    case mailio_cursor:decode(SinceState) of
        {ok, Cursor} ->
            MaxChanges = maps:get(maxChanges, Opts, maps:get(<<"maxChanges">>, Opts, 1000)),
            {ok, Envs, NewCursor, More} =
                mailio_changes:since(Account, Cursor, #{types => [email], limit => MaxChanges}),
            {Created, Updated, Destroyed} = group_changes(Envs),
            {ok, #{<<"accountId">> => Account,
                   <<"oldState">> => SinceState,
                   <<"newState">> => mailio_cursor:encode(NewCursor),
                   <<"hasMoreChanges">> => More =:= more,
                   <<"created">> => Created,
                   <<"updated">> => Updated,
                   <<"destroyed">> => Destroyed}};
        {error, invalid_state} ->
            {error, cannot_calculate_changes}
    end.

group_changes(Envs) ->
    lists:foldr(
        fun(#{verb := Verb, object_id := Id}, {C, U, D}) ->
            case Verb of
                created -> {[Id | C], U, D};
                updated -> {C, [Id | U], D};
                destroyed -> {C, U, [Id | D]}
            end
        end, {[], [], []}, Envs).
