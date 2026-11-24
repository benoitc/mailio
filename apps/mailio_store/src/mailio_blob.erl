%%% @doc Content-addressed blob storage over barrel attachments.
%%%
%%% A blob is stored as a document `blob/<sha256hex>' with metadata, plus a
%%% single `data' attachment holding the bytes. Because the id is the
%%% content hash, identical content (a raw message stored twice, a shared
%%% signature image) is naturally deduplicated; a `refs' map tracks which
%%% documents point at the blob so it can be garbage collected when the
%%% last reference is dropped.
%%%
%%% The bytes live in one of two places, chosen by `mailio_config:blob_backend/0':
%%% an attachment on the blob document (`docdb', the default) or a
%%% content-addressed file (`files', see {@link mailio_blob_files}). The blob
%%% document, its references and the grace period are the same either way. A
%%% blob is read from the configured place first and from the other one second,
%%% so blobs written before a switch stay readable.
%%%
%%% All functions take a database name and run in the caller (the account
%%% writer), which serializes access.
-module(mailio_blob).

-include("mailio_store.hrl").

-export([blob_id/1, doc_id/1]).
-export([put/3, get/2, exists/2, add_ref/3, remove_ref/3, ref_count/2]).
-export([sweep/3, has_bytes/2, hex_of/1]).
-export([install/3, check/1, repair/2, pull_missing/1, has_bytes_attachment/2]).
-export([migrate_to_files/2]).

%%====================================================================
%% Ids
%%====================================================================

%% @doc Public blob id (`sha256-<hex>') for content.
-spec blob_id(binary()) -> binary().
blob_id(Content) -> mailio_id:blob_id(Content).

%% @doc Document id (`blob/<hex>') for a public blob id or raw content.
-spec doc_id(binary()) -> binary().
doc_id(<<"sha256-", Hex/binary>>) -> <<?ID_BLOB, Hex/binary>>;
doc_id(Hex) when is_binary(Hex) -> <<?ID_BLOB, Hex/binary>>.

%%====================================================================
%% Storage
%%====================================================================

%% @doc Store content, attributing a reference to `RefId'. Idempotent: if
%% the blob already exists only the reference is added. Returns the public
%% blob id.
-spec put(binary(), binary(), binary()) -> {ok, binary()} | {error, term()}.
put(Db, Content, RefId) ->
    Hex = mailio_id:blob_hex(Content),
    BlobId = <<"sha256-", Hex/binary>>,
    DocId = <<?ID_BLOB, Hex/binary>>,
    case mailio_config:blob_backend() of
        files -> put_file(Db, Hex, DocId, BlobId, Content, RefId);
        docdb -> put_attachment_blob(Db, DocId, BlobId, Content, RefId)
    end.

%% files: the bytes first, then the document. A crash in between leaves an
%% unreferenced file (a check finds it), never a document without bytes. A
%% document that arrived by replication before its bytes gets them here.
put_file(Db, Hex, DocId, BlobId, Content, RefId) ->
    case mailio_blob_files:put(mailio_config:blob_root(), Db, Hex, Content) of
        ok -> upsert_ref(Db, DocId, BlobId, Content, RefId, <<"files">>);
        {error, _} = Err -> Err
    end.

%% docdb: the document first, because the bytes are an attachment on it.
put_attachment_blob(Db, DocId, BlobId, Content, RefId) ->
    case mailio_db:get(Db, DocId) of
        {ok, _} ->
            upsert_ref(Db, DocId, BlobId, Content, RefId, <<"docdb">>);
        {error, not_found} ->
            case upsert_ref(Db, DocId, BlobId, Content, RefId, <<"docdb">>) of
                {ok, _} ->
                    case mailio_db:put_attachment(Db, DocId, <<"data">>, Content) of
                        {ok, _} -> {ok, BlobId};
                        {error, _} = Err -> Err
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

%% Create the blob document, or add a reference to the existing one.
upsert_ref(Db, DocId, BlobId, Content, RefId, Store) ->
    case mailio_db:get(Db, DocId) of
        {ok, Existing} ->
            case mailio_db:put(Db, add_ref_to_doc(Existing, RefId)) of
                {ok, _, _} -> {ok, BlobId};
                {error, _} = Err -> Err
            end;
        {error, not_found} ->
            Doc = #{
                <<"id">> => DocId,
                <<"blobId">> => BlobId,
                <<"size">> => byte_size(Content),
                <<"store">> => Store,
                <<"refs">> => #{RefId => true}
            },
            case mailio_db:put(Db, Doc) of
                {ok, _, _} -> {ok, BlobId};
                {error, _} = Err -> Err
            end
    end.

%% @doc Fetch blob bytes by public blob id or hex.
-spec get(binary(), binary()) -> {ok, binary()} | {error, not_found}.
get(Db, BlobIdOrHex) ->
    Hex = hex_of(BlobIdOrHex),
    Order =
        case mailio_config:blob_backend() of
            files -> [files, docdb];
            docdb -> [docdb, files]
        end,
    first_found(Order, Db, Hex).

first_found([], _Db, _Hex) ->
    {error, not_found};
first_found([Where | Rest], Db, Hex) ->
    case read(Where, Db, Hex) of
        {ok, _} = Ok -> Ok;
        {error, _} -> first_found(Rest, Db, Hex)
    end.

read(files, Db, Hex) ->
    mailio_blob_files:get(mailio_config:blob_root(), Db, Hex);
read(docdb, Db, Hex) ->
    mailio_db:get_attachment(Db, <<?ID_BLOB, Hex/binary>>, <<"data">>).

%% @doc Are the bytes of this blob here, in either place? A blob document that
%% was replicated before its bytes has `exists/2' true and this false.
-spec has_bytes(binary(), binary()) -> boolean().
has_bytes(Db, BlobIdOrHex) ->
    case get(Db, BlobIdOrHex) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% @doc The hex hash of a public blob id (`sha256-<hex>'), a doc id or bare hex.
-spec hex_of(binary()) -> binary().
hex_of(<<"sha256-", Hex/binary>>) -> Hex;
hex_of(<<?ID_BLOB, Hex/binary>>) -> Hex;
hex_of(Hex) -> Hex.

-spec exists(binary(), binary()) -> boolean().
exists(Db, BlobIdOrHex) ->
    case mailio_db:get(Db, doc_id(BlobIdOrHex)) of
        {ok, _} -> true;
        _ -> false
    end.

-spec add_ref(binary(), binary(), binary()) -> ok | {error, term()}.
add_ref(Db, BlobIdOrHex, RefId) ->
    DocId = doc_id(BlobIdOrHex),
    case mailio_db:get(Db, DocId) of
        {ok, Doc} ->
            case mailio_db:put(Db, add_ref_to_doc(Doc, RefId)) of
                {ok, _, _} -> ok;
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc Drop a reference. When the last reference is gone the blob is
%% stamped `orphanedAt' (eligible for {@link sweep/3}); the stamp is cleared
%% if a reference is later re-added. Returns `{ok, orphaned | referenced}'.
-spec remove_ref(binary(), binary(), binary()) ->
    {ok, orphaned | referenced} | {error, term()}.
remove_ref(Db, BlobIdOrHex, RefId) ->
    DocId = doc_id(BlobIdOrHex),
    case mailio_db:get(Db, DocId) of
        {ok, Doc} ->
            Refs = maps:remove(RefId, maps:get(<<"refs">>, Doc, #{})),
            {Doc1, Result} =
                case maps:size(Refs) of
                    0 ->
                        {
                            Doc#{
                                <<"refs">> => Refs,
                                <<"orphanedAt">> => erlang:system_time(second)
                            },
                            orphaned
                        };
                    _ ->
                        {maps:remove(<<"orphanedAt">>, Doc#{<<"refs">> => Refs}), referenced}
                end,
            case mailio_db:put(Db, Doc1) of
                {ok, _, _} -> {ok, Result};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc Delete blobs orphaned before `Now - GraceSecs'. Returns the number
%% swept. Orphaned blobs keep a grace window so a delete immediately
%% followed by a re-ingest (which re-references the same content) does not
%% lose the bytes.
-spec sweep(binary(), integer(), non_neg_integer()) -> {ok, non_neg_integer()}.
sweep(Db, Now, GraceSecs) ->
    Cutoff = Now - GraceSecs,
    case mailio_db:find(Db, #{where => [{compare, [<<"orphanedAt">>], '=<', Cutoff}]}) of
        {ok, Docs, _} ->
            Deleted = lists:foldl(
                fun
                    (#{<<"id">> := Id, <<"refs">> := Refs}, N) when map_size(Refs) =:= 0 ->
                        case mailio_db:delete(Db, Id) of
                            {ok, _} ->
                                %% the attachment went with the document; a file is separate
                                _ = mailio_blob_files:delete(
                                    mailio_config:blob_root(), Db, hex_of(Id)
                                ),
                                N + 1;
                            _ ->
                                N
                        end;
                    (_, N) ->
                        N
                end,
                0,
                Docs
            ),
            {ok, Deleted};
        {error, _} ->
            {ok, 0}
    end.

-spec ref_count(binary(), binary()) -> non_neg_integer().
ref_count(Db, BlobIdOrHex) ->
    case mailio_db:get(Db, doc_id(BlobIdOrHex)) of
        {ok, Doc} -> maps:size(maps:get(<<"refs">>, Doc, #{}));
        _ -> 0
    end.

%%====================================================================
%% Internal
%%====================================================================

add_ref_to_doc(Doc, RefId) ->
    Refs = maps:get(<<"refs">>, Doc, #{}),
    %% Re-referencing revives an orphaned blob.
    maps:remove(<<"orphanedAt">>, Doc#{<<"refs">> => Refs#{RefId => true}}).

%%====================================================================
%% Consistency and replication
%%
%% Documents replicate through the database; the bytes of a `files' blob do
%% not. A replica therefore can hold a blob document before, or without, its
%% bytes. These functions find such blobs and fetch them by hash.
%%====================================================================

%% @doc Store bytes for a blob that already has a document, for example
%% bytes fetched from a peer. The bytes must hash to `Hex'.
-spec install(binary(), binary(), binary()) -> ok | {error, term()}.
install(Db, BlobIdOrHex, Bytes) ->
    Hex = hex_of(BlobIdOrHex),
    case mailio_id:blob_hex(Bytes) of
        Hex ->
            case mailio_config:blob_backend() of
                files ->
                    mailio_blob_files:put(mailio_config:blob_root(), Db, Hex, Bytes);
                docdb ->
                    case
                        mailio_db:put_attachment(Db, <<?ID_BLOB, Hex/binary>>, <<"data">>, Bytes)
                    of
                        {ok, _} -> ok;
                        {error, _} = Err -> Err
                    end
            end;
        _ ->
            {error, hash_mismatch}
    end.

%% @doc What is wrong with the blobs of a database:
%% `missing' have a document and no bytes, `corrupt' are files whose content
%% no longer matches their name, `orphan_files' are files no document names.
-spec check(binary()) ->
    {ok, #{missing := [binary()], corrupt := [binary()], orphan_files := [binary()]}}.
check(Db) ->
    Root = mailio_config:blob_root(),
    {ok, Docs} = mailio_db:by_id_prefix(Db, <<?ID_BLOB>>),
    Hexes = lists:sort([hex_of(Id) || #{<<"id">> := Id} <- Docs]),
    Files = mailio_blob_files:list(Root, Db),
    Corrupt = [H || H <- Files, mailio_blob_files:verify(Root, Db, H) =:= {error, corrupt}],
    Missing = [H || H <- Hexes, not bytes_present(Db, H) orelse lists:member(H, Corrupt)],
    {ok, #{
        missing => lists:sort(Missing),
        corrupt => lists:sort(Corrupt),
        orphan_files => lists:sort(Files -- Hexes)
    }}.

%% @doc Repair what {@link check/1} finds: move corrupt files aside, remove
%% orphan files older than `orphan_grace' seconds (a file is written just
%% before its document, so a young one may be mid-write), and fetch what is
%% missing from a peer with the configured `blob_fetcher'.
-spec repair(binary(), map()) -> {ok, map()}.
repair(Db, Opts) ->
    Root = mailio_config:blob_root(),
    Grace = maps:get(orphan_grace, Opts, 86400),
    Now = erlang:system_time(second),
    {ok, #{corrupt := Corrupt, orphan_files := Orphans}} = check(Db),
    lists:foreach(fun(H) -> mailio_blob_files:quarantine(Root, Db, H) end, Corrupt),
    Removed = [
        H
     || H <- Orphans,
        {ok, T} <- [mailio_blob_files:mtime(Root, Db, H)],
        Now - T >= Grace,
        mailio_blob_files:delete(Root, Db, H) =:= ok
    ],
    Pulled =
        case pull_missing(Db) of
            {ok, P} ->
                P;
            {error, no_fetcher} ->
                {ok, #{missing := Still}} = check(Db),
                #{fetched => 0, failed => Still}
        end,
    {ok, #{
        quarantined => length(Corrupt),
        orphans_removed => length(Removed),
        pulled => maps:get(fetched, Pulled),
        failed => maps:get(failed, Pulled)
    }}.

%% @doc Fetch the bytes of every blob that has a document and no bytes, with
%% the `blob_fetcher' setting: `fun((Db, Hex) -> {ok, Bytes} | {error, Why})'.
%% Bytes that do not hash to the name are refused.
-spec pull_missing(binary()) ->
    {ok, #{fetched := non_neg_integer(), failed := [binary()]}}
    | {error, no_fetcher}.
pull_missing(Db) ->
    case mailio_config:get(blob_fetcher) of
        Fetcher when is_function(Fetcher, 2) ->
            {ok, #{missing := Missing}} = check(Db),
            Results = [{H, fetch_one(Fetcher, Db, H)} || H <- Missing],
            {ok, #{
                fetched => length([ok || {_, ok} <- Results]),
                failed => [H || {H, R} <- Results, R =/= ok]
            }};
        _ ->
            case check(Db) of
                {ok, #{missing := []}} -> {ok, #{fetched => 0, failed => []}};
                _ -> {error, no_fetcher}
            end
    end.

fetch_one(Fetcher, Db, Hex) ->
    case Fetcher(Db, Hex) of
        {ok, Bytes} when is_binary(Bytes) -> install(Db, Hex, Bytes);
        {error, _} = Err -> Err;
        Other -> {error, {bad_fetcher_result, Other}}
    end.

bytes_present(Db, Hex) ->
    mailio_blob_files:exists(mailio_config:blob_root(), Db, Hex) orelse
        has_bytes_attachment(Db, Hex).

%% @doc Is there an attachment holding the bytes (the `docdb' backend)?
-spec has_bytes_attachment(binary(), binary()) -> boolean().
has_bytes_attachment(Db, Hex) ->
    case mailio_db:get_attachment(Db, <<?ID_BLOB, Hex/binary>>, <<"data">>) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%%====================================================================
%% Migration
%%====================================================================

%% @doc Move the bytes of blobs stored as attachments into files. For each
%% blob: the attachment must hash to its name, the file is written and read
%% back, the document is marked `files', and only then is the attachment
%% removed. A crash at any point leaves the bytes readable, and running it
%% again finishes the job. A blob whose attachment does not match its hash is
%% left alone and reported. `dry_run' only counts. Independent of
%% `blob_backend': it always writes files.
-spec migrate_to_files(binary(), map()) ->
    {ok, #{moved := non_neg_integer(), skipped := non_neg_integer(), failed := [binary()]}}.
migrate_to_files(Db, Opts) ->
    DryRun = maps:get(dry_run, Opts, false),
    {ok, Docs} = mailio_db:by_id_prefix(Db, <<?ID_BLOB>>),
    Results = [{hex_of(Id), migrate_one(Db, Doc, DryRun)} || #{<<"id">> := Id} = Doc <- Docs],
    {ok, #{
        moved => length([ok || {_, moved} <- Results]),
        skipped => length([ok || {_, skipped} <- Results]),
        failed => [H || {H, failed} <- Results]
    }}.

migrate_one(Db, #{<<"id">> := Id} = Doc, DryRun) ->
    Hex = hex_of(Id),
    case mailio_db:get_attachment(Db, Id, <<"data">>) of
        {error, _} ->
            %% already a file, or no bytes here yet: nothing to move
            skipped;
        {ok, Bytes} ->
            case mailio_id:blob_hex(Bytes) of
                Hex when DryRun -> moved;
                Hex -> move_bytes(Db, Doc, Hex, Bytes);
                _ -> failed
            end
    end.

move_bytes(Db, #{<<"id">> := Id}, Hex, Bytes) ->
    Root = mailio_config:blob_root(),
    case mailio_blob_files:put(Root, Db, Hex, Bytes) of
        ok ->
            case mailio_blob_files:verify(Root, Db, Hex) of
                ok ->
                    %% listed documents carry no revision: read it fresh to update
                    case mark_files(Db, Id) of
                        ok ->
                            case mailio_db:delete_attachment(Db, Id, <<"data">>) of
                                ok -> moved;
                                {error, _} -> failed
                            end;
                        {error, _} ->
                            failed
                    end;
                {error, _} ->
                    failed
            end;
        {error, _} ->
            failed
    end.

mark_files(Db, Id) ->
    case mailio_db:get(Db, Id) of
        {ok, Doc} ->
            case mailio_db:put(Db, Doc#{<<"store">> => <<"files">>}) of
                {ok, _, _} -> ok;
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.
