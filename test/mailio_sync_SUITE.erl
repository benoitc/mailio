%%% @doc M5 sync-engine vertical slice (against the scripted fake server).
%%%
%%% Proves the full chain: a configured IMAP account discovers mailboxes,
%%% backfills INBOX into the store (emitting events), persists a cursor, and
%%% reflects a later server-side flag change as an `email.updated' event —
%%% the milestone's "mark-as-read on the phone shows up locally" slice.
-module(mailio_sync_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([backfill_ingests_messages/1,
         backfill_emits_events/1,
         cursor_persists_no_redundant_fetch/1,
         flag_change_updates_email/1]).

all() ->
    [backfill_ingests_messages,
     backfill_emits_events,
     cursor_persists_no_redundant_fetch,
     flag_change_updates_email].

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
    Srv = mailio_fake_imap:start(),
    Account = list_to_binary("SYNC" ++ integer_to_list(erlang:unique_integer([positive]))),
    Imap = #{host => <<"127.0.0.1">>, port => mailio_fake_imap:port(Srv),
             tls => false, username => <<"u">>, password => <<"p">>},
    {ok, _} = mailio_accounts_sup:start_account(Account, #{imap => Imap}),
    [{srv, Srv}, {account, Account} | Config].

end_per_testcase(_TC, Config) ->
    Account = ?config(account, Config),
    try mailio_accounts_sup:stop_account(Account) catch _:_ -> ok end,
    try mailio_db:delete_db(mailio_account:db_name(Account)) catch _:_ -> ok end,
    try mailio_fake_imap:stop(?config(srv, Config)) catch _:_ -> ok end,
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
    Created = [E || E <- Events, maps:get(type, E) =:= email,
                    maps:get(verb, E) =:= created],
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
    ?assert(lists:any(fun(E) -> maps:get(type, E) =:= email andalso
                                maps:get(verb, E) =:= updated end, Events)),

    %% Unread counter dropped to 0.
    {ok, LocalId} = inbox_local_id(Account),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    ?assertEqual(0, maps:get(<<"unreadEmails">>, Mbx)).

%%====================================================================
%% Helpers
%%====================================================================

all_emails(Db) ->
    {ok, Emails, _} = mailio_db:find(
        Db, #{where => [{path, [?MAILIO_NS, <<"parse_version">>], 1}]},
        #{include_docs => true}),
    Emails.

email_by_subject(Db, Subject) ->
    {ok, [E | _], _} = mailio_db:find(
        Db, #{where => [{path, [<<"subject">>], Subject}], limit => 1},
        #{include_docs => true}),
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
