%%% @doc M6 durability and consistency suite.
%%%
%%% Exercises the recovery and repair machinery: persistence across a store
%%% close/reopen, idempotent re-ingest after a simulated partial write, blob
%%% garbage collection with a grace window, fsck counter recompute/repair,
%%% and the non-QRESYNC reconcile that detects expunges by diffing the
%%% server's uid list against locally known uids.
-module(mailio_durability_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([persists_across_reopen/1,
         destroy_then_reingest_reindexes/1,
         blob_gc_respects_grace/1,
         fsck_detects_and_repairs_drift/1,
         reconcile_removes_expunged/1]).

all() ->
    [persists_across_reopen,
     destroy_then_reingest_reindexes,
     blob_gc_respects_grace,
     fsck_detects_and_repairs_drift,
     reconcile_removes_expunged].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    Priv = ?config(priv_dir, Config),
    application:set_env(barrel_docdb, data_dir, Priv),
    application:set_env(mailio, data_dir, Priv),
    {ok, _} = application:ensure_all_started(mailio),
    Config.

end_per_suite(_Config) ->
    application:stop(mailio),
    application:stop(barrel_docdb),
    ok.

init_per_testcase(_TC, Config) ->
    Account = list_to_binary("DUR" ++ integer_to_list(erlang:unique_integer([positive]))),
    Srv = mailio_fake_imap:start(),
    [{account, Account}, {srv, Srv} | Config].

end_per_testcase(_TC, Config) ->
    Account = ?config(account, Config),
    try mailio_accounts_sup:stop_account(Account) catch _:_ -> ok end,
    try mailio_db:delete_db(mailio_account:db_name(Account)) catch _:_ -> ok end,
    try mailio_fake_imap:stop(?config(srv, Config)) catch _:_ -> ok end,
    ok.

%%====================================================================

persists_across_reopen(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, sample()),

    %% Stop the account and close the database, then reopen.
    ok = mailio_accounts_sup:stop_account(Account),
    ok = mailio_db:close_db(Db),
    {ok, _} = mailio_db:ensure_db(Db),

    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    ?assertEqual(<<"Sample subject">>, maps:get(<<"subject">>, Email)),
    {ok, Raw} = mailio_blob:get(Db, maps:get(<<"blobId">>, Email)),
    ?assertEqual(sample(), Raw).

%% Destroy an email (which deletes its docs and removes index paths), then
%% re-ingest the same content. The content-addressed id collides with the
%% tombstone, so this exercises the barrel reindex-on-recreate fix: the
%% revived email must be findable again, not just gettable.
destroy_then_reingest_reindexes(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, sample()),
    ?assertEqual(1, find_by_subject_count(Db, <<"Sample subject">>)),

    %% Destroy removes the email's last mailbox membership.
    ok = mailio_account_writer:remove_member(Account, <<"inbox">>, EmailId),
    ?assertEqual({error, not_found}, mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>)),
    ?assertEqual(0, find_by_subject_count(Db, <<"Sample subject">>)),

    %% Re-ingest the same bytes: the email is revived AND re-indexed.
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, sample()),
    ?assertMatch({ok, _}, mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>)),
    ?assertEqual(1, find_by_subject_count(Db, <<"Sample subject">>)),

    %% Counters consistent after the round trip.
    {ok, Drifts} = mailio_fsck:check_counters(Account),
    ?assertEqual([], Drifts).

blob_gc_respects_grace(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, sample()),
    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    BlobId = maps:get(<<"blobId">>, Email),

    %% While referenced, GC never touches it.
    {ok, 0} = mailio_account_writer:gc_blobs(Account, 0),
    ?assert(mailio_blob:exists(Db, BlobId)),

    %% Destroy the email (drops the blob ref -> orphaned).
    ok = mailio_account_writer:remove_member(Account, <<"inbox">>, EmailId),
    ?assertEqual(0, mailio_blob:ref_count(Db, BlobId)),

    %% A long grace keeps the orphan; a zero grace sweeps it.
    {ok, 0} = mailio_account_writer:gc_blobs(Account, 3600),
    ?assert(mailio_blob:exists(Db, BlobId)),
    {ok, 1} = mailio_account_writer:gc_blobs(Account, 0),
    ?assertNot(mailio_blob:exists(Db, BlobId)).

fsck_detects_and_repairs_drift(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    {ok, _} = mailio_account:ingest_raw(Account, <<"inbox">>, sample()),

    %% Corrupt the counter behind the writer's back.
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, "inbox">>),
    {ok, _, _} = mailio_db:put(Db, Mbx#{<<"totalEmails">> => 99,
                                        <<"unreadEmails">> => 99}),

    {ok, [Drift]} = mailio_fsck:check_counters(Account),
    ?assertEqual({99, 1}, maps:get(total, Drift)),

    {ok, 1} = mailio_fsck:repair_counters(Account),
    {ok, []} = mailio_fsck:check_counters(Account),
    {ok, Fixed} = mailio_db:get(Db, <<?ID_MAILBOX, "inbox">>),
    ?assertEqual(1, maps:get(<<"totalEmails">>, Fixed)),
    ?assertEqual(1, maps:get(<<"unreadEmails">>, Fixed)).

reconcile_removes_expunged(Config) ->
    %% Backfill an IMAP-backed account, expunge on the server, then
    %% reconcile (uid-list diff) — the no-QRESYNC removal path.
    Srv = ?config(srv, Config),
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Imap = #{host => <<"127.0.0.1">>, port => mailio_fake_imap:port(Srv),
             tls => false, username => <<"u">>, password => <<"p">>},
    {ok, _} = mailio_accounts_sup:start_account(Account, #{imap => Imap}),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, count_emails(Db)),

    %% Server drops uid 101; reconcile must notice via UID SEARCH ALL.
    ok = mailio_fake_imap:expunge(Srv, 101),
    {ok, #{removed := 1}} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
    ?assertEqual(1, count_emails(Db)).

%%====================================================================
%% Helpers
%%====================================================================

find_by_subject_count(Db, Subject) ->
    {ok, Docs, _} = mailio_db:find(
        Db, #{where => [{path, [<<"subject">>], Subject}]},
        #{include_docs => true}),
    length(Docs).

count_emails(Db) ->
    {ok, Emails, _} = mailio_db:find(
        Db, #{where => [{path, [?MAILIO_NS, <<"parse_version">>], 1}]},
        #{include_docs => true}),
    length(Emails).

sample() ->
    <<"From: alice@example.com\r\n",
      "To: bob@example.com\r\n",
      "Subject: Sample subject\r\n",
      "Message-ID: <sample@example.com>\r\n",
      "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "\r\n",
      "Sample body.\r\n">>.
