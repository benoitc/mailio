%%% @doc Content-addressed blob storage over barrel attachments.
%%%
%%% A blob is stored as a document `blob/<sha256hex>' with metadata, plus a
%%% single `data' attachment holding the bytes. Because the id is the
%%% content hash, identical content (a raw message stored twice, a shared
%%% signature image) is naturally deduplicated; a `refs' map tracks which
%%% documents point at the blob so it can be garbage collected when the
%%% last reference is dropped.
%%%
%%% All functions take a database name and run in the caller (the account
%%% writer), which serializes access.
-module(mailio_blob).

-include("mailio.hrl").

-export([blob_id/1, doc_id/1]).
-export([put/3, get/2, exists/2, add_ref/3, remove_ref/3, ref_count/2]).

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
    case mailio_db:get(Db, DocId) of
        {ok, Existing} ->
            %% Already stored: just record the new reference.
            Updated = add_ref_to_doc(Existing, RefId),
            case mailio_db:put(Db, Updated) of
                {ok, _, _} -> {ok, BlobId};
                {error, _} = Err -> Err
            end;
        {error, not_found} ->
            Doc = #{<<"id">> => DocId,
                    <<"blobId">> => BlobId,
                    <<"size">> => byte_size(Content),
                    <<"refs">> => #{RefId => true}},
            case mailio_db:put(Db, Doc) of
                {ok, _, _} ->
                    case mailio_db:put_attachment(Db, DocId, <<"data">>, Content) of
                        {ok, _} -> {ok, BlobId};
                        {error, _} = Err -> Err
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

%% @doc Fetch blob bytes by public blob id or hex.
-spec get(binary(), binary()) -> {ok, binary()} | {error, not_found}.
get(Db, BlobIdOrHex) ->
    DocId = doc_id(BlobIdOrHex),
    case mailio_db:get_attachment(Db, DocId, <<"data">>) of
        {ok, Data} -> {ok, Data};
        {error, _} -> {error, not_found}
    end.

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

%% @doc Drop a reference. Returns `{ok, orphaned}' when the last reference
%% is gone (the blob is then eligible for GC), `{ok, referenced}' otherwise.
-spec remove_ref(binary(), binary(), binary()) ->
    {ok, orphaned | referenced} | {error, term()}.
remove_ref(Db, BlobIdOrHex, RefId) ->
    DocId = doc_id(BlobIdOrHex),
    case mailio_db:get(Db, DocId) of
        {ok, Doc} ->
            Refs = maps:remove(RefId, maps:get(<<"refs">>, Doc, #{})),
            Doc1 = Doc#{<<"refs">> => Refs},
            case mailio_db:put(Db, Doc1) of
                {ok, _, _} ->
                    case maps:size(Refs) of
                        0 -> {ok, orphaned};
                        _ -> {ok, referenced}
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
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
    Doc#{<<"refs">> => Refs#{RefId => true}}.
