%%% @doc IMAP adapter integration suite (against the scripted fake server).
-module(mailio_imap_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([connect_and_capabilities/1,
         list_mailboxes/1,
         fetch_changes_initial/1,
         fetch_message/1,
         set_keywords/1]).

all() ->
    [connect_and_capabilities,
     list_mailboxes,
     fetch_changes_initial,
     fetch_message,
     set_keywords].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Srv = mailio_fake_imap:start(),
    Cfg = #{host => <<"127.0.0.1">>, port => mailio_fake_imap:port(Srv),
            tls => false, username => <<"u">>, password => <<"p">>},
    {ok, Conn} = mailio_imap:connect(Cfg),
    [{srv, Srv}, {conn, Conn} | Config].

end_per_testcase(_TC, Config) ->
    try mailio_imap:close(?config(conn, Config)) catch _:_ -> ok end,
    try mailio_fake_imap:stop(?config(srv, Config)) catch _:_ -> ok end,
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
    Sink = fun(Bytes) -> Self ! {body, iolist_to_binary(Bytes)}, ok end,
    {ok, #{size := Size}} = mailio_imap:fetch_message(Conn, <<"INBOX">>, 100, Sink),
    Body = receive {body, B} -> B after 2000 -> error(no_body) end,
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
