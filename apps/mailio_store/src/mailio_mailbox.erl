%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Mailbox model (pure).
%%%
%%% A mailbox document mirrors JMAP Mailbox (RFC 8621 s2) with Mailio
%%% internals under the {@link mailio.hrl} `_mailio' sub-map (IMAP folder
%%% name, delimiter, uidvalidity, special-use flags).
-module(mailio_mailbox).

-include("mailio_store.hrl").

-export([new/1, new/2]).
-export([doc_id/1, id_of/1, name/1, role/1, parent_id/1, imap_name/1, uidvalidity/1]).
-export([with_counters/2]).
-export([get/2, list/1]).

-export_type([mailbox/0]).

-type mailbox() :: map().

%% @doc Build a mailbox doc from required fields plus optional overrides.
-spec new(map()) -> mailbox().
new(Fields) ->
    new(mailio_id:mailbox_id(), Fields).

-spec new(binary(), map()) -> mailbox().
new(Id, Fields) when is_binary(Id), is_map(Fields) ->
    Name = maps:get(name, Fields),
    Internal = #{
        <<"imap_name">> => maps:get(imap_name, Fields, Name),
        <<"imap_delimiter">> => maps:get(imap_delimiter, Fields, <<"/">>),
        <<"uidvalidity">> => maps:get(uidvalidity, Fields, 0),
        <<"special_use">> => maps:get(special_use, Fields, [])
    },
    #{
        <<"id">> => <<?ID_MAILBOX, Id/binary>>,
        <<"name">> => Name,
        <<"parentId">> => maps:get(parent_id, Fields, null),
        <<"role">> => maps:get(role, Fields, null),
        <<"sortOrder">> => maps:get(sort_order, Fields, 0),
        <<"totalEmails">> => 0,
        <<"unreadEmails">> => 0,
        <<"totalThreads">> => 0,
        <<"unreadThreads">> => 0,
        <<"isSubscribed">> => maps:get(is_subscribed, Fields, true),
        <<"myRights">> => default_rights(),
        ?MAILIO_NS => Internal
    }.

-spec doc_id(binary()) -> binary().
doc_id(Id) when is_binary(Id) ->
    <<?ID_MAILBOX, Id/binary>>.

%% @doc Bare mailbox id (without the `mailbox/' prefix) of a mailbox doc.
-spec id_of(mailbox()) -> binary().
id_of(#{<<"id">> := <<?ID_MAILBOX, Id/binary>>}) -> Id.

-spec name(mailbox()) -> binary().
name(#{<<"name">> := N}) -> N.

-spec role(mailbox()) -> binary() | null.
role(#{<<"role">> := R}) -> R.

-spec parent_id(mailbox()) -> binary() | null.
parent_id(#{<<"parentId">> := P}) -> P.

-spec imap_name(mailbox()) -> binary().
imap_name(#{?MAILIO_NS := #{<<"imap_name">> := N}}) -> N.

-spec uidvalidity(mailbox()) -> non_neg_integer().
uidvalidity(#{?MAILIO_NS := #{<<"uidvalidity">> := U}}) -> U.

%% @doc Replace the four JMAP counter fields.
-spec with_counters(mailbox(), #{atom() => non_neg_integer()}) -> mailbox().
with_counters(Mailbox, Counters) ->
    Mailbox#{
        <<"totalEmails">> => maps:get(
            total_emails,
            Counters,
            maps:get(<<"totalEmails">>, Mailbox)
        ),
        <<"unreadEmails">> => maps:get(
            unread_emails,
            Counters,
            maps:get(<<"unreadEmails">>, Mailbox)
        ),
        <<"totalThreads">> => maps:get(
            total_threads,
            Counters,
            maps:get(<<"totalThreads">>, Mailbox)
        ),
        <<"unreadThreads">> => maps:get(
            unread_threads,
            Counters,
            maps:get(<<"unreadThreads">>, Mailbox)
        )
    }.

%%====================================================================
%% JMAP Mailbox facade
%%====================================================================

%% @doc RFC 8621 Mailbox/get. `Ids' is a list of mailbox ids or `all'.
-spec get(binary(), [binary()] | all) -> {ok, map()}.
get(Account, all) ->
    Db = mailio_account:db_name(Account),
    {ok, Docs} = mailio_db:by_id_prefix(Db, <<?ID_MAILBOX>>),
    {ok, #{
        <<"accountId">> => Account,
        <<"state">> => mailio_account:state_token(Account),
        <<"list">> => [project(D) || D <- Docs],
        <<"notFound">> => []
    }};
get(Account, Ids) when is_list(Ids) ->
    Db = mailio_account:db_name(Account),
    {Found, NotFound} = lists:foldr(
        fun(Id, {Acc, NF}) ->
            case mailio_db:get(Db, <<?ID_MAILBOX, Id/binary>>) of
                {ok, Doc} -> {[project(Doc) | Acc], NF};
                {error, not_found} -> {Acc, [Id | NF]}
            end
        end,
        {[], []},
        Ids
    ),
    {ok, #{
        <<"accountId">> => Account,
        <<"state">> => mailio_account:state_token(Account),
        <<"list">> => Found,
        <<"notFound">> => NotFound
    }}.

%% @doc List all mailbox ids for an account.
-spec list(binary()) -> {ok, [binary()]}.
list(Account) ->
    {ok, #{<<"list">> := Mailboxes}} = get(Account, all),
    {ok, [maps:get(<<"id">>, M) || M <- Mailboxes]}.

project(Doc) ->
    maps:remove(?MAILIO_NS, maps:remove(<<"_rev">>, Doc#{<<"id">> => id_of(Doc)})).

-spec default_rights() -> map().
default_rights() ->
    #{
        <<"mayReadItems">> => true,
        <<"mayAddItems">> => true,
        <<"mayRemoveItems">> => true,
        <<"maySetSeen">> => true,
        <<"maySetKeywords">> => true,
        <<"mayCreateChild">> => true,
        <<"mayRename">> => true,
        <<"mayDelete">> => true,
        <<"maySubmit">> => true
    }.
