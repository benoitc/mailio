%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc IMAP adapter integration suite (against the scripted fake server).
-module(mailio_imap_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    connect_and_capabilities/1,
    list_mailboxes/1,
    fetch_changes_initial/1,
    fetch_message/1,
    set_keywords/1,
    reads_open_read_only/1,
    unchanged_mailbox_reports_nothing/1,
    a_refused_listing_is_an_error/1,
    max_vanished_can_only_be_lowered/1,
    a_message_is_fetched_only_under_its_uidvalidity/1,
    writes_open_read_write/1
]).

all() ->
    [
        connect_and_capabilities,
        list_mailboxes,
        fetch_changes_initial,
        fetch_message,
        set_keywords,
        reads_open_read_only,
        unchanged_mailbox_reports_nothing,
        a_refused_listing_is_an_error,
        max_vanished_can_only_be_lowered,
        a_message_is_fetched_only_under_its_uidvalidity,
        writes_open_read_write
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Srv = mailio_fake_imap:start(),
    Cfg = #{
        host => <<"127.0.0.1">>,
        port => mailio_fake_imap:port(Srv),
        tls => false,
        username => <<"u">>,
        password => <<"p">>
    },
    {ok, Conn} = mailio_imap:connect(Cfg),
    [{srv, Srv}, {conn, Conn} | Config].

end_per_testcase(_TC, Config) ->
    try
        mailio_imap:close(?config(conn, Config))
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

connect_and_capabilities(Config) ->
    Conn = ?config(conn, Config),
    Caps = mailio_imap:capabilities(Conn),
    ?assert(maps:get(idle, Caps)),
    ?assert(maps:get(condstore, Caps)),
    ?assert(maps:get(qresync, Caps)),
    ?assert(maps:get(move, Caps)).

list_mailboxes(Config) ->
    Conn = ?config(conn, Config),
    {ok, Mailboxes} = mailio_imap:list_mailboxes(Conn),
    Roles = [{maps:get(name, M), maps:get(role, M)} || M <- Mailboxes],
    ?assertEqual(inbox, proplists:get_value(<<"INBOX">>, Roles)),
    ?assertEqual(sent, proplists:get_value(<<"Sent">>, Roles)),
    ?assertEqual(archive, proplists:get_value(<<"Archive">>, Roles)).

fetch_changes_initial(Config) ->
    Conn = ?config(conn, Config),
    {ok, Changes, NewState, done} =
        mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    Added = [C || {added, _} = C <- Changes],
    ?assertEqual(2, length(Added)),
    Uids = lists:sort([maps:get(uid, M) || {added, M} <- Added]),
    ?assertEqual([100, 101], Uids),

    %% Message 100 carries \Seen -> $seen keyword.
    [M100] = [M || {added, M} <- Added, maps:get(uid, M) =:= 100],
    ?assert(lists:member(?KW_SEEN, maps:get(keywords, M100))),

    %% Cursor reflects the SELECT response.
    ?assertEqual(1, mailio_imap_map:state_uidvalidity(NewState)),
    ?assertEqual(102, mailio_imap_map:state_uidnext(NewState)),
    ?assertEqual(6, mailio_imap_map:state_modseq(NewState)).

fetch_message(Config) ->
    Conn = ?config(conn, Config),
    Self = self(),
    Sink = fun(Bytes) ->
        Self ! {body, iolist_to_binary(Bytes)},
        ok
    end,
    {ok, #{size := Size}} = mailio_imap:fetch_message(Conn, <<"INBOX">>, 100, Sink),
    Body =
        receive
            {body, B} -> B
        after 2000 -> error(no_body)
        end,
    ?assertEqual(Size, byte_size(Body)),
    ?assert(binary:match(Body, <<"First message">>) =/= nomatch),
    %% Round-trips through the MIME parser.
    Parsed = mailio_mime:parse(Body),
    ?assertEqual(<<"First message">>, mailio_mime:header(<<"subject">>, Parsed)).

set_keywords(Config) ->
    Conn = ?config(conn, Config),
    Srv = ?config(srv, Config),
    ok = mailio_imap:set_keywords(Conn, <<"INBOX">>, 101, [?KW_FLAGGED], []),
    Flags = mailio_fake_imap:last_flags(Srv, 101),
    ?assert(lists:member(<<"\\Flagged">>, Flags)).

%% Opening a mailbox to read it must not take write access.
reads_open_read_only(Config) ->
    Conn = ?config(conn, Config),
    Srv = ?config(srv, Config),
    {ok, _, State, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    %% the QRESYNC path as well
    {ok, _, _, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{}),
    {ok, _} = mailio_imap:fetch_message(Conn, <<"INBOX">>, 100, fun(_) -> ok end),
    {ok, _} = mailio_imap:list_uids(Conn, <<"INBOX">>),
    Cmds = mailio_fake_imap:commands(Srv),
    ?assertEqual([], [C || C <- Cmds, binary:match(C, <<"SELECT ">>) =/= nomatch]),
    ?assertNotEqual([], [C || C <- Cmds, binary:match(C, <<"EXAMINE ">>) =/= nomatch]).

writes_open_read_write(Config) ->
    Conn = ?config(conn, Config),
    Srv = ?config(srv, Config),
    ok = mailio_imap:set_keywords(Conn, <<"INBOX">>, 101, [?KW_FLAGGED], []),
    Cmds = mailio_fake_imap:commands(Srv),
    ?assertNotEqual([], [C || C <- Cmds, binary:match(C, <<"SELECT ">>) =/= nomatch]).

%% `N:*' matches the highest message even when N is past it. A poll of a
%% mailbox that did not change must not report that message again.
unchanged_mailbox_reports_nothing(Config) ->
    Conn = ?config(conn, Config),
    {ok, [_, _], State, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    {ok, [], State2, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{}),
    {ok, [], _, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State2, #{}).

%% A listing the server answers with NO must be an error, never an empty list
%% with a new cursor: the mail it did not list would not be asked for again.
a_refused_listing_is_an_error(Config) ->
    Conn = ?config(conn, Config),
    Srv = ?config(srv, Config),
    {ok, _, State, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    ok = mailio_fake_imap:deliver(Srv, <<"More mail">>),
    ok = mailio_fake_imap:set_failure(Srv, meta, true),
    ?assertMatch({error, _}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{})),
    ?assertMatch({error, _}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{})),
    ok = mailio_fake_imap:set_failure(Srv, meta, false),
    {ok, Changes, _, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{}),
    ?assertEqual([102], [Uid || {added, #{uid := Uid}} <- Changes]).

max_vanished_can_only_be_lowered(Config) ->
    Srv = ?config(srv, Config),
    %% the fake server serves one connection at a time
    mailio_imap:close(?config(conn, Config)),
    Cfg = #{
        host => <<"127.0.0.1">>,
        port => mailio_fake_imap:port(Srv),
        tls => false,
        username => <<"u">>,
        password => <<"p">>
    },
    Max = fun(Extra) ->
        {ok, C} = mailio_imap:connect(maps:merge(Cfg, Extra)),
        V = maps:get(max_vanished, C),
        mailio_imap:close(C),
        V
    end,
    ?assertEqual(100000, Max(#{})),
    ?assertEqual(100000, Max(#{max_vanished => 50000000})),
    ?assertEqual(5, Max(#{max_vanished => 5})).

a_message_is_fetched_only_under_its_uidvalidity(Config) ->
    Conn = ?config(conn, Config),
    Srv = ?config(srv, Config),
    Sink = fun(_) -> ok end,
    ?assertMatch(
        {ok, _},
        mailio_imap:fetch_message(Conn, <<"INBOX">>, 100, Sink, #{uidvalidity => 1})
    ),
    ok = mailio_fake_imap:new_validity(Srv, [<<"Other one">>]),
    {error, Err} = mailio_imap:fetch_message(Conn, <<"INBOX">>, 100, Sink, #{uidvalidity => 1}),
    ?assertEqual(imap_uidvalidity_changed, mailio_error:code({error, Err})),
    %% without the option the old behaviour stays
    ?assertMatch({ok, _}, mailio_imap:fetch_message(Conn, <<"INBOX">>, 100, Sink)).
