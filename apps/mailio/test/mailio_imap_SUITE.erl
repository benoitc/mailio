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
    a_large_mailbox_is_listed_in_windows/1,
    flag_changes_are_listed_in_windows/1,
    a_reset_during_a_listing_is_reported/1,
    uids_are_listed_in_windows/1,
    a_mailbox_larger_than_one_command_may_collect_is_listed/1,
    a_missing_uidnext_still_lists/1,
    a_missing_uidnext_and_no_highest_uid_is_an_error/1,
    unsolicited_updates_are_not_listed_as_new_mail/1,
    windows_respect_the_line_limit/1,
    a_sparse_mailbox_has_a_bound_on_the_work/1,
    a_window_without_a_search_answer_is_an_error/1,
    a_search_answer_with_junk_is_an_error/1,
    an_explicit_empty_search_is_a_listing_of_nothing/1,
    a_mailbox_of_unknown_size_is_not_an_empty_one/1,
    search_answers_that_are_not_valid_are_errors/1,
    a_search_answer_outside_the_window_is_an_error/1,
    a_search_answer_with_modseq_is_accepted/1,
    a_uidnext_of_zero_is_not_trusted/1,
    a_uidnext_with_a_leading_zero_is_not_trusted/1,
    a_modseq_suffix_alone_is_an_error/1,
    a_highest_uid_of_zero_is_an_error/1,
    a_cursor_needs_a_valid_uidvalidity/1,
    a_cursor_without_a_known_uidvalidity_is_reset/1,
    a_listing_needs_a_valid_uidvalidity/1,
    a_uidnext_below_exists_is_an_error/1,
    an_update_does_not_hide_an_invalid_highest_uid/1,
    a_saved_cursor_with_nothing_known_is_reset/1,
    a_listing_that_misses_messages_is_an_error/1,
    a_listing_beyond_the_limit_stops/1,
    qresync_is_enabled_again_after_a_reconnect/1,
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
        a_large_mailbox_is_listed_in_windows,
        flag_changes_are_listed_in_windows,
        a_reset_during_a_listing_is_reported,
        uids_are_listed_in_windows,
        a_mailbox_larger_than_one_command_may_collect_is_listed,
        a_missing_uidnext_still_lists,
        a_missing_uidnext_and_no_highest_uid_is_an_error,
        unsolicited_updates_are_not_listed_as_new_mail,
        windows_respect_the_line_limit,
        a_sparse_mailbox_has_a_bound_on_the_work,
        a_window_without_a_search_answer_is_an_error,
        a_search_answer_with_junk_is_an_error,
        an_explicit_empty_search_is_a_listing_of_nothing,
        a_mailbox_of_unknown_size_is_not_an_empty_one,
        search_answers_that_are_not_valid_are_errors,
        a_search_answer_outside_the_window_is_an_error,
        a_search_answer_with_modseq_is_accepted,
        a_uidnext_of_zero_is_not_trusted,
        a_uidnext_with_a_leading_zero_is_not_trusted,
        a_modseq_suffix_alone_is_an_error,
        a_highest_uid_of_zero_is_an_error,
        a_cursor_needs_a_valid_uidvalidity,
        a_cursor_without_a_known_uidvalidity_is_reset,
        a_listing_needs_a_valid_uidvalidity,
        a_uidnext_below_exists_is_an_error,
        an_update_does_not_hide_an_invalid_highest_uid,
        a_saved_cursor_with_nothing_known_is_reset,
        a_listing_that_misses_messages_is_an_error,
        a_listing_beyond_the_limit_stops,
        qresync_is_enabled_again_after_a_reconnect,
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

%% Reconnect with other settings (the fake serves one connection at a time).
conn_with(Config, Extra) ->
    try
        mailio_imap:close(?config(conn, Config))
    catch
        _:_ -> ok
    end,
    Srv = ?config(srv, Config),
    Cfg = #{
        host => <<"127.0.0.1">>,
        port => mailio_fake_imap:port(Srv),
        tls => false,
        username => <<"u">>,
        password => <<"p">>
    },
    {ok, Conn} = mailio_imap:connect(maps:merge(Cfg, Extra)),
    Conn.

%% Read until the adapter says it is done, collecting the pages.
read_pages(Conn, State) -> read_pages(Conn, State, [], 0).

read_pages(Conn, State, Acc, N) when N < 100 ->
    case mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{}) of
        {ok, Changes, Next, done} -> {lists:append(lists:reverse([Changes | Acc])), Next, N + 1};
        {ok, Changes, Next, more} -> read_pages(Conn, Next, [Changes | Acc], N + 1)
    end.

a_large_mailbox_is_listed_in_windows(Config) ->
    Srv = ?config(srv, Config),
    [ok = mailio_fake_imap:deliver(Srv, integer_to_binary(N)) || N <- lists:seq(1, 3)],
    Conn = conn_with(Config, #{listing_window => 2}),
    {Changes, Final, Pages} = read_pages(Conn, initial),
    ?assertEqual([100, 101, 102, 103, 104], [U || {added, #{uid := U}} <- Changes]),
    ?assert(Pages >= 3),
    %% every message says which UIDVALIDITY it was listed under
    ?assertEqual([1], lists:usort([V || {added, #{uidvalidity := V}} <- Changes])),
    %% the last state is an ordinary one, and nothing is left to list
    ?assertEqual(105, mailio_imap_map:state_uidnext(Final)),
    {ok, [], _, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, Final, #{}).

flag_changes_are_listed_in_windows(Config) ->
    Srv = ?config(srv, Config),
    [ok = mailio_fake_imap:deliver(Srv, integer_to_binary(N)) || N <- lists:seq(1, 3)],
    %% the flag windows are for a server without QRESYNC: read as one without
    Conn = conn_with(Config, #{listing_window => 2, qresync => false}),
    {_, State, _} = read_pages(Conn, initial),
    [ok = mailio_fake_imap:set_flags(Srv, U, [<<"\\Seen">>]) || U <- [100, 101, 102, 103, 104]],
    {Changes, _Final, Pages} = read_pages(Conn, State),
    ?assertEqual([100, 101, 102, 103, 104], lists:sort([U || {updated, #{uid := U}} <- Changes])),
    ?assert(Pages >= 2).

%% The mailbox is recreated between two calls of one listing.
a_reset_during_a_listing_is_reported(Config) ->
    Srv = ?config(srv, Config),
    [ok = mailio_fake_imap:deliver(Srv, integer_to_binary(N)) || N <- lists:seq(1, 3)],
    Conn = conn_with(Config, #{listing_window => 2}),
    {ok, First, State, more} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    ?assertNotEqual([], First),
    ok = mailio_fake_imap:new_validity(Srv, [<<"Reborn">>]),
    ?assertMatch(
        {ok, [reset], _, done}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{})
    ).

uids_are_listed_in_windows(Config) ->
    Srv = ?config(srv, Config),
    [ok = mailio_fake_imap:deliver(Srv, integer_to_binary(N)) || N <- lists:seq(1, 3)],
    Conn = conn_with(Config, #{listing_window => 2}),
    ?assertEqual({ok, [100, 101, 102, 103, 104]}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% One command may collect only so much; a window keeps each one under it.
a_mailbox_larger_than_one_command_may_collect_is_listed(Config) ->
    Srv = ?config(srv, Config),
    [ok = mailio_fake_imap:deliver(Srv, integer_to_binary(N)) || N <- lists:seq(1, 14)],
    Conn = conn_with(Config, #{listing_window => 3, max_untagged => 10}),
    {Changes, _, _} = read_pages(Conn, initial),
    ?assertEqual(16, length([A || {added, _} = A <- Changes])),
    ?assertEqual({ok, lists:seq(100, 115)}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    %% a window the setting makes too wide is cut to what one command may collect
    mailio_imap:close(Conn),
    Whole = conn_with(Config, #{listing_window => 1000, max_untagged => 10}),
    {Changes2, _, _} = read_pages(Whole, initial),
    ?assertEqual(16, length([A || {added, _} = A <- Changes2])).

%% RFC 3501 allows a server to leave out UIDNEXT. The highest UID is then asked
%% for, and a mailbox is never taken for an empty one.
a_missing_uidnext_still_lists(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_option(Srv, no_uidnext, true),
    Conn = conn_with(Config, #{}),
    ?assertEqual({ok, [100, 101]}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    {ok, Changes, State, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    ?assertEqual([100, 101], [U || {added, #{uid := U}} <- Changes]),
    %% the state it leaves has a UIDNEXT: one past the highest UID seen
    ?assertEqual(102, mailio_imap_map:state_uidnext(State)).

a_missing_uidnext_and_no_highest_uid_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_option(Srv, no_uidnext, true),
    ok = mailio_fake_imap:set_option(Srv, fail_max_uid, true),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    ?assertMatch({error, _}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{})).

%% A flag update the server volunteers for a message outside the window is not
%% new mail.
unsolicited_updates_are_not_listed_as_new_mail(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:inject(Srv, [<<"* 7 FETCH (UID 9999 FLAGS (\\Seen))">>]),
    Conn = conn_with(Config, #{}),
    {ok, Changes, _, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    ?assertEqual([100, 101], [U || {added, #{uid := U}} <- Changes]),
    ?assertEqual([9999], [U || {updated, #{uid := U}} <- Changes]).

%% A window is sized by the limits of the connection, not only by the setting.
windows_respect_the_line_limit(Config) ->
    Srv = ?config(srv, Config),
    [ok = mailio_fake_imap:deliver(Srv, integer_to_binary(N)) || N <- lists:seq(1, 30)],
    %% a window of 100000 UIDs would be a 350 000 byte SEARCH line and 100000 FETCH lines
    Conn = conn_with(Config, #{listing_window => 100000, max_line => 200, max_untagged => 20}),
    ?assertEqual({ok, lists:seq(100, 131)}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    {Changes, _, _} = read_pages(Conn, initial),
    ?assertEqual(32, length([A || {added, _} = A <- Changes])).

%% UIDs that are far apart cost windows, not messages: the work has a bound.
a_sparse_mailbox_has_a_bound_on_the_work(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_uidnext(Srv, 100000),
    Conn = conn_with(Config, #{listing_window => 100, max_list_commands => 20}),
    ?assertEqual(
        {listing_too_sparse}, mailio_error_code(mailio_imap:list_uids(Conn, <<"INBOX">>))
    ),
    ?assertEqual(
        {listing_too_sparse},
        mailio_error_code(mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}))
    ),
    %% a bound that fits the mailbox lists it
    mailio_imap:close(Conn),
    Conn2 = conn_with(Config, #{listing_window => 100, max_list_commands => 2000}),
    ?assertEqual({ok, [100, 101]}, mailio_imap:list_uids(Conn2, <<"INBOX">>)).

mailio_error_code({error, #{detail := #{detail := Why}}}) -> {Why};
mailio_error_code({error, Why}) -> {Why}.

%% A tagged OK that carries no SEARCH line says nothing: it must not read as a
%% mailbox with no mail, which reconcile would answer by removing it all.
a_window_without_a_search_answer_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_search(Srv, none),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

a_search_answer_with_junk_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_search(Srv, junk),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% A window with no UIDs in it is answered by `* SEARCH' with nothing after it.
an_explicit_empty_search_is_a_listing_of_nothing(Config) ->
    Srv = ?config(srv, Config),
    [ok = mailio_fake_imap:expunge(Srv, U) || U <- [100, 101]],
    Conn = conn_with(Config, #{}),
    ?assertEqual({ok, []}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% Neither EXISTS nor UIDNEXT: the size is not known, which is not the same as
%% nothing in it.
a_mailbox_of_unknown_size_is_not_an_empty_one(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_option(Srv, no_uidnext, true),
    ok = mailio_fake_imap:set_option(Srv, no_exists, true),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    ?assertMatch({error, _}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{})).

search_answers_that_are_not_valid_are_errors(Config) ->
    Srv = ?config(srv, Config),
    Conn = conn_with(Config, #{}),
    [
        begin
            ok = mailio_fake_imap:set_search(Srv, Mode),
            ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>))
        end
     || Mode <- [bracket, bracket_between, junk, none, modseq_alone, modseq_glued, modseq_zero]
    ].

%% A number the window did not ask for is not an answer about the window.
a_search_answer_outside_the_window_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_search(Srv, outside),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% The CONDSTORE form of the answer is a valid one.
a_search_answer_with_modseq_is_accepted(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_search(Srv, modseq),
    Conn = conn_with(Config, #{}),
    ?assertEqual({ok, [100, 101]}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% UIDNEXT is a number from 1: 0 is not a value, so the highest UID is asked for.
a_uidnext_of_zero_is_not_trusted(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_uidnext(Srv, 0),
    Conn = conn_with(Config, #{}),
    ?assertEqual({ok, [100, 101]}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    {ok, Changes, _, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    ?assertEqual([100, 101], [U || {added, #{uid := U}} <- Changes]).

%% `UIDNEXT 01' is not a UIDNEXT: it must not read as 1, which would make the
%% mailbox look empty.
a_uidnext_with_a_leading_zero_is_not_trusted(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_uidnext(Srv, <<"01">>),
    Conn = conn_with(Config, #{}),
    ?assertEqual({ok, [100, 101]}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    {ok, Changes, _, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    ?assertEqual([100, 101], [U || {added, #{uid := U}} <- Changes]).

a_modseq_suffix_alone_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_search(Srv, modseq_alone),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% A highest UID of 0 is not a UID: it must not make the mailbox look empty.
a_highest_uid_of_zero_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_uidnext(Srv, <<"01">>),
    ok = mailio_fake_imap:set_option(Srv, zero_max_uid, true),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    ?assertMatch({error, _}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{})).

%% A cursor says which mailbox generation its UIDs belong to. Without a valid
%% UIDVALIDITY there is nothing to say, so no cursor is issued.
a_cursor_needs_a_valid_uidvalidity(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_option(Srv, bad_validity, true),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{})).

%% A cursor from before the validity was known cannot be compared with the
%% mailbox now: it is a reset, not "nothing changed".
a_cursor_without_a_known_uidvalidity_is_reset(Config) ->
    Conn = conn_with(Config, #{}),
    Old = mailio_imap_map:encode_state(#{
        uidvalidity => undefined, uidnext => 102, highestmodseq => 1, page => undefined
    }),
    ?assertMatch(
        {ok, [reset], _, done}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, Old, #{})
    ).

%% A listing is about one generation of the mailbox: without a valid UIDVALIDITY
%% it cannot be used to remove anything.
a_listing_needs_a_valid_uidvalidity(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_option(Srv, bad_validity, true),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% Two messages cannot have a highest UID of 0: UIDNEXT 1 contradicts EXISTS 2.
a_uidnext_below_exists_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_uidnext(Srv, 1),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)),
    ?assertMatch({error, _}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{})).

%% An update for another message in the same answer does not make the invalid
%% UID of the last one a valid highest UID.
an_update_does_not_hide_an_invalid_highest_uid(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_uidnext(Srv, <<"01">>),
    ok = mailio_fake_imap:set_option(Srv, zero_max_uid, true),
    ok = mailio_fake_imap:inject(Srv, [<<"* 1 FETCH (UID 100 FLAGS (\\Seen))">>]),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% Only the literal `initial' is a first read. A saved cursor that knows nothing
%% cannot say its UIDs are still the same messages.
a_saved_cursor_with_nothing_known_is_reset(Config) ->
    Conn = conn_with(Config, #{}),
    Old = mailio_imap_map:encode_state(#{
        uidvalidity => undefined,
        uidnext => undefined,
        highestmodseq => undefined,
        page => undefined
    }),
    ?assertMatch(
        {ok, [reset], _, done}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, Old, #{})
    ),
    ?assertMatch(
        {ok, [{added, _} | _], _, done},
        mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{})
    ).

%% The server says two messages and the search finds none: the listing does not
%% agree with the mailbox, and is not an inventory of it.
a_listing_that_misses_messages_is_an_error(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_search(Srv, empty),
    Conn = conn_with(Config, #{}),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>)).

%% A mailbox with more messages than the caller accepts is refused as it is read.
a_listing_beyond_the_limit_stops(Config) ->
    Conn = conn_with(Config, #{}),
    ?assertMatch({ok, [100, 101]}, mailio_imap:list_uids(Conn, <<"INBOX">>, #{max => 2})),
    ?assertMatch({error, _}, mailio_imap:list_uids(Conn, <<"INBOX">>, #{max => 1})).

%% A server that wants ENABLE QRESYNC on every connection: a read after the
%% connection was lost and made again still works.
qresync_is_enabled_again_after_a_reconnect(Config) ->
    Srv = ?config(srv, Config),
    ok = mailio_fake_imap:set_option(Srv, enforce_enable, true),
    Conn = conn_with(Config, #{}),
    {ok, _, S1, done} = mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, initial, #{}),
    ?assertMatch({ok, _, _, done}, mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, S1, #{})),
    ok = mailio_fake_imap:drop_connection(Srv),
    ?assertMatch({ok, _, _, done}, retry_until_connected(Conn, S1, 50)).

retry_until_connected(Conn, State, 0) ->
    mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{});
retry_until_connected(Conn, State, N) ->
    case mailio_imap:fetch_changes_since(Conn, <<"INBOX">>, State, #{}) of
        {error, _} ->
            timer:sleep(200),
            retry_until_connected(Conn, State, N - 1);
        Ok ->
            Ok
    end.
