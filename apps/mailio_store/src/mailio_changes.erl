%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Durable changes-feed API.
%%%
%%% Reads the barrel changes feed for an account and normalizes each raw
%%% document change into a domain event envelope (created/updated/destroyed
%%% per entity type). This is the source of truth for both the live event
%%% pump and durable consumers (indexer, workflow engine), which persist
%%% the returned cursor and resume from it — giving at-least-once delivery
%%% without building durability into the dispatcher.
-module(mailio_changes).

-include("mailio_store.hrl").

-export([since/3, envelopes_for/3, domain_type/1]).

-export_type([envelope/0]).

-type envelope() :: #{
    v := 1,
    id := binary(),
    seq := mailio_cursor:token(),
    account_id := binary(),
    type := atom(),
    verb := created | updated | destroyed,
    object_id := binary(),
    data := map()
}.

%% Entity types that surface as domain events.
-define(DOMAIN_TYPES, [email, mailbox, thread, submission, identity]).

%%====================================================================
%% API
%%====================================================================

%% @doc Fetch normalized change envelopes for an account since a cursor.
%% `Cursor' is `first' or a barrel HLC timestamp. Options:
%% <ul>
%%   <li>`limit' - max raw changes to scan</li>
%%   <li>`types' - entity types to include (default: domain types)</li>
%%   <li>`include_internal' - also include blob/text/msgid/sync changes</li>
%% </ul>
%% Returns `{ok, Envelopes, NewCursor, more | done}'.
-spec since(binary(), barrel_hlc:timestamp() | first, map()) ->
    {ok, [envelope()], barrel_hlc:timestamp() | first, more | done}.
since(AccountId, Cursor, Opts) ->
    Db = mailio_account:db_name(AccountId),
    Limit = maps:get(limit, Opts, 1000),
    {ok, Changes, NewHlc} = mailio_db:changes(Db, Cursor, #{
        include_docs => true,
        limit => Limit
    }),
    Wanted = wanted_types(Opts),
    Envelopes = envelopes_for(AccountId, Changes, Wanted),
    More =
        case length(Changes) >= Limit of
            true -> more;
            false -> done
        end,
    {ok, Envelopes, NewHlc, More}.

%% @doc Build envelopes from raw barrel change maps, keeping only the
%% requested entity types.
-spec envelopes_for(binary(), [map()], [atom()] | all) -> [envelope()].
envelopes_for(AccountId, Changes, Wanted) ->
    lists:filtermap(
        fun(Change) -> to_envelope(AccountId, Change, Wanted) end,
        Changes
    ).

%% @doc Map a document id to its entity type atom.
-spec domain_type(binary()) -> atom().
domain_type(<<?ID_EMAIL, _/binary>>) -> email;
domain_type(<<?ID_MAILBOX, _/binary>>) -> mailbox;
domain_type(<<?ID_THREAD, _/binary>>) -> thread;
domain_type(<<?ID_SUBMISSION, _/binary>>) -> submission;
domain_type(<<?ID_IDENTITY, _/binary>>) -> identity;
domain_type(<<?ID_MSGID, _/binary>>) -> msgid;
domain_type(<<?ID_BLOB, _/binary>>) -> blob;
domain_type(<<?ID_TEXT, _/binary>>) -> text;
domain_type(<<?ID_SYNC_IMAP, _/binary>>) -> sync;
domain_type(_) -> other.

%%====================================================================
%% Internal
%%====================================================================

wanted_types(Opts) ->
    case maps:get(include_internal, Opts, false) of
        true -> all;
        false -> maps:get(types, Opts, ?DOMAIN_TYPES)
    end.

to_envelope(AccountId, Change, Wanted) ->
    DocId = maps:get(id, Change),
    Type = domain_type(DocId),
    case type_wanted(Type, Wanted) of
        false ->
            false;
        true ->
            Hlc = maps:get(hlc, Change),
            Rev = maps:get(rev, Change, <<>>),
            Deleted = maps:get(deleted, Change, false),
            Doc = maps:get(doc, Change, undefined),
            Envelope = #{
                v => 1,
                id => <<DocId/binary, "@", Rev/binary>>,
                seq => mailio_cursor:encode(Hlc),
                account_id => AccountId,
                type => Type,
                verb => verb(Deleted, AccountId, DocId),
                object_id => object_id(Type, DocId),
                data => data_for(Type, Doc)
            },
            {true, Envelope}
    end.

type_wanted(_Type, all) -> true;
type_wanted(Type, Types) -> lists:member(Type, Types).

%% barrel 3 revisions are `<hlc>@<writer>' and carry no generation, so
%% "created" means the document has a single version.
verb(true, _AccountId, _DocId) ->
    destroyed;
verb(false, AccountId, DocId) ->
    case mailio_db:version_count(mailio_account:db_name(AccountId), DocId) of
        1 -> created;
        _ -> updated
    end.

%% Strip the entity prefix to get the bare object id.
object_id(email, <<?ID_EMAIL, Id/binary>>) -> Id;
object_id(mailbox, <<?ID_MAILBOX, Id/binary>>) -> Id;
object_id(thread, <<?ID_THREAD, Id/binary>>) -> Id;
object_id(submission, <<?ID_SUBMISSION, Id/binary>>) -> Id;
object_id(identity, <<?ID_IDENTITY, Id/binary>>) -> Id;
object_id(_Type, DocId) -> DocId.

data_for(_Type, undefined) ->
    #{};
data_for(email, Doc) ->
    #{
        subject => maps:get(<<"subject">>, Doc, null),
        thread_id => maps:get(<<"threadId">>, Doc, undefined),
        mailbox_ids => maps:keys(maps:get(<<"mailboxIds">>, Doc, #{})),
        keywords => maps:keys(maps:get(<<"keywords">>, Doc, #{})),
        has_attachment => maps:get(<<"hasAttachment">>, Doc, false)
    };
data_for(mailbox, Doc) ->
    #{
        name => maps:get(<<"name">>, Doc, null),
        role => maps:get(<<"role">>, Doc, null)
    };
data_for(_Type, _Doc) ->
    #{}.
