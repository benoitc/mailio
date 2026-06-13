%%% @doc M3 end-to-end ingestion suite.
%%%
%%% Exercises the no-network pipeline: feed raw RFC 5322 bytes through the
%%% account writer and assert the persisted email/thread/text/mailbox
%%% documents, live event delivery, threading, idempotent re-ingest, and
%%% multi-mailbox membership.
-module(mailio_ingest_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([ingest_creates_documents/1,
         ingest_emits_events/1,
         idempotent_reingest/1,
         copy_to_second_mailbox/1,
         threads_reply_together/1,
         threads_by_subject_fallback/1,
         unrelated_message_new_thread/1,
         state_token_advances/1]).

all() ->
    [ingest_creates_documents,
     ingest_emits_events,
     idempotent_reingest,
     copy_to_second_mailbox,
     threads_reply_together,
     threads_by_subject_fallback,
     unrelated_message_new_thread,
     state_token_advances].

init_per_suite(Config) ->
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
    %% A fresh account (and database) per test case.
    Account = list_to_binary("ACCT" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    [{account, Account} | Config].

end_per_testcase(_TC, Config) ->
    Account = ?config(account, Config),
    ok = mailio_accounts_sup:stop_account(Account),
    try mailio_db:delete_db(mailio_account:db_name(Account)) catch _:_ -> ok end,
    ok.

%%====================================================================
%% Cases
%%====================================================================

ingest_creates_documents(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),

    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    ?assertEqual(<<"Project kickoff">>, maps:get(<<"subject">>, Email)),
    ?assertEqual([<<"alice@example.com">>],
                 [E || #{<<"email">> := E} <- maps:get(<<"from">>, Email)]),
    ?assert(maps:is_key(<<"inbox">>, maps:get(<<"mailboxIds">>, Email))),
    ?assertMatch(<<"sha256-", _/binary>>, maps:get(<<"blobId">>, Email)),
    ThreadId = maps:get(<<"threadId">>, Email),
    ?assert(is_binary(ThreadId)),

    %% Thread doc references the email.
    {ok, Thread} = mailio_db:get(Db, <<?ID_THREAD, ThreadId/binary>>),
    ?assertEqual([EmailId], maps:get(<<"emailIds">>, Thread)),

    %% Text doc carries the extracted body.
    {ok, Text} = mailio_db:get(Db, <<?ID_TEXT, EmailId/binary>>),
    ?assert(binary:match(maps:get(<<"body_text">>, Text), <<"start the project">>)
            =/= nomatch),

    %% Raw blob is retrievable and matches the input.
    {ok, Raw} = mailio_blob:get(Db, maps:get(<<"blobId">>, Email)),
    ?assertEqual(msg1(), Raw),

    %% Mailbox counter updated.
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, "inbox">>),
    ?assertEqual(1, maps:get(<<"totalEmails">>, Mbx)),
    ?assertEqual(1, maps:get(<<"unreadEmails">>, Mbx)).

ingest_emits_events(Config) ->
    Account = ?config(account, Config),
    {ok, _Ref} = mailio_events:subscribe(#{account => Account,
                                           types => [email, thread, mailbox]}),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),

    Events = drain_events(300),
    Types = [{maps:get(type, E), maps:get(verb, E)} || E <- Events],
    ?assert(lists:member({email, created}, Types)),
    ?assert(lists:member({thread, created}, Types)),
    ?assert(lists:member({mailbox, created}, Types) orelse
            lists:member({mailbox, updated}, Types)),

    EmailEv = hd([E || E <- Events, maps:get(type, E) =:= email]),
    ?assertEqual(EmailId, maps:get(object_id, EmailEv)),
    ?assertEqual(Account, maps:get(account_id, EmailEv)),
    ?assertEqual(<<"Project kickoff">>, maps:get(subject, maps:get(data, EmailEv))).

idempotent_reingest(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, Id1} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),
    {ok, Id2} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),
    ?assertEqual(Id1, Id2),

    %% Exactly one email doc, one thread member, counter still 1.
    {ok, [_], _} = mailio_db:find(Db, #{where => [{path, [?MAILIO_NS, <<"parse_version">>], 1}]}),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, "inbox">>),
    ?assertEqual(1, maps:get(<<"totalEmails">>, Mbx)),
    ?assertEqual(1, mailio_blob:ref_count(Db, maps:get(<<"blobId">>,
                       element(2, mailio_db:get(Db, <<?ID_EMAIL, Id1/binary>>))))).

copy_to_second_mailbox(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),
    {ok, EmailId} = mailio_account:ingest_raw(Account, <<"archive">>, msg1()),

    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    Mailboxes = maps:keys(maps:get(<<"mailboxIds">>, Email)),
    ?assertEqual([<<"archive">>, <<"inbox">>], lists:sort(Mailboxes)),

    {ok, Inbox} = mailio_db:get(Db, <<?ID_MAILBOX, "inbox">>),
    {ok, Archive} = mailio_db:get(Db, <<?ID_MAILBOX, "archive">>),
    ?assertEqual(1, maps:get(<<"totalEmails">>, Inbox)),
    ?assertEqual(1, maps:get(<<"totalEmails">>, Archive)).

threads_reply_together(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, Id1} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),
    {ok, Id2} = mailio_account:ingest_raw(Account, <<"inbox">>, reply_to_msg1()),

    {ok, E1} = mailio_db:get(Db, <<?ID_EMAIL, Id1/binary>>),
    {ok, E2} = mailio_db:get(Db, <<?ID_EMAIL, Id2/binary>>),
    ?assertEqual(maps:get(<<"threadId">>, E1), maps:get(<<"threadId">>, E2)),

    ThreadId = maps:get(<<"threadId">>, E1),
    {ok, Thread} = mailio_db:get(Db, <<?ID_THREAD, ThreadId/binary>>),
    ?assertEqual([Id1, Id2], maps:get(<<"emailIds">>, Thread)).

%% No Message-ID references between these two, but the same normalized
%% subject and a shared participant: they must thread via the subject
%% fallback (which relies on a nested-field find — the bug fixed by moving
%% the internal namespace off the reserved `_'-prefix).
threads_by_subject_fallback(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    A = <<"From: Alice <alice@example.com>\r\n",
          "To: Bob <bob@example.com>\r\n",
          "Subject: Quarterly report\r\n",
          "Message-ID: <s1@example.com>\r\n",
          "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\n\r\n",
          "First.\r\n">>,
    B = <<"From: Bob <bob@example.com>\r\n",
          "To: Alice <alice@example.com>\r\n",
          "Subject: RE: Quarterly report\r\n",
          "Message-ID: <s2@example.com>\r\n",
          "Date: Mon, 2 Jun 2025 09:30:00 +0000\r\n\r\n",
          "Second.\r\n">>,
    {ok, Id1} = mailio_account:ingest_raw(Account, <<"inbox">>, A),
    {ok, Id2} = mailio_account:ingest_raw(Account, <<"inbox">>, B),
    {ok, E1} = mailio_db:get(Db, <<?ID_EMAIL, Id1/binary>>),
    {ok, E2} = mailio_db:get(Db, <<?ID_EMAIL, Id2/binary>>),
    ?assertEqual(maps:get(<<"threadId">>, E1), maps:get(<<"threadId">>, E2)).

unrelated_message_new_thread(Config) ->
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, Id1} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),
    {ok, Id3} = mailio_account:ingest_raw(Account, <<"inbox">>, unrelated_msg()),
    {ok, E1} = mailio_db:get(Db, <<?ID_EMAIL, Id1/binary>>),
    {ok, E3} = mailio_db:get(Db, <<?ID_EMAIL, Id3/binary>>),
    ?assertNotEqual(maps:get(<<"threadId">>, E1), maps:get(<<"threadId">>, E3)).

state_token_advances(Config) ->
    Account = ?config(account, Config),
    Before = mailio_account:state_token(Account),
    {ok, _} = mailio_account:ingest_raw(Account, <<"inbox">>, msg1()),
    After = mailio_account:state_token(Account),
    ?assertNotEqual(Before, After),
    %% Token round-trips through the cursor codec.
    ?assertMatch({ok, _}, mailio_cursor:decode(After)).

%%====================================================================
%% Helpers
%%====================================================================

drain_events(Timeout) ->
    receive
        {mailio_event, _Ref, Env} -> [Env | drain_events(Timeout)]
    after Timeout -> []
    end.

msg1() ->
    <<"From: Alice <alice@example.com>\r\n",
      "To: Bob <bob@example.com>\r\n",
      "Subject: Project kickoff\r\n",
      "Message-ID: <m1@example.com>\r\n",
      "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "\r\n",
      "Let's start the project this week.\r\n">>.

reply_to_msg1() ->
    <<"From: Bob <bob@example.com>\r\n",
      "To: Alice <alice@example.com>\r\n",
      "Subject: Re: Project kickoff\r\n",
      "Message-ID: <m2@example.com>\r\n",
      "In-Reply-To: <m1@example.com>\r\n",
      "References: <m1@example.com>\r\n",
      "Date: Mon, 2 Jun 2025 10:00:00 +0000\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "\r\n",
      "Sounds good, let's go.\r\n">>.

unrelated_msg() ->
    <<"From: Carol <carol@example.com>\r\n",
      "To: Bob <bob@example.com>\r\n",
      "Subject: Lunch tomorrow?\r\n",
      "Message-ID: <u1@example.com>\r\n",
      "Date: Mon, 2 Jun 2025 11:00:00 +0000\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "\r\n",
      "Want to grab lunch?\r\n">>.
