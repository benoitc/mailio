%%% @doc Thin helper over barrel_docdb.
%%%
%%% This is deliberately not an abstraction layer: it normalizes return
%%% shapes, threads Mailio's configured data directory into database
%%% creation, and gives the rest of the code one place to call for doc
%%% CRUD, batch writes, queries, the changes feed, and attachment
%%% streaming. barrel_docdb is a hard dependency; there is no second
%%% backend.
-module(mailio_db).

-export([ensure_db/1, open_db/1, close_db/1, delete_db/1]).
-export([get/2, get_many/2, put/2, put_batch/2, put_batch_strict/2, delete/2, delete/3]).
-export([find/2, find/3, explain/2, by_id_prefix/2]).
-export([changes/2, changes/3, subscribe_changes/2, subscribe_path/2, unsubscribe/1]).
-export([put_attachment/4, get_attachment/3, open_attachment_stream/3,
         read_attachment_chunk/1, close_attachment_stream/1]).

-export_type([db/0, doc/0, doc_id/0, rev/0, cursor/0, change/0]).

-type db() :: binary().
-type doc() :: map().
-type doc_id() :: binary().
-type rev() :: binary().
-type cursor() :: barrel_hlc:timestamp() | first.
-type change() :: map().

%%====================================================================
%% Database lifecycle
%%====================================================================

%% @doc Open the named database, creating it (under Mailio's data dir) if
%% it does not yet exist.
-spec ensure_db(db()) -> {ok, pid()} | {error, term()}.
ensure_db(Name) when is_binary(Name) ->
    case barrel_docdb:open_db(Name) of
        {ok, Pid} -> {ok, Pid};
        {error, _} ->
            case barrel_docdb:create_db(Name, #{data_dir => mailio_config:data_dir()}) of
                {ok, Pid} -> {ok, Pid};
                {error, already_exists} -> barrel_docdb:open_db(Name);
                {error, _} = Err -> Err
            end
    end.

-spec open_db(db()) -> {ok, pid()} | {error, term()}.
open_db(Name) -> barrel_docdb:open_db(Name).

-spec close_db(db()) -> ok | {error, term()}.
close_db(Name) -> barrel_docdb:close_db(Name).

-spec delete_db(db()) -> ok | {error, term()}.
delete_db(Name) -> barrel_docdb:delete_db(Name).

%%====================================================================
%% Document CRUD
%%====================================================================

-spec get(db(), doc_id()) -> {ok, doc()} | {error, not_found}.
get(Db, Id) ->
    case barrel_docdb:get_doc(Db, Id) of
        {ok, Doc} -> {ok, Doc};
        {error, not_found} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

%% @doc Bulk read. Returns a list aligned with `Ids', each element
%% `{ok, Doc}' or `{error, not_found}'.
-spec get_many(db(), [doc_id()]) -> [{ok, doc()} | {error, term()}].
get_many(Db, Ids) ->
    barrel_docdb:get_docs(Db, Ids).

%% @doc Create or update one document. The doc must carry `<<"id">>';
%% for updates it must also carry `<<"_rev">>'. Returns the new revision.
-spec put(db(), doc()) -> {ok, doc_id(), rev()} | {error, term()}.
put(Db, Doc) when is_map(Doc) ->
    case barrel_docdb:put_doc(Db, Doc) of
        {ok, #{<<"id">> := Id, <<"rev">> := Rev}} ->
            {ok, Id, Rev};
        {error, conflict} ->
            %% A create (no `_rev') conflicts only with a tombstone, since
            %% all writes for an account are serialized by one writer.
            %% Re-creating over a deleted doc requires its tombstone rev;
            %% recover it and retry. Real updates (carrying `_rev') keep the
            %% conflict.
            case maps:is_key(<<"_rev">>, Doc) of
                true -> {error, conflict};
                false -> recreate_over_tombstone(Db, Doc)
            end;
        {error, _} = Err ->
            Err
    end.

recreate_over_tombstone(Db, Doc) ->
    Id = maps:get(<<"id">>, Doc),
    case barrel_docdb:get_docs(Db, [Id], #{include_deleted => true}) of
        [{ok, #{<<"_rev">> := Rev}}] ->
            case barrel_docdb:put_doc(Db, Doc#{<<"_rev">> => Rev}) of
                {ok, #{<<"id">> := Id2, <<"rev">> := R2}} -> {ok, Id2, R2};
                {error, _} = Err -> Err
            end;
        _ ->
            {error, conflict}
    end.

%% @doc Batch write. Returns the raw per-doc result list (aligned with
%% input order). Use {@link put_batch_strict/2} when any failure should
%% abort with an error.
-spec put_batch(db(), [doc()]) -> [{ok, doc()} | {error, term()}].
put_batch(Db, Docs) when is_list(Docs) ->
    barrel_docdb:put_docs(Db, Docs).

%% @doc Batch write that collapses to a single `{ok, Results}' only if
%% every doc succeeded, else `{error, {batch_failed, FailedResults}}'.
-spec put_batch_strict(db(), [doc()]) ->
    {ok, [doc()]} | {error, {batch_failed, [term()]}}.
put_batch_strict(Db, Docs) ->
    Results = barrel_docdb:put_docs(Db, Docs),
    Failed = [R || {error, _} = R <- Results],
    case Failed of
        [] -> {ok, [Doc || {ok, Doc} <- Results]};
        _ -> {error, {batch_failed, Failed}}
    end.

-spec delete(db(), doc_id()) -> {ok, rev()} | {error, term()}.
delete(Db, Id) ->
    case barrel_docdb:delete_doc(Db, Id) of
        {ok, #{<<"rev">> := Rev}} -> {ok, Rev};
        {error, _} = Err -> Err
    end.

-spec delete(db(), doc_id(), rev()) -> {ok, rev()} | {error, term()}.
delete(Db, Id, Rev) ->
    case barrel_docdb:delete_doc(Db, Id, #{<<"_rev">> => Rev}) of
        {ok, #{<<"rev">> := NewRev}} -> {ok, NewRev};
        {error, _} = Err -> Err
    end.

%%====================================================================
%% Queries
%%====================================================================

-spec find(db(), map()) -> {ok, [doc()], map()} | {error, term()}.
find(Db, QuerySpec) ->
    unwrap(barrel_docdb:find(Db, QuerySpec)).

-spec find(db(), map(), map()) -> {ok, [doc()], map()} | {error, term()}.
find(Db, QuerySpec, Opts) ->
    unwrap(barrel_docdb:find(Db, QuerySpec, Opts)).

%% barrel `find' returns result wrappers `#{<<"id">>, <<"doc">> => Doc}'
%% (the body nested under `doc'). Unwrap to the actual documents; when
%% `include_docs' was false there is no `doc', so keep the `{id}' wrapper.
unwrap({ok, Results, Meta}) ->
    {ok, [maps:get(<<"doc">>, R, R) || R <- Results], Meta};
unwrap({error, _} = Err) ->
    Err.

%% @doc Return the query plan for a spec, for index-coverage assertions.
-spec explain(db(), map()) -> {ok, map()} | {error, term()}.
explain(Db, QuerySpec) ->
    barrel_docdb:explain(Db, QuerySpec).

%% @doc Enumerate documents whose id starts with `Prefix' via barrel's
%% primary-key range scan (no secondary index needed). Used to list a
%% collection by its path-style id namespace (e.g. `<<"email/">>').
-spec by_id_prefix(db(), binary()) -> {ok, [doc()]} | {error, term()}.
by_id_prefix(Db, Prefix) ->
    case unwrap(barrel_docdb:find(Db, #{id_prefix => Prefix}, #{limit => 1000000})) of
        {ok, Docs, _Meta} -> {ok, Docs};
        {error, _} = Err -> Err
    end.

%%====================================================================
%% Changes feed and subscriptions
%%====================================================================

%% @doc Changes since a cursor. Returns `{ok, Changes, NewCursor}' where
%% `NewCursor' is the HLC to pass next time.
-spec changes(db(), cursor()) -> {ok, [change()], cursor()}.
changes(Db, Since) ->
    barrel_docdb:get_changes(Db, Since).

-spec changes(db(), cursor(), map()) -> {ok, [change()], cursor()}.
changes(Db, Since, Opts) ->
    barrel_docdb:get_changes(Db, Since, Opts).

%% @doc Live change stream as a process; messages arrive per barrel's
%% changes-stream protocol.
-spec subscribe_changes(db(), cursor()) -> {ok, pid()} | {error, term()}.
subscribe_changes(Db, Since) ->
    barrel_docdb:subscribe_changes(Db, Since).

%% @doc MQTT-style path subscription. NOTE: patterns match document field
%% paths, not document ids; the events layer is driven by the changes
%% feed, this is for targeted field-level watches.
-spec subscribe_path(db(), binary()) -> {ok, reference()} | {error, term()}.
subscribe_path(Db, Pattern) ->
    barrel_docdb:subscribe(Db, Pattern).

-spec unsubscribe(reference()) -> ok.
unsubscribe(Ref) ->
    barrel_docdb:unsubscribe(Ref).

%%====================================================================
%% Attachments (blob storage)
%%====================================================================

-spec put_attachment(db(), doc_id(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
put_attachment(Db, DocId, Name, Data) ->
    barrel_docdb:put_attachment(Db, DocId, Name, Data).

-spec get_attachment(db(), doc_id(), binary()) ->
    {ok, binary()} | {error, term()}.
get_attachment(Db, DocId, Name) ->
    barrel_docdb:get_attachment(Db, DocId, Name).

-spec open_attachment_stream(db(), doc_id(), binary()) ->
    {ok, map()} | {error, term()}.
open_attachment_stream(Db, DocId, Name) ->
    barrel_docdb:open_attachment_stream(Db, DocId, Name).

-spec read_attachment_chunk(map()) -> {ok, binary(), map()} | eof | {error, term()}.
read_attachment_chunk(Stream) ->
    barrel_docdb:read_attachment_chunk(Stream).

-spec close_attachment_stream(map()) -> ok.
close_attachment_stream(Stream) ->
    barrel_docdb:close_attachment_stream(Stream).
