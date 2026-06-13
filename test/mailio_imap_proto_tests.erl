-module(mailio_imap_proto_tests).
-include_lib("eunit/include/eunit.hrl").

-define(P, mailio_imap_proto).

%%==== command encoders ====

login_quotes_test() ->
    ?assertEqual(<<"a1 LOGIN \"user\" \"p@ss\"\r\n">>,
                 iolist_to_binary(?P:login(<<"a1">>, <<"user">>, <<"p@ss">>))).

login_escapes_quotes_test() ->
    Out = iolist_to_binary(?P:login(<<"a1">>, <<"a\"b">>, <<"c\\d">>)),
    ?assertEqual(<<"a1 LOGIN \"a\\\"b\" \"c\\\\d\"\r\n">>, Out).

uid_fetch_test() ->
    Out = iolist_to_binary(?P:uid_fetch(<<"a2">>, {range, 100, '*'},
                                        [<<"FLAGS">>, <<"UID">>, <<"BODY.PEEK[]">>])),
    ?assertEqual(<<"a2 UID FETCH 100:* (FLAGS UID BODY.PEEK[])\r\n">>, Out).

uid_store_test() ->
    Out = iolist_to_binary(?P:uid_store(<<"a3">>, 42, {add, true}, [<<"\\Seen">>])),
    ?assertEqual(<<"a3 UID STORE 42 +FLAGS.SILENT (\\Seen)\r\n">>, Out).

seqset_list_test() ->
    ?assertEqual(<<"1,3:5,9">>,
                 iolist_to_binary(?P:format_seqset([1, {range, 3, 5}, 9]))).

append_prefix_test() ->
    {Prefix, Data} = ?P:append(<<"a4">>, <<"Sent">>, [<<"\\Seen">>], <<"hello">>),
    ?assertEqual(<<"a4 APPEND \"Sent\" (\\Seen) {5}\r\n">>, iolist_to_binary(Prefix)),
    ?assertEqual(<<"hello\r\n">>, Data).

%%==== framing (read_response) ====

frame_simple_test() ->
    {ok, Line, Rest} = ?P:read_response(<<"* OK hello\r\nNEXT">>),
    ?assertEqual(<<"* OK hello">>, Line),
    ?assertEqual(<<"NEXT">>, Rest).

frame_incomplete_test() ->
    ?assertEqual(more, ?P:read_response(<<"* OK hel">>)).

frame_literal_test() ->
    %% Literal spans what would otherwise be a line boundary.
    Buf = <<"* 1 FETCH (BODY[] {11}\r\nHello\r\nXYZ)\r\nTAIL">>,
    {ok, Line, Rest} = ?P:read_response(Buf),
    ?assertEqual(<<"* 1 FETCH (BODY[] {11}\r\nHello\r\nXYZ)">>, Line),
    ?assertEqual(<<"TAIL">>, Rest).

frame_literal_incomplete_test() ->
    %% Literal announces 11 bytes but only 5 present.
    ?assertEqual(more, ?P:read_response(<<"* 1 FETCH (BODY[] {11}\r\nHello">>)).

%%==== greeting / capability ====

greeting_test() ->
    {untagged, {status_resp, ok, Code, Text}} =
        ?P:parse_response(<<"* OK [CAPABILITY IMAP4rev1 IDLE] Dovecot ready.">>),
    ?assertMatch({<<"CAPABILITY">>, _}, Code),
    ?assertEqual(<<"Dovecot ready.">>, Text).

capability_test() ->
    {untagged, {capability, Caps}} =
        ?P:parse_response(<<"* CAPABILITY IMAP4rev1 IDLE CONDSTORE QRESYNC">>),
    ?assert(lists:member(<<"IDLE">>, Caps)),
    ?assert(lists:member(<<"QRESYNC">>, Caps)).

%%==== select responses ====

exists_test() ->
    ?assertEqual({untagged, {exists, 23}}, ?P:parse_response(<<"* 23 EXISTS">>)).

flags_test() ->
    {untagged, {flags, Flags}} =
        ?P:parse_response(<<"* FLAGS (\\Answered \\Seen \\Draft)">>),
    ?assertEqual([<<"\\Answered">>, <<"\\Seen">>, <<"\\Draft">>], Flags).

uidvalidity_code_test() ->
    {untagged, {status_resp, ok, Code, _}} =
        ?P:parse_response(<<"* OK [UIDVALIDITY 3857529045] UIDs valid">>),
    ?assertEqual({<<"UIDVALIDITY">>, [{number, 3857529045}]}, Code).

permanentflags_test() ->
    {untagged, {status_resp, ok, {Name, [{list, Flags}]}, _}} =
        ?P:parse_response(<<"* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] limited">>),
    ?assertEqual(<<"PERMANENTFLAGS">>, Name),
    ?assertEqual([{atom, <<"\\Deleted">>}, {atom, <<"\\Seen">>}, {atom, <<"\\*">>}], Flags).

highestmodseq_test() ->
    {untagged, {status_resp, ok, {<<"HIGHESTMODSEQ">>, [{number, 715}]}, _}} =
        ?P:parse_response(<<"* OK [HIGHESTMODSEQ 715] Highest">>),
    ok.

tagged_ok_readwrite_test() ->
    {tagged, <<"a5">>, ok, #{code := Code, text := Text}} =
        ?P:parse_response(<<"a5 OK [READ-WRITE] SELECT completed">>),
    ?assertEqual({<<"READ-WRITE">>}, Code),
    ?assertEqual(<<"SELECT completed">>, Text).

tagged_no_test() ->
    {tagged, <<"a6">>, no, #{text := Text}} =
        ?P:parse_response(<<"a6 NO [AUTHENTICATIONFAILED] Invalid credentials">>),
    ?assertEqual(<<"Invalid credentials">>, Text).

%%==== LIST / STATUS / SEARCH ====

list_test() ->
    {untagged, {list, Attrs, Delim, Name}} =
        ?P:parse_response(<<"* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Items\"">>),
    ?assertEqual([<<"\\HasNoChildren">>, <<"\\Sent">>], Attrs),
    ?assertEqual(<<"/">>, Delim),
    ?assertEqual(<<"Sent Items">>, Name).

list_nil_delim_test() ->
    {untagged, {list, _Attrs, Delim, Name}} =
        ?P:parse_response(<<"* LIST (\\Noselect) NIL \"\"">>),
    ?assertEqual(nil, Delim),
    ?assertEqual(<<>>, Name).

status_test() ->
    {untagged, {status, Mbox, Items}} =
        ?P:parse_response(<<"* STATUS \"INBOX\" (MESSAGES 231 UIDNEXT 44292)">>),
    ?assertEqual(<<"INBOX">>, Mbox),
    ?assertEqual(231, proplists:get_value(<<"MESSAGES">>, Items)),
    ?assertEqual(44292, proplists:get_value(<<"UIDNEXT">>, Items)).

search_test() ->
    {untagged, {search, Uids}} =
        ?P:parse_response(<<"* SEARCH 2 84 882 1024">>),
    ?assertEqual([2, 84, 882, 1024], Uids).

%%==== FETCH ====

fetch_flags_uid_test() ->
    {untagged, {fetch, 12, Items}} =
        ?P:parse_response(<<"* 12 FETCH (FLAGS (\\Seen) UID 4827 RFC822.SIZE 4326)">>),
    ?assertEqual([<<"\\Seen">>], proplists:get_value(flags, Items)),
    ?assertEqual(4827, proplists:get_value(uid, Items)),
    ?assertEqual(4326, proplists:get_value(size, Items)).

fetch_internaldate_modseq_test() ->
    {untagged, {fetch, 1, Items}} =
        ?P:parse_response(
            <<"* 1 FETCH (UID 9 INTERNALDATE \"17-Jul-2020 02:44:25 +0000\" MODSEQ (74))">>),
    ?assertEqual(9, proplists:get_value(uid, Items)),
    ?assertEqual(<<"17-Jul-2020 02:44:25 +0000">>, proplists:get_value(internaldate, Items)),
    ?assertEqual(74, proplists:get_value(modseq, Items)).

fetch_body_literal_test() ->
    %% Frame then parse a FETCH carrying a literal body.
    Body = <<"From: a@b\r\n\r\nhi">>,
    Len = integer_to_binary(byte_size(Body)),
    Raw = <<"* 7 FETCH (UID 30 BODY[] {", Len/binary, "}\r\n", Body/binary, ")">>,
    {untagged, {fetch, 7, Items}} = ?P:parse_response(Raw),
    ?assertEqual(30, proplists:get_value(uid, Items)),
    ?assertEqual(Body, proplists:get_value(body, Items)).

%%==== VANISHED / continuation ====

vanished_test() ->
    {untagged, {vanished, true, Uids}} =
        ?P:parse_response(<<"* VANISHED (EARLIER) 41,43:45">>),
    ?assertEqual([41, 43, 44, 45], Uids).

continuation_test() ->
    ?assertEqual({continuation, <<"go ahead">>},
                 ?P:parse_response(<<"+ go ahead">>)).

uid_set_parse_test() ->
    ?assertEqual([1, 3, 4, 5, 9], ?P:parse_uid_set(<<"1,3:5,9">>)).
