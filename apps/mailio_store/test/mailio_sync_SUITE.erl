%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc M5 sync-engine vertical slice (against the scripted fake server).
%%%
%%% Proves the full chain: a configured IMAP account discovers mailboxes,
%%% backfills INBOX into the store (emitting events), persists a cursor, and
%%% reflects a later server-side flag change as an `email.updated' event —
%%% the milestone's "mark-as-read on the phone shows up locally" slice.
-module(mailio_sync_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio_store.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    backfill_ingests_messages/1,
    backfill_emits_events/1,
    cursor_persists_no_redundant_fetch/1,
    flag_change_updates_email/1,
    qresync_expunge_removes_email/1,
    idle_push_triggers_sync/1,
    oversized_vanished_resynchronizes/1,
    failed_resync_keeps_the_cursor/1,
    validity_change_replaces_the_mailbox/1,
    failed_listing_keeps_mail_and_cursor/1,
    failed_body_fetch_keeps_the_cursor/1,
    recreated_mailbox_during_resync_replaces_reused_uids/1,
    removing_one_duplicate_keeps_the_other_uid/1,
    removing_one_duplicate_in_a_resync_keeps_the_other_uid/1,
    shared_mail_leaves_a_mailbox_with_its_last_uid/1,
    a_reset_on_a_later_page_discards_the_earlier_pages/1,
    a_reset_is_kept_when_the_adapter_names_no_uidvalidity/1,
    a_retry_after_a_failed_fetch_stores_both_messages/1,
    a_retry_after_the_mailbox_was_recreated_replaces_the_first_message/1,
    a_retry_after_an_expunge_removes_the_first_message/1,
    a_retry_after_flags_were_cleared_updates_the_first_message/1,
    a_full_read_beyond_the_listing_limit_stops/1,
    a_full_resync_removes_more_than_one_chunk_of_mappings/1,
    reconcile_removes_more_than_one_chunk_of_mappings/1,
    a_reset_is_remembered_across_a_failed_retry_and_a_restart/1,
    a_streamed_read_applies_flag_updates_in_order/1,
    reconcile_keeps_local_mail_for_a_modseq_suffix_alone/1,
    reconcile_keeps_local_mail_for_a_uidnext_with_a_leading_zero/1,
    reconcile_keeps_local_mail_for_an_invalid_highest_uid/1,
    reconcile_keeps_local_mail_for_a_bad_modseq_suffix/1,
    a_first_read_without_a_valid_uidvalidity_gives_no_cursor/1,
    integer_and_text_ids_do_not_collide/1,
    an_older_text_id_mapping_is_still_found/1,
    a_half_moved_mapping_is_finished_by_a_retry/1,
    reconcile_keeps_local_mail_for_an_empty_answer_about_a_mailbox_with_mail/1,
    a_removal_on_a_later_page_of_a_full_read_is_applied/1,
    a_streamed_message_is_stored_whole/1,
    a_message_that_arrives_short_is_not_stored/1,
    an_interrupted_removal_is_finished_and_counted_once/1,
    a_connection_that_gave_up_is_replaced/1,
    a_shared_read_email_is_not_unread_in_the_second_mailbox/1,
    a_mapping_of_the_intermediate_build_is_still_found/1,
    a_full_read_that_misses_messages_removes_nothing/1,
    an_idle_sync_that_finds_a_dead_connection_keeps_the_watch/1,
    a_sink_answers_ok_past_the_size_limit/1,
    a_removal_that_failed_between_the_email_and_the_counter_is_repaired/1,

    opaque_ids_are_synced_and_reconciled/1,
    an_unreliable_listing_does_not_remove_local_mail/1,
    a_repeated_cursor_ends_the_sync/1,
    an_endless_listing_is_bounded/1,
    an_adapter_that_cannot_check_uidvalidity_keeps_the_cursor/1
]).

all() ->
    [
        backfill_ingests_messages,
        backfill_emits_events,
        cursor_persists_no_redundant_fetch,
        flag_change_updates_email,
        qresync_expunge_removes_email,
        idle_push_triggers_sync,
        oversized_vanished_resynchronizes,
        failed_resync_keeps_the_cursor,
        validity_change_replaces_the_mailbox,
        failed_listing_keeps_mail_and_cursor,
        failed_body_fetch_keeps_the_cursor,
        recreated_mailbox_during_resync_replaces_reused_uids,
        removing_one_duplicate_keeps_the_other_uid,
        removing_one_duplicate_in_a_resync_keeps_the_other_uid,
        shared_mail_leaves_a_mailbox_with_its_last_uid,
        a_reset_on_a_later_page_discards_the_earlier_pages,
        a_reset_is_kept_when_the_adapter_names_no_uidvalidity,
        a_retry_after_a_failed_fetch_stores_both_messages,
        a_retry_after_the_mailbox_was_recreated_replaces_the_first_message,
        a_retry_after_an_expunge_removes_the_first_message,
        a_retry_after_flags_were_cleared_updates_the_first_message,
        a_full_read_beyond_the_listing_limit_stops,
        a_full_resync_removes_more_than_one_chunk_of_mappings,
        reconcile_removes_more_than_one_chunk_of_mappings,
        a_reset_is_remembered_across_a_failed_retry_and_a_restart,
        a_streamed_read_applies_flag_updates_in_order,
        reconcile_keeps_local_mail_for_a_modseq_suffix_alone,
        reconcile_keeps_local_mail_for_a_uidnext_with_a_leading_zero,
        reconcile_keeps_local_mail_for_an_invalid_highest_uid,
        reconcile_keeps_local_mail_for_a_bad_modseq_suffix,
        a_first_read_without_a_valid_uidvalidity_gives_no_cursor,
        integer_and_text_ids_do_not_collide,
        an_older_text_id_mapping_is_still_found,
        a_half_moved_mapping_is_finished_by_a_retry,
        reconcile_keeps_local_mail_for_an_empty_answer_about_a_mailbox_with_mail,
        a_removal_on_a_later_page_of_a_full_read_is_applied,
        a_streamed_message_is_stored_whole,
        a_message_that_arrives_short_is_not_stored,
        an_interrupted_removal_is_finished_and_counted_once,
        a_connection_that_gave_up_is_replaced,
        a_shared_read_email_is_not_unread_in_the_second_mailbox,
        a_mapping_of_the_intermediate_build_is_still_found,
        a_full_read_that_misses_messages_removes_nothing,
        an_idle_sync_that_finds_a_dead_connection_keeps_the_watch,
        a_sink_answers_ok_past_the_size_limit,
        a_removal_that_failed_between_the_email_and_the_counter_is_repaired,

        opaque_ids_are_synced_and_reconciled,
        an_unreliable_listing_does_not_remove_local_mail,
        a_repeated_cursor_ends_the_sync,
        an_endless_listing_is_bounded,
        an_adapter_that_cannot_check_uidvalidity_keeps_the_cursor
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
    Srv = mailio_fake_imap:start(),
    Account = list_to_binary("SYNC" ++ integer_to_list(erlang:unique_integer([positive]))),
    Imap = #{
        host => <<"127.0.0.1">>,
        port => mailio_fake_imap:port(Srv),
        tls => false,
        username => <<"u">>,
        password => <<"p">>
    },
    {ok, _} = mailio_accounts_sup:start_account(Account, #{imap => Imap}),
    [{srv, Srv}, {account, Account} | Config].

end_per_testcase(_TC, Config) ->
    Account = ?config(account, Config),
    try
        mailio_accounts_sup:stop_account(Account)
    catch
        _:_ -> ok
    end,
    try
        mailio_db:delete_db(mailio_account:db_name(Account))
    catch
        _:_ -> ok
    end,
    try
        mailio_fake_imap:stop(?config(srv, Config))
    catch
        _:_ -> ok
    end,
    ok.

%%====================================================================

backfill_ingests_messages(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, _Stats} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),

    Emails = all_emails(Db),
    ?assertEqual(2, length(Emails)),
    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- Emails]),
    ?assertEqual([<<"First message">>, <<"Second message">>], Subjects),

    %% INBOX counters: 2 total, 1 unread (message 100 is \Seen).
    {ok, LocalId} = inbox_local_id(Account),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(2, maps:get(<<"totalEmails">>, Mbx)),
    ?assertEqual(1, maps:get(<<"unreadEmails">>, Mbx)),
    ?assertEqual(<<"inbox">>, maps:get(<<"role">>, Mbx)).

backfill_emits_events(Config) ->
    Account = ?config(account, Config),
    {ok, _Ref} = mailio_events:subscribe(#{account => Account, types => [email]}),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    Events = drain(500),
    Created = [
        E
     || E <- Events,
        maps:get(type, E) =:= email,
        maps:get(verb, E) =:= created
    ],
    ?assertEqual(2, length(Created)).

cursor_persists_no_redundant_fetch(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, S1} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, added(S1)),

    %% A cursor doc now exists for INBOX.
    {ok, LocalId} = inbox_local_id(Account),
    ?assertMatch({ok, _}, mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>)),

    %% Second pass: nothing new (UIDNEXT advanced, no flag changes).
    {ok, S2} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, added(S2)),
    ?assertEqual(2, length(all_emails(Db))).

flag_change_updates_email(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),

    %% Second message starts unseen.
    E0 = email_by_subject(Db, <<"Second message">>),
    ?assertNot(mailio_email:is_seen(E0)),

    %% Server marks it \Seen; resync should reflect it and emit an update.
    ok = mailio_fake_imap:set_flags(Srv, 101, [<<"\\Seen">>]),
    {ok, _Ref} = mailio_events:subscribe(#{account => Account, types => [email]}),
    {ok, Stats} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(1, maps:get(updated, Stats)),

    E1 = email_by_subject(Db, <<"Second message">>),
    ?assert(mailio_email:is_seen(E1)),

    Events = drain(500),
    ?assert(
        lists:any(
            fun(E) ->
                maps:get(type, E) =:= email andalso
                    maps:get(verb, E) =:= updated
            end,
            Events
        )
    ),

    %% Unread counter dropped to 0.
    {ok, LocalId} = inbox_local_id(Account),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(0, maps:get(<<"unreadEmails">>, Mbx)).

%% A server-side expunge is reported via QRESYNC VANISHED on the next sync
%% and removes the email locally.
qresync_expunge_removes_email(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    E = email_by_subject(Db, <<"Second message">>),
    EmailId = mailio_email:id_of(E),

    ok = mailio_fake_imap:expunge(Srv, 101),
    {ok, Stats} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(1, maps:get(removed, Stats)),

    %% The email is gone and its mailbox counter dropped.
    ?assertEqual(1, length(all_emails(Db))),
    ?assertEqual({error, not_found}, mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>)),
    {ok, LocalId} = inbox_local_id(Account),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(1, maps:get(<<"totalEmails">>, Mbx)).

%% A new message pushed by the server while IDLE wakes the sync engine and
%% the message is ingested without an explicit sync call.
idle_push_triggers_sync(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),

    ok = mailio_sync_mgr:watch_inbox(Account),
    ok = mailio_fake_imap:deliver(Srv, <<"Pushed message">>),

    %% Wait for the IDLE-driven resync to ingest the new message.
    ok = wait_until(fun() -> length(all_emails(Db)) =:= 3 end, 5000),
    Subjects = [maps:get(<<"subject">>, E) || E <- all_emails(Db)],
    ?assert(lists:member(<<"Pushed message">>, Subjects)).

%% A VANISHED report longer than the adapter will list. The adapter asks for a
%% resynchronisation; the store must bring its mailbox in line with the server
%% (removals, new mail, flags) before it keeps the new cursor.
oversized_vanished_resynchronizes(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{max_vanished => 1}),
    ok = mailio_fake_imap:deliver(Srv, <<"Third message">>),
    ok = mailio_fake_imap:deliver(Srv, <<"Fourth message">>),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(4, length(all_emails(Db))),
    {ok, LocalId} = inbox_local_id(Account),
    Before = cursor(Db, LocalId),

    %% two removals (more than the cap of one), a flag change, one new message
    ok = mailio_fake_imap:expunge(Srv, 100),
    ok = mailio_fake_imap:expunge(Srv, 101),
    ok = mailio_fake_imap:set_flags(Srv, 103, [<<"\\Seen">>]),
    ok = mailio_fake_imap:deliver(Srv, <<"Fifth message">>),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),

    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    ?assertEqual([<<"Fifth message">>, <<"Fourth message">>, <<"Third message">>], Subjects),
    ?assert(mailio_email:is_seen(email_by_subject(Db, <<"Fourth message">>))),
    ?assertNot(mailio_email:is_seen(email_by_subject(Db, <<"Third message">>))),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(3, maps:get(<<"totalEmails">>, Mbx)),
    After = cursor(Db, LocalId),
    ?assertNotEqual(Before, After),
    %% the new cursor is a good one: nothing is reported again
    {ok, S2} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, maps:get(added, S2)),
    ?assertEqual(0, maps:get(removed, S2)),
    ?assertEqual(0, maps:get(updated, S2)),
    ?assertEqual(3, length(all_emails(Db))).

%% If the full re-read cannot be done, the old cursor stays, so the next sync
%% tries again and nothing is skipped.
failed_resync_keeps_the_cursor(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{max_vanished => 1}, mailio_failing_adapter),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    {ok, LocalId} = inbox_local_id(Account),
    Before = cursor(Db, LocalId),
    ok = mailio_fake_imap:expunge(Srv, 100),
    ok = mailio_fake_imap:expunge(Srv, 101),
    application:set_env(mailio_store, fail_full_read, true),
    try
        ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)),
        ?assertEqual(Before, cursor(Db, LocalId)),
        ?assertEqual(2, length(all_emails(Db)))
    after
        application:set_env(mailio_store, fail_full_read, false)
    end,
    %% the next sync does the work the failed one could not
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, length(all_emails(Db))),
    ?assertNotEqual(Before, cursor(Db, LocalId)).

%% A new UIDVALIDITY makes every old UID meaningless: the mailbox is replaced by
%% what the server has now, and the cursor moves only after that.
validity_change_replaces_the_mailbox(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    ok = mailio_fake_imap:new_validity(Srv, [<<"Brand new one">>, <<"Brand new two">>]),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    ?assertEqual([<<"Brand new one">>, <<"Brand new two">>], Subjects),
    {ok, S2} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, maps:get(added, S2)).

%% The server answers the listing with NO, on the wire, after EXAMINE worked.
%% Nothing may be removed and the cursor must stay where it was.
failed_listing_keeps_mail_and_cursor(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{max_vanished => 1}),
    ok = mailio_fake_imap:deliver(Srv, <<"Third message">>),
    ok = mailio_fake_imap:deliver(Srv, <<"Fourth message">>),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(4, length(all_emails(Db))),
    {ok, LocalId} = inbox_local_id(Account),
    Before = cursor(Db, LocalId),
    ok = mailio_fake_imap:expunge(Srv, 100),
    ok = mailio_fake_imap:expunge(Srv, 101),
    ok = mailio_fake_imap:set_failure(Srv, meta, true),
    ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(4, length(all_emails(Db))),
    ?assertEqual(Before, cursor(Db, LocalId)),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(4, maps:get(<<"totalEmails">>, Mbx)),
    %% once the server answers again, the work is done
    ok = mailio_fake_imap:set_failure(Srv, meta, false),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))).

%% A message that cannot be fetched stops the resync before the cursor moves.
failed_body_fetch_keeps_the_cursor(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{max_vanished => 1}),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    {ok, LocalId} = inbox_local_id(Account),
    Before = cursor(Db, LocalId),
    ok = mailio_fake_imap:expunge(Srv, 100),
    ok = mailio_fake_imap:expunge(Srv, 101),
    ok = mailio_fake_imap:deliver(Srv, <<"Needs fetching">>),
    ok = mailio_fake_imap:set_failure(Srv, body, true),
    ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(Before, cursor(Db, LocalId)),
    ok = mailio_fake_imap:set_failure(Srv, body, false),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual([<<"Needs fetching">>], [maps:get(<<"subject">>, E) || E <- all_emails(Db)]).

%% The mailbox is recreated after the server reported too many changes and
%% before the full read: the UIDs it reuses are other messages.
recreated_mailbox_during_resync_replaces_reused_uids(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{max_vanished => 1}, mailio_failing_adapter),
    ok = mailio_fake_imap:deliver(Srv, <<"Third message">>),
    ok = mailio_fake_imap:deliver(Srv, <<"Fourth message">>),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(4, length(all_emails(Db))),
    ok = mailio_fake_imap:expunge(Srv, 102),
    ok = mailio_fake_imap:expunge(Srv, 103),
    application:set_env(mailio_store, before_full_read, fun() ->
        ok = mailio_fake_imap:new_validity(Srv, [<<"Reborn one">>, <<"Reborn two">>])
    end),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)
    after
        application:unset_env(mailio_store, before_full_read)
    end,
    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    %% uids 100 and 101 now belong to the new messages: no old body is kept
    ?assertEqual([<<"Reborn one">>, <<"Reborn two">>], Subjects),
    {ok, S2} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, maps:get(added, S2)),
    ?assertEqual(0, maps:get(removed, S2)).

%% Two UIDs holding the same mail are one email. Losing one UID must not
%% remove the email while the other UID is still on the server.
removing_one_duplicate_keeps_the_other_uid(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:deliver(Srv, <<"Twice">>),
    ok = mailio_fake_imap:deliver(Srv, <<"Twice">>),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    {ok, LocalId} = inbox_local_id(Account),
    ?assertEqual(3, length(all_emails(Db))),
    ok = mailio_fake_imap:expunge(Srv, 102),
    {ok, S} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(1, maps:get(removed, S)),
    ?assertEqual(3, length(all_emails(Db))),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(3, maps:get(<<"totalEmails">>, Mbx)),
    %% the second one goes too: now the email is gone
    ok = mailio_fake_imap:expunge(Srv, 103),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    {ok, Mbx2} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(2, maps:get(<<"totalEmails">>, Mbx2)).

removing_one_duplicate_in_a_resync_keeps_the_other_uid(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{max_vanished => 1}),
    ok = mailio_fake_imap:deliver(Srv, <<"Twice">>),
    ok = mailio_fake_imap:deliver(Srv, <<"Twice">>),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    {ok, LocalId} = inbox_local_id(Account),
    ok = mailio_fake_imap:expunge(Srv, 100),
    ok = mailio_fake_imap:expunge(Srv, 102),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    ?assertEqual([<<"Second message">>, <<"Twice">>], Subjects),
    %% the surviving UID still maps to the email, and the email knows only it
    {ok, EmailId} = mailio_account_writer:lookup_uid(Account, LocalId, 103),
    {ok, Twice} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    ?assertEqual([103], [maps:get(<<"uid">>, E) || E <- mailio_email:imap_entries(Twice, LocalId)]),
    ?assertEqual({error, not_found}, mailio_account_writer:lookup_uid(Account, LocalId, 102)),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(2, maps:get(<<"totalEmails">>, Mbx)),
    {ok, S2} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, maps:get(added, S2)),
    ?assertEqual(0, maps:get(removed, S2)).

%% The same mail in INBOX and Archive. When it is delivered again to INBOX and
%% then loses its last UID there, INBOX must not still hold it or count it.
shared_mail_leaves_a_mailbox_with_its_last_uid(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Raw = <<"From: a@x\r\nTo: b@y\r\nSubject: shared\r\nMessage-ID: <s1@x>\r\n\r\nbody\r\n">>,
    Inbox = <<"mbx-inbox">>,
    Archive = <<"mbx-archive">>,
    Total = fun(M) ->
        {ok, Doc} = mailio_db:get(Db, <<?ID_MAILBOX, M/binary>>),
        maps:get(<<"totalEmails">>, Doc)
    end,
    {ok, Id} = mailio_account_writer:ingest(Account, Inbox, Raw, #{uid => 5, uidvalidity => 1}),
    {ok, Id} = mailio_account_writer:ingest(Account, Archive, Raw, #{uid => 9, uidvalidity => 1}),
    ?assertEqual({1, 1}, {Total(Inbox), Total(Archive)}),
    %% INBOX loses its only UID: the email stays in Archive only
    ok = mailio_account_writer:remove_uid(Account, Inbox, 5),
    ?assertEqual({0, 1}, {Total(Inbox), Total(Archive)}),
    %% delivered to INBOX again, then gone again
    {ok, Id} = mailio_account_writer:ingest(Account, Inbox, Raw, #{uid => 6, uidvalidity => 1}),
    ?assertEqual({1, 1}, {Total(Inbox), Total(Archive)}),
    ok = mailio_account_writer:remove_uid(Account, Inbox, 6),
    ?assertEqual({0, 1}, {Total(Inbox), Total(Archive)}),
    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, Id/binary>>),
    ?assertEqual([], mailio_email:imap_entries(Email, Inbox)),
    ?assertNot(mailio_email:in_mailbox(Email, Inbox)),
    ?assert(mailio_email:in_mailbox(Email, Archive)).

state(Validity, UidNext) ->
    mailio_imap_map:encode_state(#{uidvalidity => Validity, uidnext => UidNext, highestmodseq => 10}).

added(Uid, Validity) ->
    {added, #{uid => Uid, uidvalidity => Validity, keywords => []}}.

%% A page of a full read says the mailbox was recreated. What the earlier pages
%% listed belongs to the old one and is not used: the read starts again.
a_reset_on_a_later_page_discards_the_earlier_pages(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    {ok, LocalId} = inbox_local_id(Account),
    ok = mailio_fake_imap:new_validity(Srv, [<<"Reborn one">>, <<"Reborn two">>]),
    Calls = counters:new(1, []),
    Final = state(2, 102),
    application:set_env(mailio_store, script, fun
        (<<"p1">>) ->
            {ok, [reset], <<"p2">>, more};
        (initial) ->
            counters:add(Calls, 1, 1),
            case counters:get(Calls, 1) of
                %% first read: a page, and then the news that the mailbox changed
                1 -> {ok, [added(100, 1)], <<"p1">>, more};
                _ -> {ok, [added(100, 2), added(101, 2)], Final, done}
            end;
        (S) ->
            {ok, [resync], S, done}
    end),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)
    after
        application:unset_env(mailio_store, script)
    end,
    ?assertEqual(2, counters:get(Calls, 1)),
    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    ?assertEqual([<<"Reborn one">>, <<"Reborn two">>], Subjects),
    {ok, Cur} = mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>),
    ?assertEqual(Final, maps:get(<<"remote_state">>, Cur)).

%% Same, for an adapter that does not say which UIDVALIDITY a message was listed
%% under: nothing tells the store that UIDs 100 and 101 are other messages now,
%% except the reset it was given. It must replace what it had.
a_reset_is_kept_when_the_adapter_names_no_uidvalidity(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    ok = mailio_fake_imap:new_validity(Srv, [<<"Reborn one">>, <<"Reborn two">>]),
    Calls = counters:new(1, []),
    Plain = fun(Uid) -> {added, #{uid => Uid, keywords => []}} end,
    application:set_env(mailio_store, script, fun
        (<<"p1">>) ->
            {ok, [reset], <<"p2">>, more};
        (initial) ->
            counters:add(Calls, 1, 1),
            case counters:get(Calls, 1) of
                1 -> {ok, [Plain(100)], <<"p1">>, more};
                _ -> {ok, [Plain(100), Plain(101)], state(2, 102), done}
            end;
        (S) ->
            {ok, [resync], S, done}
    end),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)
    after
        application:unset_env(mailio_store, script)
    end,
    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    ?assertEqual([<<"Reborn one">>, <<"Reborn two">>], Subjects).

%% A fetch that fails halfway through a page: the cursor stays, and when the
%% server recovers the same page is applied again. What was stored the first
%% time must not make the second time fail.
a_retry_after_a_failed_fetch_stores_both_messages(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, LocalId} = ensure_inbox(Account),
    WriterBefore = whereis_writer(Account),
    ok = mailio_fake_imap:set_failure(Srv, {body, 101}, true),
    ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(1, length(all_emails(Db))),
    ?assertEqual(none, cursor_or_none(Db, LocalId)),
    ok = mailio_fake_imap:set_failure(Srv, {body, 101}, false),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    ?assertNotEqual(none, cursor_or_none(Db, LocalId)),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(2, maps:get(<<"totalEmails">>, Mbx)),
    %% the writer was not taken down by the replay
    ?assertEqual(WriterBefore, whereis_writer(Account)),
    ?assert(is_process_alive(WriterBefore)).

%% The first sync stores the first message and fails on the second. Before the
%% retry the server changes. The retry must leave the store the way the server is.
partly_synced(Config) ->
    Account = ?config(account, Config),
    Srv = ?config(srv, Config),
    {ok, LocalId} = ensure_inbox(Account),
    ok = mailio_fake_imap:set_failure(Srv, {body, 101}, true),
    ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(1, length(all_emails(mailio_account:db_name(Account)))),
    LocalId.

finish_retry(Config) ->
    Account = ?config(account, Config),
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_failure(Srv, {body, 101}, false),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    %% nothing is left to report afterwards
    {ok, S} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual({0, 0, 0}, {maps:get(added, S), maps:get(removed, S), maps:get(updated, S)}).

mailbox_counts(Account, LocalId) ->
    {ok, Mbx} = mailio_db:get(mailio_account:db_name(Account), <<?ID_MAILBOX, LocalId/binary>>),
    {maps:get(<<"totalEmails">>, Mbx), maps:get(<<"unreadEmails">>, Mbx)}.

subjects(Account) ->
    lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(mailio_account:db_name(Account))]).

a_retry_after_the_mailbox_was_recreated_replaces_the_first_message(Config) ->
    Account = ?config(account, Config),
    Srv = ?config(srv, Config),
    LocalId = partly_synced(Config),
    ok = mailio_fake_imap:new_validity(Srv, [<<"Reborn one">>, <<"Reborn two">>]),
    finish_retry(Config),
    ?assertEqual([<<"Reborn one">>, <<"Reborn two">>], subjects(Account)),
    ?assertEqual({2, 2}, mailbox_counts(Account, LocalId)).

a_retry_after_an_expunge_removes_the_first_message(Config) ->
    Account = ?config(account, Config),
    Srv = ?config(srv, Config),
    LocalId = partly_synced(Config),
    ok = mailio_fake_imap:expunge(Srv, 100),
    finish_retry(Config),
    ?assertEqual([<<"Second message">>], subjects(Account)),
    ?assertEqual({1, 1}, mailbox_counts(Account, LocalId)).

a_retry_after_flags_were_cleared_updates_the_first_message(Config) ->
    Account = ?config(account, Config),
    Srv = ?config(srv, Config),
    LocalId = partly_synced(Config),
    %% message 100 was read; now it is not
    ok = mailio_fake_imap:set_flags(Srv, 100, []),
    finish_retry(Config),
    ?assertEqual(2, length(subjects(Account))),
    ?assertEqual({2, 2}, mailbox_counts(Account, LocalId)).

%% A full read keeps the UIDs it has seen, and the number of them is limited.
a_full_read_beyond_the_listing_limit_stops(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, LocalId} = ensure_inbox(Account),
    application:set_env(mailio_store, sync_max_listed_uids, 1),
    try
        ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>))
    after
        application:unset_env(mailio_store, sync_max_listed_uids)
    end,
    ?assertEqual(none, cursor_or_none(Db, LocalId)),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))).

%% More local UIDs than the database returns in one answer.
many_local_mails(Config, N) ->
    Account = ?config(account, Config),
    {ok, LocalId} = ensure_inbox(Account),
    [
        {ok, _} = mailio_account_writer:ingest(
            Account,
            LocalId,
            iolist_to_binary([
                <<"From: a@x\r\nTo: b@y\r\nSubject: bulk ">>,
                integer_to_binary(U),
                <<"\r\nMessage-ID: <b">>,
                integer_to_binary(U),
                <<"@x>\r\n\r\nbody ">>,
                integer_to_binary(U),
                <<"\r\n">>
            ]),
            #{uid => U, uidvalidity => 1}
        )
     || U <- lists:seq(1000, 999 + N)
    ],
    LocalId.

a_full_resync_removes_more_than_one_chunk_of_mappings(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    LocalId = many_local_mails(Config, 1201),
    ?assertEqual({1201, 1201}, mailbox_counts(Account, LocalId)),
    %% the server has nothing
    application:set_env(mailio_store, script, fun(_) -> {ok, [], state(1, 5000), done} end),
    application:set_env(mailio_store, mailbox_size, 0),
    try
        {ok, S} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        ?assertEqual(1201, maps:get(removed, S))
    after
        application:unset_env(mailio_store, script),
        application:unset_env(mailio_store, mailbox_size)
    end,
    ?assertEqual(0, length(all_emails(Db))),
    ?assertEqual({0, 0}, mailbox_counts(Account, LocalId)),
    {ok, Left} = mailio_db:by_id_prefix(Db, <<?ID_UIDMAP, LocalId/binary, "/">>),
    ?assertEqual([], Left),
    ?assertNotEqual(none, cursor_or_none(Db, LocalId)).

reconcile_removes_more_than_one_chunk_of_mappings(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    LocalId = many_local_mails(Config, 1201),
    {ok, S} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
    ?assertEqual(1201, maps:get(removed, S)),
    ?assertEqual(0, length(all_emails(Db))),
    ?assertEqual({0, 0}, mailbox_counts(Account, LocalId)).

%% A reset seen once must not be forgotten if the read that followed it failed:
%% what is held under the reused UIDs is replaced until a full read succeeds,
%% also after the sync process was restarted.
a_reset_is_remembered_across_a_failed_retry_and_a_restart(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    ok = mailio_fake_imap:new_validity(Srv, [<<"Reborn one">>, <<"Reborn two">>]),
    Plain = fun(Uid) -> {added, #{uid => Uid, keywords => []}} end,
    Calls = counters:new(1, []),
    %% first try: a page, then a reset, then the read that restarts fails
    application:set_env(mailio_store, script, fun
        (<<"p1">>) ->
            {ok, [reset], <<"p2">>, more};
        (initial) ->
            counters:add(Calls, 1, 1),
            case counters:get(Calls, 1) of
                1 -> {ok, [Plain(100)], <<"p1">>, more};
                _ -> {error, simulated_failure}
            end;
        (S) ->
            {ok, [resync], S, done}
    end),
    try
        ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>))
    after
        application:unset_env(mailio_store, script)
    end,
    %% the sync process starts again, knowing nothing of what happened
    restart_with(Config, #{}, mailio_failing_adapter),
    application:set_env(mailio_store, script, fun
        (initial) -> {ok, [Plain(100), Plain(101)], state(2, 102), done};
        (S) -> {ok, [resync], S, done}
    end),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)
    after
        application:unset_env(mailio_store, script)
    end,
    ?assertEqual([<<"Reborn one">>, <<"Reborn two">>], subjects(Account)).

%% Pages of a full read are applied in the order they come, so an update on a
%% later page is not lost.
a_streamed_read_applies_flag_updates_in_order(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, LocalId} = ensure_inbox(Account),
    Plain = fun(Uid) -> {added, #{uid => Uid, uidvalidity => 1, keywords => []}} end,
    application:set_env(mailio_store, script, fun
        (initial) ->
            {ok, [Plain(100), Plain(101)], <<"page2">>, more};
        (<<"page2">>) ->
            {ok, [{updated, #{uid => 100, keywords => [<<"$seen">>]}}], state(1, 102), done};
        (S) ->
            {ok, [], S, done}
    end),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)
    after
        application:unset_env(mailio_store, script)
    end,
    ?assertEqual(2, length(all_emails(Db))),
    ?assert(mailio_email:is_seen(email_by_subject(Db, <<"First message">>))),
    ?assertNot(mailio_email:is_seen(email_by_subject(Db, <<"Second message">>))),
    ?assertEqual({2, 1}, mailbox_counts(Account, LocalId)).

%% Two replies that read as an empty mailbox if they are taken as they are
%% written. Neither may make reconcile remove local mail.
reconcile_keeps_local_mail_for_a_modseq_suffix_alone(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ok = mailio_fake_imap:set_search(Srv, modseq_alone),
    ?assertMatch({error, _}, mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(2, length(all_emails(Db))).

reconcile_keeps_local_mail_for_a_uidnext_with_a_leading_zero(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ok = mailio_fake_imap:set_uidnext(Srv, <<"01">>),
    {ok, S} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, maps:get(removed, S)),
    ?assertEqual(2, length(all_emails(Db))).

reconcile_keeps_local_mail_for_an_invalid_highest_uid(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ok = mailio_fake_imap:set_uidnext(Srv, <<"01">>),
    ok = mailio_fake_imap:set_option(Srv, zero_max_uid, true),
    ?assertMatch({error, _}, mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(2, length(all_emails(Db))).

reconcile_keeps_local_mail_for_a_bad_modseq_suffix(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    [
        begin
            ok = mailio_fake_imap:set_search(Srv, Mode),
            ?assertMatch({error, _}, mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>)),
            ?assertEqual(2, length(all_emails(Db)))
        end
     || Mode <- [modseq_glued, modseq_zero]
    ].

%% With no valid UIDVALIDITY the first read gives no cursor, so a later read of
%% the same UIDs under another generation is not taken for "nothing new".
a_first_read_without_a_valid_uidvalidity_gives_no_cursor(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_option(Srv, bad_validity, true),
    ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)),
    ok = mailio_fake_imap:set_option(Srv, bad_validity, false),
    {ok, S} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, maps:get(added, S)),
    ?assertEqual(2, length(all_emails(Db))).

%% The integer 1 and the text "1" are two ids: removing one keeps the other.
integer_and_text_ids_do_not_collide(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_opaque_adapter),
    Mail = fun(N) ->
        <<"From: a@x\r\nTo: b@y\r\nSubject: id ", N/binary, "\r\nMessage-ID: <", N/binary,
            "@x>\r\n\r\nbody ", N/binary, "\r\n">>
    end,
    application:set_env(mailio_store, opaque_messages, #{
        1 => Mail(<<"int">>), <<"1">> => Mail(<<"text">>)
    }),
    try
        {ok, S1} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        ?assertEqual(2, maps:get(added, S1)),
        ?assertEqual(2, length(all_emails(Db))),
        %% the text id is gone from the provider: the integer one stays
        application:set_env(mailio_store, opaque_messages, #{1 => Mail(<<"int">>)}),
        {ok, R1} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        ?assertEqual(1, maps:get(removed, R1)),
        ?assertEqual([<<"id int">>], subjects(Account)),
        %% and the other way round
        application:set_env(mailio_store, opaque_messages, #{
            1 => Mail(<<"int">>), <<"1">> => Mail(<<"text">>)
        }),
        {ok, _} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        application:set_env(mailio_store, opaque_messages, #{<<"1">> => Mail(<<"text">>)}),
        {ok, R2} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        ?assertEqual(1, maps:get(removed, R2)),
        ?assertEqual([<<"id text">>], subjects(Account))
    after
        application:unset_env(mailio_store, opaque_messages)
    end.

%% Mappings an older version wrote sit under the UID as it is, with the UID and
%% its type in the document. They are found and removed for that UID only.
an_older_text_id_mapping_is_still_found(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_opaque_adapter),
    Mail = fun(N) ->
        <<"From: a@x\r\nTo: b@y\r\nSubject: old ", N/binary, "\r\nMessage-ID: <", N/binary,
            "@x>\r\n\r\nbody ", N/binary, "\r\n">>
    end,
    %% `x' and `b:x' are two messages; so are the texts 001 and 123
    Ids = [<<"x">>, <<"b:x">>, <<"001">>, <<"123">>],
    Messages = maps:from_list([{Id, Mail(Id)} || Id <- Ids]),
    application:set_env(mailio_store, opaque_messages, Messages),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        {ok, LocalId} = ensure_inbox(Account),
        [to_legacy_mapping(Db, Account, LocalId, Id) || Id <- Ids],
        %% each is found as itself
        Subject = fun(Id) ->
            {ok, EmailId} = mailio_account_writer:lookup_uid(Account, LocalId, Id),
            {ok, Email} = mailio_db:get(Db, <<"email/", EmailId/binary>>),
            maps:get(<<"subject">>, Email)
        end,
        ?assertEqual([<<"old x">>, <<"old b:x">>], [Subject(<<"x">>), Subject(<<"b:x">>)]),
        %% the provider drops `x' and `001': the others, and their mappings, stay
        application:set_env(
            mailio_store, opaque_messages, maps:with([<<"b:x">>, <<"123">>], Messages)
        ),
        {ok, R} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        ?assertEqual(2, maps:get(removed, R)),
        ?assertEqual([<<"old 123">>, <<"old b:x">>], lists:sort(subjects(Account))),
        ?assertEqual(
            {error, not_found}, mailio_account_writer:lookup_uid(Account, LocalId, <<"x">>)
        ),
        ?assertMatch({ok, _}, mailio_account_writer:lookup_uid(Account, LocalId, <<"b:x">>)),
        ?assertMatch({ok, _}, mailio_account_writer:lookup_uid(Account, LocalId, <<"123">>)),
        %% and all of them when the provider has nothing
        application:set_env(mailio_store, opaque_messages, #{}),
        {ok, R2} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        ?assertEqual(2, maps:get(removed, R2)),
        ?assertEqual([], all_emails(Db))
    after
        application:unset_env(mailio_store, opaque_messages)
    end.

%% A move to the new key that stopped half way leaves both records: reading the
%% same message again finishes it, and it can be repeated.
a_half_moved_mapping_is_finished_by_a_retry(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_opaque_adapter),
    Raw = <<"From: a@x\r\nTo: b@y\r\nSubject: half\r\nMessage-ID: <h@x>\r\n\r\nbody\r\n">>,
    application:set_env(mailio_store, opaque_messages, #{<<"h">> => Raw}),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        {ok, LocalId} = ensure_inbox(Account),
        Current = mailio_account_writer:uidmap_id(Account, LocalId, <<"h">>),
        {ok, Doc} = mailio_db:get(Db, Current),
        Old = <<"uidmap/", LocalId/binary, "/h">>,
        {ok, _, _} = mailio_db:put(Db, Doc#{<<"id">> => Old}),
        %% both exist; the mailbox is read in full twice
        [{ok, _} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>) || _ <- [1, 2]],
        ?assertEqual(1, length(all_emails(Db))),
        ?assertMatch({ok, _}, mailio_account_writer:lookup_uid(Account, LocalId, <<"h">>)),
        {ok, _} = mailio_account_writer:ingest(Account, LocalId, Raw, #{uid => <<"h">>}),
        ?assertEqual({error, not_found}, mailio_db:get(Db, Old))
    after
        application:unset_env(mailio_store, opaque_messages)
    end.

%% The server says two messages and the search finds none: not an inventory.
reconcile_keeps_local_mail_for_an_empty_answer_about_a_mailbox_with_mail(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ok = mailio_fake_imap:set_search(Srv, empty),
    ?assertMatch({error, _}, mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(2, length(all_emails(Db))).

%% UID 100 is listed on the first page and reported removed on the second: it is
%% gone at the end, and so is its mapping.
a_removal_on_a_later_page_of_a_full_read_is_applied(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, LocalId} = ensure_inbox(Account),
    Final = state(1, 102),
    application:set_env(mailio_store, script, fun
        (initial) -> {ok, [added(100, 1), added(101, 1)], <<"p1">>, more};
        (<<"p1">>) -> {ok, [{removed, 100}], Final, done};
        (S) -> {ok, [], S, done}
    end),
    application:set_env(mailio_store, mailbox_size, 1),
    try
        {ok, S} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        ?assertEqual(1, maps:get(removed, S))
    after
        application:unset_env(mailio_store, script),
        application:unset_env(mailio_store, mailbox_size)
    end,
    ?assertEqual([<<"Second message">>], subjects(Account)),
    ?assertEqual({error, not_found}, mailio_account_writer:lookup_uid(Account, LocalId, 100)),
    ?assertEqual({1, 1}, mailbox_counts(Account, LocalId)),
    ?assertEqual(1, length(all_emails(Db))).

%% A message given to the sink in two chunks is stored in full.
a_streamed_message_is_stored_whole(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    Head = <<"From: a@x\r\nTo: b@y\r\nSubject: chunked\r\nMessage-ID: <c@x>\r\n\r\n">>,
    Body = <<"the whole body of the message\r\n">>,
    application:set_env(mailio_store, script, fun
        (initial) -> {ok, [added(100, 1)], state(1, 101), done};
        (S) -> {ok, [], S, done}
    end),
    application:set_env(mailio_store, fetch_override, fun(_Uid, Sink) ->
        Sink(Head),
        Sink(Body),
        {ok, #{size => byte_size(Head) + byte_size(Body)}}
    end),
    application:set_env(mailio_store, mailbox_size, 1),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)
    after
        application:unset_env(mailio_store, script),
        application:unset_env(mailio_store, mailbox_size),
        application:unset_env(mailio_store, fetch_override)
    end,
    [Email] = all_emails(Db),
    ?assertEqual(byte_size(Head) + byte_size(Body), maps:get(<<"size">>, Email)).

%% What the adapter says it sent is what has to arrive: a short message is an
%% error and the cursor stays where it was.
a_message_that_arrives_short_is_not_stored(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, LocalId} = ensure_inbox(Account),
    Head = <<"From: a@x\r\nTo: b@y\r\nSubject: short\r\nMessage-ID: <s@x>\r\n\r\n">>,
    application:set_env(mailio_store, script, fun
        (initial) -> {ok, [added(100, 1)], state(1, 101), done};
        (S) -> {ok, [], S, done}
    end),
    application:set_env(mailio_store, fetch_override, fun(_Uid, Sink) ->
        Sink(Head),
        {ok, #{size => byte_size(Head) + 40}}
    end),
    try
        ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>))
    after
        application:unset_env(mailio_store, script),
        application:unset_env(mailio_store, fetch_override)
    end,
    ?assertEqual([], all_emails(Db)),
    ?assertEqual(none, cursor_or_none(Db, LocalId)).

%% A removal that stopped after the email was updated and before the mapping was
%% deleted is finished by the next one, and the counter moves once.
an_interrupted_removal_is_finished_and_counted_once(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Mail = fun(N) ->
        <<"From: a@x\r\nTo: b@y\r\nSubject: m", N/binary, "\r\nMessage-ID: <", N/binary,
            "@x>\r\n\r\nbody ", N/binary, "\r\n">>
    end,
    %% `one' is in both mailboxes, so it survives the removal from the first
    {ok, _} = mailio_account_writer:ingest(Account, <<"mbA">>, Mail(<<"one">>), #{uid => 1}),
    {ok, _} = mailio_account_writer:ingest(Account, <<"mbB">>, Mail(<<"one">>), #{uid => 1}),
    {ok, _} = mailio_account_writer:ingest(Account, <<"mbA">>, Mail(<<"two">>), #{uid => 2}),
    ?assertEqual({2, 2}, mailbox_counts(Account, <<"mbA">>)),
    Map = mailio_account_writer:uidmap_id(Account, <<"mbA">>, 1),
    {ok, Doc} = mailio_db:get(Db, Map),
    ok = mailio_account_writer:remove_uid(Account, <<"mbA">>, 1),
    ?assertEqual({1, 1}, mailbox_counts(Account, <<"mbA">>)),
    %% the state a stop before the last step leaves: the mapping is still there
    {ok, _, _} = mailio_db:put(Db, maps:without([<<"_rev">>], Doc)),
    ok = mailio_account_writer:remove_uid(Account, <<"mbA">>, 1),
    ?assertEqual({1, 1}, mailbox_counts(Account, <<"mbA">>)),
    ?assertEqual({1, 1}, mailbox_counts(Account, <<"mbB">>)),
    ?assertEqual({error, not_found}, mailio_account_writer:lookup_uid(Account, <<"mbA">>, 1)),
    ?assertEqual(2, length(all_emails(Db))).

%% A connection that gave up (the server sent more than it may) is not kept: the
%% next sync runs on a new one.
a_connection_that_gave_up_is_replaced(Config) ->
    Account = ?config(account, Config),
    application:set_env(mailio_store, connect_count, 0),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = ensure_inbox(Account),
    Before = application:get_env(mailio_store, connect_count, 0),
    application:set_env(mailio_store, script, fun(_) ->
        {error, #{code => imap_command_failed, detail => response_too_large}}
    end),
    try
        ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>))
    after
        application:unset_env(mailio_store, script)
    end,
    wait_until(fun() -> application:get_env(mailio_store, connect_count, 0) > Before end, 3000),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(mailio_account:db_name(Account)))),
    application:unset_env(mailio_store, connect_count).

%% The same read email in a second mailbox is read there too.
a_shared_read_email_is_not_unread_in_the_second_mailbox(Config) ->
    Account = ?config(account, Config),
    Raw = <<"From: a@x\r\nTo: b@y\r\nSubject: shared\r\nMessage-ID: <sh@x>\r\n\r\nbody\r\n">>,
    {ok, _} = mailio_account_writer:ingest(Account, <<"mbA">>, Raw, #{keywords => [<<"$seen">>]}),
    {ok, _} = mailio_account_writer:ingest(Account, <<"mbB">>, Raw, #{keywords => [<<"$seen">>]}),
    ?assertEqual({1, 0}, mailbox_counts(Account, <<"mbA">>)),
    ?assertEqual({1, 0}, mailbox_counts(Account, <<"mbB">>)).

%% The build that ran for a while kept a text UID after `b:' in the old namespace.
a_mapping_of_the_intermediate_build_is_still_found(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_opaque_adapter),
    Raw = <<"From: a@x\r\nTo: b@y\r\nSubject: mid\r\nMessage-ID: <m@x>\r\n\r\nbody\r\n">>,
    application:set_env(mailio_store, opaque_messages, #{<<"msg-a">> => Raw}),
    try
        {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        {ok, LocalId} = ensure_inbox(Account),
        Current = mailio_account_writer:uidmap_id(Account, LocalId, <<"msg-a">>),
        {ok, Doc} = mailio_db:get(Db, Current),
        Mid = <<"uidmap/", LocalId/binary, "/b:msg-a">>,
        {ok, _, _} = mailio_db:put(Db, Doc#{<<"id">> => Mid}),
        _ = mailio_db:delete(Db, Current),
        ?assertMatch({ok, _}, mailio_account_writer:lookup_uid(Account, LocalId, <<"msg-a">>)),
        application:set_env(mailio_store, opaque_messages, #{}),
        {ok, R} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        ?assertEqual(1, maps:get(removed, R)),
        ?assertEqual([], all_emails(Db))
    after
        application:unset_env(mailio_store, opaque_messages)
    end.

%% A full read that lists one message of the two the server holds is not an
%% inventory: nothing is removed on it, and the cursor stays.
a_full_read_that_misses_messages_removes_nothing(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    {ok, LocalId} = ensure_inbox(Account),
    Before = cursor(Db, LocalId),
    application:set_env(mailio_store, script, fun
        (initial) -> {ok, [added(100, 1)], state(1, 102), done};
        (S) -> {ok, [resync], S, done}
    end),
    try
        ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>))
    after
        application:unset_env(mailio_store, script)
    end,
    ?assertEqual(2, length(all_emails(Db))),
    ?assertEqual(Before, cursor(Db, LocalId)).

%% The sync an IDLE wake-up runs may find the connection dead: it is replaced and
%% the watch goes on the new one.
an_idle_sync_that_finds_a_dead_connection_keeps_the_watch(Config) ->
    Account = ?config(account, Config),
    application:set_env(mailio_store, connect_count, 0),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = ensure_inbox(Account),
    ok = mailio_sync_mgr:watch_inbox(Account),
    IdlesBefore = idle_count(?config(srv, Config)),
    Before = application:get_env(mailio_store, connect_count, 0),
    application:set_env(mailio_store, script, fun(_) ->
        {error, #{code => imap_command_failed, detail => response_too_large}}
    end),
    Mgr = mailio_registry:whereis_name({sync, Account}),
    Mgr ! {imap_idle_event, self(), changed},
    wait_until(fun() -> application:get_env(mailio_store, connect_count, 0) > Before end, 3000),
    application:unset_env(mailio_store, script),
    %% the new connection is watched
    Srv = ?config(srv, Config),
    wait_until(fun() -> idle_count(Srv) > IdlesBefore end, 3000),
    application:unset_env(mailio_store, connect_count).

%% The email left the mailbox and the counter write was refused: the mailbox is
%% marked, and the next removal counts it again from the emails.
a_removal_that_failed_between_the_email_and_the_counter_is_repaired(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Mail = fun(N) ->
        <<"From: a@x\r\nTo: b@y\r\nSubject: m", N/binary, "\r\nMessage-ID: <", N/binary,
            "@x>\r\n\r\nbody ", N/binary, "\r\n">>
    end,
    {ok, One} = mailio_account_writer:ingest(Account, <<"mbA">>, Mail(<<"one">>), #{uid => 1}),
    {ok, _} = mailio_account_writer:ingest(Account, <<"mbA">>, Mail(<<"two">>), #{uid => 2}),
    {ok, _} = mailio_account_writer:ingest(Account, <<"mbB">>, Mail(<<"one">>), #{uid => 1}),
    %% the state after the email was written and before the counter was
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, "mbA">>),
    {ok, _, _} = mailio_db:put(Db, Mbx#{<<"counters_dirty">> => true}),
    {ok, Email} = mailio_db:get(Db, <<"email/", One/binary>>),
    {ok, _, _} = mailio_db:put(Db, mailio_email:remove_mailbox(Email, <<"mbA">>)),
    ?assertEqual({2, 2}, mailbox_counts(Account, <<"mbA">>)),
    %% the removal is tried again
    ok = mailio_account_writer:remove_uid(Account, <<"mbA">>, 1),
    ?assertEqual({1, 1}, mailbox_counts(Account, <<"mbA">>)),
    ?assertEqual({ok, []}, mailio_fsck:check_counters(Account)),
    {ok, Fixed} = mailio_db:get(Db, <<?ID_MAILBOX, "mbA">>),
    ?assertNot(maps:is_key(<<"counters_dirty">>, Fixed)).

idle_count(Srv) ->
    length([
        C
     || C <- mailio_fake_imap:commands(Srv), re:run(C, <<"^IDLE">>, [caseless]) =/= nomatch
    ]).

%% The sink always answers ok, as its contract says, and a message past the size
%% limit is refused when the adapter is done.
a_sink_answers_ok_past_the_size_limit(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, LocalId} = ensure_inbox(Account),
    Big = binary:copy(<<"x">>, 64),
    application:set_env(mailio_store, sync_max_message_bytes, 16),
    application:set_env(mailio_store, script, fun
        (initial) -> {ok, [added(100, 1)], state(1, 101), done};
        (S) -> {ok, [], S, done}
    end),
    Self = self(),
    application:set_env(mailio_store, fetch_override, fun(_Uid, Sink) ->
        Self ! {sink_answer, Sink([Big, Big])},
        {ok, #{size => 128}}
    end),
    try
        ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>))
    after
        application:unset_env(mailio_store, script),
        application:unset_env(mailio_store, fetch_override),
        application:unset_env(mailio_store, sync_max_message_bytes)
    end,
    ?assertEqual(
        ok,
        receive
            {sink_answer, A} -> A
        after 1000 -> no_answer
        end
    ),
    ?assertEqual([], all_emails(Db)),
    ?assertEqual(none, cursor_or_none(Db, LocalId)).

%% What an older version stored for `Id': the UID as it is, under the old prefix.
to_legacy_mapping(Db, Account, LocalId, Id) ->
    Current = mailio_account_writer:uidmap_id(Account, LocalId, Id),
    {ok, Doc} = mailio_db:get(Db, Current),
    Old = <<"uidmap/", LocalId/binary, "/", Id/binary>>,
    {ok, _, _} = mailio_db:put(Db, Doc#{<<"id">> => Old}),
    _ = mailio_db:delete(Db, Current),
    ok.

%% Ids that are not numbers: two distinct ones are two messages, in a first read,
%% in the next, and in a reconcile.
opaque_ids_are_synced_and_reconciled(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_opaque_adapter),
    Mail = fun(N) ->
        <<"From: a@x\r\nTo: b@y\r\nSubject: opaque ", N/binary, "\r\nMessage-ID: <", N/binary,
            "@x>\r\n\r\nbody ", N/binary, "\r\n">>
    end,
    application:set_env(mailio_store, opaque_messages, #{
        <<"msg-a">> => Mail(<<"a">>), <<"msg-b">> => Mail(<<"b">>)
    }),
    try
        {ok, S1} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        ?assertEqual(2, maps:get(added, S1)),
        ?assertEqual(2, length(all_emails(Db))),
        %% the same mailbox again changes nothing
        {ok, S2} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
        ?assertEqual(0, maps:get(removed, S2)),
        ?assertEqual(2, length(all_emails(Db))),
        {ok, R} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        ?assertEqual(0, maps:get(removed, R)),
        %% one is gone from the provider
        application:set_env(mailio_store, opaque_messages, #{<<"msg-a">> => Mail(<<"a">>)}),
        {ok, R2} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
        ?assertEqual(1, maps:get(removed, R2)),
        ?assertEqual([<<"opaque a">>], subjects(Account))
    after
        application:unset_env(mailio_store, opaque_messages)
    end.

%% A listing that does not say what is there is not a listing of nothing.
an_unreliable_listing_does_not_remove_local_mail(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Srv = ?config(srv, Config),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    [ok = mailio_fake_imap:set_search(Srv, Mode) || Mode <- [none]],
    ?assertMatch({error, _}, mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(2, length(all_emails(Db))),
    ok = mailio_fake_imap:set_search(Srv, junk),
    ?assertMatch({error, _}, mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(2, length(all_emails(Db))).

whereis_writer(Account) ->
    {ok, Pid} = mailio_registry:lookup({writer, Account}),
    Pid.

%% An adapter that answers `more' with the cursor it was given is not getting
%% anywhere: the sync ends instead of asking for ever.
a_repeated_cursor_ends_the_sync(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    {ok, LocalId} = inbox_local_id(Account),
    Before = cursor(Db, LocalId),
    application:set_env(mailio_store, script, fun(Cursor) -> {ok, [], Cursor, more} end),
    try
        {T, R} = timer:tc(fun() -> mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>) end),
        ?assertEqual({error, repeated_cursor}, R),
        ?assert(T < 5000000)
    after
        application:unset_env(mailio_store, script)
    end,
    ?assertEqual(Before, cursor(Db, LocalId)).

an_endless_listing_is_bounded(Config) ->
    Account = ?config(account, Config),
    restart_with(Config, #{}, mailio_failing_adapter),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    Counter = counters:new(1, []),
    application:set_env(mailio_store, sync_max_pages, 40),
    application:set_env(mailio_store, script, fun(_) ->
        counters:add(Counter, 1, 1),
        N = counters:get(Counter, 1),
        {ok, [], state(1, 1000 + N), more}
    end),
    try
        ?assertEqual({error, too_many_pages}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>))
    after
        application:unset_env(mailio_store, script),
        application:unset_env(mailio_store, sync_max_pages)
    end,
    ?assert(counters:get(Counter, 1) =< 41).

%% UIDs listed under a UIDVALIDITY are only trusted to an adapter that can check
%% it when the message is fetched. Without that, the cursor stays and the mail is
%% still there for a retry.
an_adapter_that_cannot_check_uidvalidity_keeps_the_cursor(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    restart_with(Config, #{}, mailio_plain_adapter),
    {ok, LocalId0} = ensure_inbox(Account),
    ?assertMatch({error, _}, mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>)),
    ?assertEqual(0, length(all_emails(Db))),
    ?assertEqual(none, cursor_or_none(Db, LocalId0)),
    %% an adapter that can check it sees the mail on the retry
    restart_with(Config, #{}, mailio_imap),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))).

ensure_inbox(Account) ->
    %% the mailbox list is read when the sync manager connects
    wait_until(fun() -> inbox_local_id(Account) =/= not_found end, 3000),
    inbox_local_id(Account).

cursor_or_none(Db, LocalId) ->
    case mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>) of
        {ok, _} -> cursor(Db, LocalId);
        {error, not_found} -> none
    end.

restart_with(Config, Extra) ->
    restart_with(Config, Extra, mailio_imap).

restart_with(Config, Extra, Adapter) ->
    Account = ?config(account, Config),
    Srv = ?config(srv, Config),
    ok = mailio_accounts_sup:stop_account(Account),
    Imap = maps:merge(
        #{
            host => <<"127.0.0.1">>,
            port => mailio_fake_imap:port(Srv),
            tls => false,
            username => <<"u">>,
            password => <<"p">>
        },
        Extra
    ),
    {ok, _} = mailio_accounts_sup:start_account(Account, #{imap => Imap, adapter => Adapter}),
    ok.

cursor(Db, LocalId) ->
    {ok, Doc} = mailio_db:get(Db, <<?ID_SYNC_IMAP, LocalId/binary>>),
    maps:without([<<"_rev">>, <<"at">>, <<"updated_at">>], Doc).

wait_until(Pred, Timeout) when Timeout =< 0 ->
    case Pred() of
        true -> ok;
        false -> error(timeout)
    end;
wait_until(Pred, Timeout) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Pred, Timeout - 100)
    end.

%%====================================================================
%% Helpers
%%====================================================================

all_emails(Db) ->
    {ok, Emails} = mailio_db:by_id_prefix(Db, <<"email/">>),
    Emails.

email_by_subject(Db, Subject) ->
    {ok, [E | _], _} = mailio_db:find(
        Db,
        #{where => [{path, [<<"subject">>], Subject}], limit => 1},
        #{include_docs => true}
    ),
    E.

inbox_local_id(Account) ->
    Db = mailio_account:db_name(Account),
    Query = #{where => [{path, [?MAILIO_NS, <<"imap_name">>], <<"INBOX">>}], limit => 1},
    case mailio_db:find(Db, Query, #{include_docs => true}) of
        {ok, [#{<<"id">> := <<?ID_MAILBOX, LocalId/binary>>} | _], _} -> {ok, LocalId};
        _ -> not_found
    end.

added(#{mailboxes := _} = _Stats) -> error(bad_stats);
added(Stats) -> maps:get(added, Stats, 0).

drain(Timeout) ->
    receive
        {mailio_event, _Ref, Env} -> [Env | drain(Timeout)]
    after Timeout -> []
    end.
