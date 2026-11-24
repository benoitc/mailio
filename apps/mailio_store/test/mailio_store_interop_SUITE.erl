%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc The store syncing from real mail servers: what a server does, as
%%% opposed to what a scripted one was told to do. Each server is a group and
%%% is skipped, with one message, when it is not running. The servers and how
%%% to start them are in the "Interoperability" section of CONTRIBUTING.md.
%%%
%%% Flag changes need CONDSTORE and removals need QRESYNC on the incremental
%%% path, so a server without them is only expected to ingest new mail there.
%%% Removals are always found by a reconcile pass, which every server supports.
-module(mailio_store_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio_store.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    backfill_ingests_real_messages/1,
    second_sync_reports_nothing/1,
    flag_change_reaches_the_store/1,
    expunge_removes_the_email/1,
    idle_push_ingests_new_mail/1
]).

all() -> [{group, dovecot}, {group, greenmail}, {group, stalwart}].

groups() ->
    Cases = [
        backfill_ingests_real_messages,
        second_sync_reports_nothing,
        flag_change_reaches_the_store,
        expunge_removes_the_email,
        idle_push_ingests_new_mail
    ],
    [{dovecot, [], Cases}, {greenmail, [], Cases}, {stalwart, [], Cases}].

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

init_per_group(Name, Config) ->
    P = mailio_servers:profile(Name),
    case mailio_servers:reachable(maps:get(imap, P)) of
        false ->
            {skip,
                lists:flatten(
                    io_lib:format("~p is not running, see CONTRIBUTING.md (Interoperability)", [
                        Name
                    ])
                )};
        true ->
            [{profile, P} | Config]
    end.

end_per_group(_Name, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    P = ?config(profile, Config),
    purge(P),
    Account = list_to_binary("RS" ++ integer_to_list(erlang:unique_integer([positive]))),
    Imap = imap_cfg(P),
    {ok, _} = mailio_accounts_sup:start_account(Account, #{imap => Imap}),
    {ok, Probe} = mailio_imap:connect(Imap),
    Caps = mailio_imap:capabilities(Probe),
    mailio_imap:close(Probe),
    [{account, Account}, {caps, Caps} | Config].

end_per_testcase(_Case, Config) ->
    Account = ?config(account, Config),
    try
        mailio_accounts_sup:stop_account(Account),
        mailio_db:delete_db(mailio_account:db_name(Account))
    catch
        _:_ -> ok
    end,
    ok.

%%====================================================================
%% Cases
%%====================================================================

backfill_ingests_real_messages(Config) ->
    P = ?config(profile, Config),
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    Subject = <<"Réunion à 14h ☕"/utf8>>,
    put_mail(P, [
        message(<<"first">>, <<"1\r\n">>),
        attachment_message(Subject, <<"Bonjour\r\n">>, crypto:strong_rand_bytes(50 * 1024)),
        message(<<"third">>, <<"3\r\n">>)
    ]),
    {ok, Stats} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(3, maps:get(added, Stats)),
    Subjects = lists:sort([maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    ?assertEqual(lists:sort([<<"first">>, Subject, <<"third">>]), Subjects),
    ?assertEqual(3, mailbox_total(Account)),
    %% the attachment is known to the store
    [WithAtt] = [E || E <- all_emails(Db), maps:get(<<"subject">>, E) =:= Subject],
    ?assert(maps:get(<<"hasAttachment">>, WithAtt, false)).

%% A real server returns the newest message for any range that starts past the
%% end, so a second pass must not count it again.
second_sync_reports_nothing(Config) ->
    P = ?config(profile, Config),
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    put_mail(P, [message(<<"a">>, <<"1\r\n">>), message(<<"b">>, <<"2\r\n">>)]),
    {ok, S1} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, maps:get(added, S1)),
    {ok, S2} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(0, maps:get(added, S2)),
    ?assertEqual(0, maps:get(removed, S2)),
    ?assertEqual(2, length(all_emails(Db))).

flag_change_reaches_the_store(Config) ->
    P = ?config(profile, Config),
    Account = ?config(account, Config),
    Caps = ?config(caps, Config),
    Db = mailio_account:db_name(Account),
    put_mail(P, [message(<<"to read">>, <<"x\r\n">>)]),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertNot(mailio_email:is_seen(email_by_subject(Db, <<"to read">>))),
    server_cmd(P, fun(T) ->
        mailio_imap_proto:uid_store(T, {range, 1, '*'}, {add, true}, [<<"\\Seen">>])
    end),
    {ok, Stats} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    case maps:get(condstore, Caps, false) of
        true ->
            ?assertEqual(1, maps:get(updated, Stats)),
            ?assert(mailio_email:is_seen(email_by_subject(Db, <<"to read">>)));
        false ->
            %% without CONDSTORE a flag change is not visible to an incremental pass
            ok
    end.

expunge_removes_the_email(Config) ->
    P = ?config(profile, Config),
    Account = ?config(account, Config),
    Caps = ?config(caps, Config),
    Db = mailio_account:db_name(Account),
    put_mail(P, [message(<<"stays">>, <<"1\r\n">>), message(<<"goes">>, <<"2\r\n">>)]),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ?assertEqual(2, length(all_emails(Db))),
    server_expunge(P, <<"goes">>),
    {ok, Stats} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    case maps:get(qresync, Caps, false) of
        true -> ?assertEqual(1, maps:get(removed, Stats));
        false -> ok
    end,
    %% a reconcile pass finds it on every server
    {ok, _} = mailio_sync_mgr:reconcile_mailbox(Account, <<"INBOX">>),
    ?assertEqual([<<"stays">>], [maps:get(<<"subject">>, E) || E <- all_emails(Db)]),
    ?assertEqual(1, mailbox_total(Account)).

idle_push_ingests_new_mail(Config) ->
    P = ?config(profile, Config),
    Account = ?config(account, Config),
    Db = mailio_account:db_name(Account),
    {ok, _} = mailio_sync_mgr:sync_mailbox(Account, <<"INBOX">>),
    ok = mailio_sync_mgr:watch_inbox(Account),
    put_mail(P, [message(<<"pushed">>, <<"x\r\n">>)]),
    ok = wait_until(fun() -> length(all_emails(Db)) =:= 1 end, 15000),
    ?assertEqual([<<"pushed">>], [maps:get(<<"subject">>, E) || E <- all_emails(Db)]).

%%====================================================================
%% Helpers: servers
%%====================================================================

imap_cfg(P) ->
    Base = #{
        host => <<"127.0.0.1">>,
        port => maps:get(imap, P),
        tls => maps:get(plain_tls, P, false),
        credentials => {password, maps:get(user, P), maps:get(pass, P)}
    },
    case maps:get(verify, P) of
        none -> Base#{verify => verify_none};
        ca -> Base#{verify => verify_peer, cacertfile => mailio_servers:ca_file()}
    end.

with_server(P, Fun) ->
    {ok, C} = mailio_imap_conn:start_link(imap_cfg(P)),
    try
        Fun(C)
    after
        mailio_imap_conn:close(C)
    end.

run(C, Builder) ->
    case mailio_imap_conn:run(C, fun(T) -> {Builder(T), undefined} end) of
        {ok, Ev, {ok, _, _}} -> Ev;
        Other -> ct:fail({imap, Other})
    end.

purge(P) ->
    with_server(P, fun(C) ->
        Ev = run(C, fun(T) -> mailio_imap_proto:select(T, <<"INBOX">>) end),
        case lists:keyfind(exists, 1, Ev) of
            {exists, N} when N > 0 ->
                run(C, fun(T) ->
                    mailio_imap_proto:uid_store(T, {range, 1, '*'}, {add, true}, [<<"\\Deleted">>])
                end),
                run(C, fun(T) -> mailio_imap_proto:expunge(T) end);
            _ ->
                ok
        end
    end).

put_mail(P, Raws) ->
    with_server(P, fun(C) ->
        [
            case
                mailio_imap_conn:run(C, fun(T) ->
                    mailio_imap_proto:append(T, <<"INBOX">>, [], R)
                end)
            of
                {ok, _, {ok, _, _}} -> ok;
                Other -> ct:fail({append, Other})
            end
         || R <- Raws
        ]
    end).

server_cmd(P, Builder) ->
    with_server(P, fun(C) ->
        run(C, fun(T) -> mailio_imap_proto:select(T, <<"INBOX">>) end),
        run(C, Builder)
    end).

%% Delete the message with this subject on the server.
server_expunge(P, Subject) ->
    with_server(P, fun(C) ->
        run(C, fun(T) -> mailio_imap_proto:select(T, <<"INBOX">>) end),
        Ev = run(C, fun(T) ->
            mailio_imap_proto:uid_fetch(T, {range, 1, '*'}, [<<"UID">>, <<"BODY.PEEK[HEADER]">>])
        end),
        [Uid] = [
            proplists:get_value(uid, I)
         || {fetch, _, I} <- Ev,
            binary:match(
                proplists:get_value(<<"BODY[HEADER]">>, I, <<>>), <<"Subject: ", Subject/binary>>
            ) =/=
                nomatch
        ],
        run(C, fun(T) ->
            mailio_imap_proto:uid_store(T, {range, Uid, Uid}, {add, true}, [<<"\\Deleted">>])
        end),
        run(C, fun(T) -> mailio_imap_proto:expunge(T) end)
    end).

%%====================================================================
%% Helpers: the store
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

mailbox_total(Account) ->
    Db = mailio_account:db_name(Account),
    Query = #{where => [{path, [?MAILIO_NS, <<"imap_name">>], <<"INBOX">>}], limit => 1},
    {ok, [#{<<"id">> := <<?ID_MAILBOX, LocalId/binary>>} | _], _} =
        mailio_db:find(Db, Query, #{include_docs => true}),
    {ok, Mbx} = mailio_db:get(Db, <<?ID_MAILBOX, LocalId/binary>>),
    maps:get(<<"totalEmails">>, Mbx).

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
%% Helpers: messages
%%====================================================================

message(Subject, Body) ->
    mailio_mime_render:render(#{
        type => <<"text">>,
        subtype => <<"plain">>,
        charset => <<"utf-8">>,
        encoding => <<"7bit">>,
        headers => headers(Subject),
        body => Body
    }).

attachment_message(Subject, Text, Attachment) ->
    mailio_mime_render:render(#{
        type => <<"multipart">>,
        subtype => <<"mixed">>,
        headers => headers(Subject),
        parts => [
            #{
                type => <<"text">>,
                subtype => <<"plain">>,
                charset => <<"utf-8">>,
                encoding => <<"quoted-printable">>,
                body => Text
            },
            #{
                type => <<"application">>,
                subtype => <<"octet-stream">>,
                params => #{<<"name">> => <<"data.bin">>},
                encoding => <<"base64">>,
                disposition => <<"attachment">>,
                filename => <<"data.bin">>,
                body => Attachment
            }
        ]
    }).

headers(Subject) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    [
        {<<"From">>, <<"sender@example.test">>},
        {<<"To">>, <<"alice@example.test">>},
        {<<"Subject">>, Subject},
        {<<"Message-ID">>, <<"<", Id/binary, "@store-interop.test>">>},
        {<<"Date">>, <<"Mon, 23 Nov 2026 10:00:00 +0000">>},
        {<<"MIME-Version">>, <<"1.0">>}
    ].
