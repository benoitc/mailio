%%% @doc Email model (pure).
%%%
%%% An email document mirrors JMAP Email (RFC 8621 s4): immutable
%%% content-addressed id, `mailboxIds' and `keywords' as `#{Key => true}'
%%% maps, header convenience properties, and a body structure. Mailio
%%% internals (IMAP uid lists, normalized index fields, parse version)
%%% live under the `_mailio' sub-map.
%%%
%%% This module is pure: it builds and inspects maps. Persistence,
%%% threading, and indexing live elsewhere.
-module(mailio_email).

-include("mailio.hrl").

-export([doc_id/1, id_of/1]).
-export([blob_id/1, thread_id/1, subject/1, received_at/1, size/1]).
-export([mailbox_ids/1, in_mailbox/2, add_mailbox/2, remove_mailbox/2]).
-export([keywords/1, has_keyword/2, add_keyword/2, remove_keyword/2,
         set_keyword/3, is_seen/1]).
-export([imap_entries/2, add_imap_entry/3]).

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
