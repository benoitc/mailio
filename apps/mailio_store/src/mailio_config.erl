%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Application configuration access.
-module(mailio_config).

-export([data_dir/0, system_db/0, blob_backend/0, blob_root/0, get/1, get/2]).

-spec data_dir() -> string().
data_dir() ->
    get(data_dir, "data/mailio").

%% @doc Where new raw messages are written: `docdb' (an attachment on the blob
%% document, the default) or `files' (content-addressed files, see
%% mailio_blob_files). Blobs written by the other backend stay readable.
-spec blob_backend() -> docdb | files.
blob_backend() ->
    case get(blob_backend, docdb) of
        files -> files;
        _ -> docdb
    end.

%% @doc Root directory of the blob files.
-spec blob_root() -> file:filename().
blob_root() ->
    get(blob_root, filename:join(data_dir(), "blobs")).

-spec system_db() -> binary().
system_db() ->
    get(system_db, <<"mailio_system">>).

-spec get(atom()) -> term() | undefined.
get(Key) ->
    get(Key, undefined).

-spec get(atom(), term()) -> term().
get(Key, Default) ->
    application:get_env(mailio_store, Key, Default).
