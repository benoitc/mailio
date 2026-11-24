-module(mailio_blob_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio_store.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    files_roundtrip/1,
    references_and_grace/1,
    mixed_backends_read_both_ways/1,
    replicated_document_gets_its_bytes/1,
    failed_write_leaves_no_document/1,
    ingest_stores_a_file/1,
    check_finds_missing_corrupt_and_orphans/1,
    repair_pulls_missing_and_cleans_up/1,
    install_refuses_wrong_bytes/1,
    fetcher_cannot_supply_wrong_bytes/1,
    repair_without_a_fetcher_reports_what_is_missing/1,
    migration_moves_attachments_to_files/1,
    migration_through_the_writer/1
]).

all() ->
    [
        files_roundtrip,
        references_and_grace,
        mixed_backends_read_both_ways,
        replicated_document_gets_its_bytes,
        failed_write_leaves_no_document,
        ingest_stores_a_file,
        check_finds_missing_corrupt_and_orphans,
        repair_pulls_missing_and_cleans_up,
        install_refuses_wrong_bytes,
        fetcher_cannot_supply_wrong_bytes,
        repair_without_a_fetcher_reports_what_is_missing,
        migration_moves_attachments_to_files,
        migration_through_the_writer
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    Priv = ?config(priv_dir, Config),
    application:set_env(barrel_docdb, data_dir, Priv),
    application:set_env(mailio_store, data_dir, Priv),
    {ok, _} = application:ensure_all_started(mailio_store),
    Config.

end_per_suite(_Config) ->
    application:stop(mailio_store),
    application:stop(barrel_docdb),
    ok.

init_per_testcase(_TC, Config) ->
    Account = list_to_binary("BLB" ++ integer_to_list(erlang:unique_integer([positive]))),
    Db = mailio_account:db_name(Account),
    {ok, _} = mailio_db:ensure_db(Db),
    Root = filename:join(?config(priv_dir, Config), "blobs_" ++ binary_to_list(Account)),
    application:set_env(mailio_store, blob_root, Root),
    application:set_env(mailio_store, blob_backend, files),
    [{account, Account}, {db, Db}, {root, Root} | Config].

end_per_testcase(_TC, Config) ->
    application:unset_env(mailio_store, blob_backend),
    application:unset_env(mailio_store, blob_fetcher),
    application:unset_env(mailio_store, blob_root),
    try
        mailio_accounts_sup:stop_account(?config(account, Config))
    catch
        _:_ -> ok
    end,
    try
        mailio_db:delete_db(?config(db, Config))
    catch
        _:_ -> ok
    end,
    ok.

raw(N) ->
    iolist_to_binary([
        "From: a@b.test\r\nSubject: m",
        integer_to_list(N),
        "\r\n\r\nbody ",
        integer_to_list(N),
        "\r\n"
    ]).

%%====================================================================

files_roundtrip(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    Content = raw(1),
    Hex = mailio_id:blob_hex(Content),
    {ok, BlobId} = mailio_blob:put(Db, Content, <<"ref1">>),
    ?assertEqual(<<"sha256-", Hex/binary>>, BlobId),
    ?assertEqual({ok, Content}, mailio_blob:get(Db, BlobId)),
    %% the bytes are a file named after the hash, not an attachment
    ?assert(mailio_blob_files:exists(Root, Db, Hex)),
    ?assertMatch({error, _}, mailio_db:get_attachment(Db, <<?ID_BLOB, Hex/binary>>, <<"data">>)),
    {ok, Doc} = mailio_db:get(Db, <<?ID_BLOB, Hex/binary>>),
    ?assertEqual(<<"files">>, maps:get(<<"store">>, Doc)),
    ?assertEqual(byte_size(Content), maps:get(<<"size">>, Doc)),
    ?assert(mailio_blob:has_bytes(Db, BlobId)).

references_and_grace(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    Content = raw(2),
    Hex = mailio_id:blob_hex(Content),
    {ok, BlobId} = mailio_blob:put(Db, Content, <<"ref1">>),
    {ok, BlobId} = mailio_blob:put(Db, Content, <<"ref2">>),
    ?assertEqual(2, mailio_blob:ref_count(Db, BlobId)),
    ?assertEqual([Hex], mailio_blob_files:list(Root, Db)),
    {ok, referenced} = mailio_blob:remove_ref(Db, BlobId, <<"ref1">>),
    {ok, orphaned} = mailio_blob:remove_ref(Db, BlobId, <<"ref2">>),
    %% inside the grace window the file stays
    ?assertEqual({ok, 0}, mailio_blob:sweep(Db, erlang:system_time(second), 3600)),
    ?assert(mailio_blob_files:exists(Root, Db, Hex)),
    %% a re-reference revives it
    {ok, BlobId} = mailio_blob:put(Db, Content, <<"ref3">>),
    ?assertEqual({ok, 0}, mailio_blob:sweep(Db, erlang:system_time(second) + 10, 0)),
    {ok, orphaned} = mailio_blob:remove_ref(Db, BlobId, <<"ref3">>),
    %% past the grace window both the document and the file go
    ?assertEqual({ok, 1}, mailio_blob:sweep(Db, erlang:system_time(second) + 10, 0)),
    ?assertNot(mailio_blob_files:exists(Root, Db, Hex)),
    ?assertNot(mailio_blob:exists(Db, BlobId)),
    ?assertEqual({error, not_found}, mailio_blob:get(Db, BlobId)).

mixed_backends_read_both_ways(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    Old = raw(3),
    New = raw(4),
    %% written before the switch, as an attachment
    application:set_env(mailio_store, blob_backend, docdb),
    {ok, OldId} = mailio_blob:put(Db, Old, <<"old">>),
    ?assertEqual({ok, Old}, mailio_blob:get(Db, OldId)),
    ?assertEqual([], mailio_blob_files:list(Root, Db)),
    %% after the switch, new blobs are files and the old one is still readable
    application:set_env(mailio_store, blob_backend, files),
    {ok, NewId} = mailio_blob:put(Db, New, <<"new">>),
    ?assertEqual({ok, Old}, mailio_blob:get(Db, OldId)),
    ?assertEqual({ok, New}, mailio_blob:get(Db, NewId)),
    ?assertEqual([mailio_id:blob_hex(New)], mailio_blob_files:list(Root, Db)),
    %% and the other way round: switching back keeps the file readable
    application:set_env(mailio_store, blob_backend, docdb),
    ?assertEqual({ok, New}, mailio_blob:get(Db, NewId)),
    ?assertEqual({ok, Old}, mailio_blob:get(Db, OldId)).

%% A blob document can arrive by replication before its bytes do.
replicated_document_gets_its_bytes(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    Content = raw(5),
    Hex = mailio_id:blob_hex(Content),
    BlobId = <<"sha256-", Hex/binary>>,
    {ok, _, _} = mailio_db:put(Db, #{
        <<"id">> => <<?ID_BLOB, Hex/binary>>,
        <<"blobId">> => BlobId,
        <<"size">> => byte_size(Content),
        <<"store">> => <<"files">>,
        <<"refs">> => #{<<"remote">> => true}
    }),
    ?assert(mailio_blob:exists(Db, BlobId)),
    ?assertNot(mailio_blob:has_bytes(Db, BlobId)),
    ?assertEqual({error, not_found}, mailio_blob:get(Db, BlobId)),
    %% the next local write of the same content fills it in and adds the reference
    {ok, BlobId} = mailio_blob:put(Db, Content, <<"local">>),
    ?assert(mailio_blob:has_bytes(Db, BlobId)),
    ?assert(mailio_blob_files:exists(Root, Db, Hex)),
    ?assertEqual(2, mailio_blob:ref_count(Db, BlobId)).

%% If the file cannot be written there is no blob document either.
failed_write_leaves_no_document(Config) ->
    Db = ?config(db, Config),
    Priv = ?config(priv_dir, Config),
    Blocker = filename:join(Priv, "not_a_directory"),
    ok = file:write_file(Blocker, <<"a file where a directory should be">>),
    application:set_env(mailio_store, blob_root, filename:join(Blocker, "blobs")),
    Content = raw(6),
    ?assertMatch({error, _}, mailio_blob:put(Db, Content, <<"ref">>)),
    ?assertNot(mailio_blob:exists(Db, mailio_id:blob_id(Content))).

ingest_stores_a_file(Config) ->
    Account = ?config(account, Config),
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    Raw = raw(7),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, Raw),
    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    BlobId = maps:get(<<"blobId">>, Email),
    ?assertEqual({ok, Raw}, mailio_blob:get(Db, BlobId)),
    ?assert(mailio_blob_files:exists(Root, Db, mailio_blob:hex_of(BlobId))),
    %% ingesting it again stores nothing new
    {ok, _} = mailio_account:ingest_raw(Account, <<"inbox">>, Raw),
    ?assertEqual(1, length(mailio_blob_files:list(Root, Db))).

%%====================================================================
%% Consistency and replication

%% Three blobs, then: one loses its file, one is damaged, one file has no document.
damaged_store(Db, Root) ->
    [A, B, C] = [raw(N) || N <- [20, 21, 22]],
    [{ok, _} = mailio_blob:put(Db, X, <<"ref">>) || X <- [A, B, C]],
    [HA, HB, HC] = [mailio_id:blob_hex(X) || X <- [A, B, C]],
    ok = mailio_blob_files:delete(Root, Db, HA),
    {ok, PB} = mailio_blob_files:path(Root, Db, HB),
    ok = file:write_file(PB, <<"damaged on disk">>),
    Stray = <<"a file nothing refers to">>,
    HS = mailio_id:blob_hex(Stray),
    ok = mailio_blob_files:put(Root, Db, HS, Stray),
    {#{HA => A, HB => B, HC => C}, [HA, HB, HC], HS}.

check_finds_missing_corrupt_and_orphans(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    {_, [HA, HB, HC], HS} = damaged_store(Db, Root),
    {ok, R} = mailio_blob:check(Db),
    ?assertEqual(lists:sort([HA, HB]), maps:get(missing, R)),
    ?assertEqual([HB], maps:get(corrupt, R)),
    ?assertEqual([HS], maps:get(orphan_files, R)),
    ?assertNot(lists:member(HC, maps:get(missing, R))).

repair_pulls_missing_and_cleans_up(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    {Originals, [HA, HB, HC], HS} = damaged_store(Db, Root),
    Fetches = ets:new(fetches, [public, bag]),
    application:set_env(
        mailio_store,
        blob_fetcher,
        fun(D, Hex) ->
            ets:insert(Fetches, {D, Hex}),
            case maps:find(Hex, Originals) of
                {ok, Bytes} -> {ok, Bytes};
                error -> {error, not_on_peer}
            end
        end
    ),
    %% a young orphan is kept: it may be a write in progress
    {ok, R1} = mailio_blob:repair(Db, #{}),
    ?assertEqual(1, maps:get(quarantined, R1)),
    ?assertEqual(0, maps:get(orphans_removed, R1)),
    ?assertEqual(2, maps:get(pulled, R1)),
    ?assertEqual([], maps:get(failed, R1)),
    ?assert(mailio_blob_files:exists(Root, Db, HS)),
    %% only what was missing was asked for, and the healthy blob was left alone
    ?assertEqual(lists:sort([HA, HB]), lists:sort([H || {_, H} <- ets:tab2list(Fetches)])),
    ?assertEqual({ok, maps:get(HB, Originals)}, mailio_blob:get(Db, HB)),
    ?assertEqual({ok, maps:get(HA, Originals)}, mailio_blob:get(Db, HA)),
    ?assertEqual({ok, maps:get(HC, Originals)}, mailio_blob:get(Db, HC)),
    %% the damaged file was kept for inspection
    ?assert(
        filelib:is_regular(filename:join([Root, binary_to_list(Db), "corrupt", binary_to_list(HB)]))
    ),
    %% with no grace the orphan goes, and now everything is consistent
    {ok, R2} = mailio_blob:repair(Db, #{orphan_grace => 0}),
    ?assertEqual(1, maps:get(orphans_removed, R2)),
    ?assertNot(mailio_blob_files:exists(Root, Db, HS)),
    {ok, #{missing := [], corrupt := [], orphan_files := []}} = mailio_blob:check(Db).

install_refuses_wrong_bytes(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    Content = raw(30),
    Hex = mailio_id:blob_hex(Content),
    {ok, _, _} = mailio_db:put(Db, #{
        <<"id">> => <<?ID_BLOB, Hex/binary>>,
        <<"size">> => 1,
        <<"store">> => <<"files">>,
        <<"refs">> => #{<<"r">> => true}
    }),
    ?assertEqual({error, hash_mismatch}, mailio_blob:install(Db, Hex, <<"not what was promised">>)),
    ?assertNot(mailio_blob_files:exists(Root, Db, Hex)),
    ?assertEqual(ok, mailio_blob:install(Db, <<"sha256-", Hex/binary>>, Content)),
    ?assertEqual({ok, Content}, mailio_blob:get(Db, Hex)).

%% A peer that answers with the wrong bytes does not poison the store.
fetcher_cannot_supply_wrong_bytes(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    Content = raw(31),
    Hex = mailio_id:blob_hex(Content),
    {ok, _, _} = mailio_db:put(Db, #{
        <<"id">> => <<?ID_BLOB, Hex/binary>>,
        <<"size">> => 1,
        <<"store">> => <<"files">>,
        <<"refs">> => #{<<"r">> => true}
    }),
    application:set_env(mailio_store, blob_fetcher, fun(_, _) ->
        {ok, <<"someone else's bytes">>}
    end),
    ?assertEqual({ok, #{fetched => 0, failed => [Hex]}}, mailio_blob:pull_missing(Db)),
    ?assertNot(mailio_blob_files:exists(Root, Db, Hex)),
    ?assertEqual([], mailio_blob_files:list(Root, Db)).

repair_without_a_fetcher_reports_what_is_missing(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    {_, [HA, _, _], _} = damaged_store(Db, Root),
    ?assertEqual({error, no_fetcher}, mailio_blob:pull_missing(Db)),
    {ok, R} = mailio_blob:repair(Db, #{}),
    ?assertEqual(0, maps:get(pulled, R)),
    ?assert(lists:member(HA, maps:get(failed, R))).

%%====================================================================
%% Migration

migration_moves_attachments_to_files(Config) ->
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    application:set_env(mailio_store, blob_backend, docdb),
    Contents = [raw(N) || N <- [40, 41, 42]],
    Ids = [
        begin
            {ok, I} = mailio_blob:put(Db, C, <<"r">>),
            I
        end
     || C <- Contents
    ],
    %% one attachment is damaged: it must not be copied as if it were good
    [_, BadId, _] = Ids,
    BadHex = mailio_blob:hex_of(BadId),
    {ok, _} = mailio_db:put_attachment(Db, <<?ID_BLOB, BadHex/binary>>, <<"data">>, <<"damaged">>),
    application:set_env(mailio_store, blob_backend, files),
    %% a dry run changes nothing
    ?assertEqual(
        {ok, #{moved => 2, skipped => 0, failed => [BadHex]}},
        mailio_blob:migrate_to_files(Db, #{dry_run => true})
    ),
    ?assertEqual([], mailio_blob_files:list(Root, Db)),
    ?assertEqual(
        {ok, #{moved => 2, skipped => 0, failed => [BadHex]}},
        mailio_blob:migrate_to_files(Db, #{})
    ),
    Good = [mailio_blob:hex_of(I) || I <- Ids, I =/= BadId],
    ?assertEqual(lists:sort(Good), mailio_blob_files:list(Root, Db)),
    %% the moved blobs read from files, and their attachments are gone
    [
        begin
            ?assertMatch(
                {error, _}, mailio_db:get_attachment(Db, <<?ID_BLOB, H/binary>>, <<"data">>)
            ),
            {ok, D} = mailio_db:get(Db, <<?ID_BLOB, H/binary>>),
            ?assertEqual(<<"files">>, maps:get(<<"store">>, D)),
            ?assertMatch({ok, _}, mailio_blob:get(Db, H))
        end
     || H <- Good
    ],
    %% the damaged one is untouched
    ?assertEqual(
        {ok, <<"damaged">>}, mailio_db:get_attachment(Db, <<?ID_BLOB, BadHex/binary>>, <<"data">>)
    ),
    %% running it again moves nothing more
    ?assertEqual(
        {ok, #{moved => 0, skipped => 2, failed => [BadHex]}}, mailio_blob:migrate_to_files(Db, #{})
    ).

migration_through_the_writer(Config) ->
    Account = ?config(account, Config),
    Db = ?config(db, Config),
    Root = ?config(root, Config),
    application:set_env(mailio_store, blob_backend, docdb),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    Raw = raw(50),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, Raw),
    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    BlobId = maps:get(<<"blobId">>, Email),
    ?assertEqual([], mailio_blob_files:list(Root, Db)),
    application:set_env(mailio_store, blob_backend, files),
    ?assertEqual(
        {ok, #{moved => 1, skipped => 0, failed => []}},
        mailio_account_writer:migrate_blobs(Account, #{})
    ),
    ?assertEqual({ok, Raw}, mailio_blob:get(Db, BlobId)),
    ?assert(mailio_blob_files:exists(Root, Db, mailio_blob:hex_of(BlobId))),
    {ok, #{missing := [], corrupt := [], orphan_files := []}} = mailio_blob:check(Db).
