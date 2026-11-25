%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_imap_proto_tests).
-include_lib("eunit/include/eunit.hrl").

-define(P, mailio_imap_proto).

%%==== command encoders ====

login_quotes_test() ->
    ?assertEqual(
        <<"a1 LOGIN \"user\" \"p@ss\"\r\n">>,
        iolist_to_binary(?P:login(<<"a1">>, <<"user">>, <<"p@ss">>))
    ).

login_escapes_quotes_test() ->
    Out = iolist_to_binary(?P:login(<<"a1">>, <<"a\"b">>, <<"c\\d">>)),
    ?assertEqual(<<"a1 LOGIN \"a\\\"b\" \"c\\\\d\"\r\n">>, Out).

uid_fetch_test() ->
    Out = iolist_to_binary(
        ?P:uid_fetch(
            <<"a2">>,
            {range, 100, '*'},
            [<<"FLAGS">>, <<"UID">>, <<"BODY.PEEK[]">>]
        )
    ),
    ?assertEqual(<<"a2 UID FETCH 100:* (FLAGS UID BODY.PEEK[])\r\n">>, Out).

uid_store_test() ->
    Out = iolist_to_binary(?P:uid_store(<<"a3">>, 42, {add, true}, [<<"\\Seen">>])),
    ?assertEqual(<<"a3 UID STORE 42 +FLAGS.SILENT (\\Seen)\r\n">>, Out).

seqset_list_test() ->
    ?assertEqual(
        <<"1,3:5,9">>,
        iolist_to_binary(?P:format_seqset([1, {range, 3, 5}, 9]))
    ).

enable_test() ->
    ?assertEqual(
        <<"a1 ENABLE QRESYNC CONDSTORE\r\n">>,
        iolist_to_binary(?P:enable(<<"a1">>, [<<"QRESYNC">>, <<"CONDSTORE">>]))
    ).

select_qresync_test() ->
    ?assertEqual(
        <<"a2 SELECT \"INBOX\" (QRESYNC (1 6))\r\n">>,
        iolist_to_binary(?P:select_qresync(<<"a2">>, <<"INBOX">>, 1, 6))
    ).

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
            <<"* 1 FETCH (UID 9 INTERNALDATE \"17-Jul-2020 02:44:25 +0000\" MODSEQ (74))">>
        ),
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
    ?assertEqual([{41, 41}, {43, 45}], Uids).

continuation_test() ->
    ?assertEqual(
        {continuation, <<"go ahead">>},
        ?P:parse_response(<<"+ go ahead">>)
    ).

uid_set_parse_test() ->
    ?assertEqual([{1, 1}, {3, 5}, {9, 9}], ?P:parse_uid_ranges(<<"1,3:5,9">>)),
    ?assertEqual(
        {ok, [1, 3, 4, 5, 9]}, ?P:expand_uid_ranges(?P:parse_uid_ranges(<<"1,3:5,9">>), 100)
    ).

%% RFC 3501: the two ends of a range may come in either order.
uid_set_descending_range_test() ->
    ?assertEqual([{3, 5}], ?P:parse_uid_ranges(<<"5:3">>)),
    ?assertEqual({ok, [3, 4, 5]}, ?P:expand_uid_ranges(?P:parse_uid_ranges(<<"5:3">>), 10)).

uid_set_is_normalised_test() ->
    ?assertEqual([{1, 8}, {10, 10}], ?P:parse_uid_ranges(<<"10,3:8,1:5">>)).

%% A short set must not be able to allocate a huge list.
uid_set_expansion_is_bounded_test() ->
    Ranges = ?P:parse_uid_ranges(<<"1:4294967295">>),
    ?assertEqual([{1, 4294967295}], Ranges),
    ?assertEqual({error, too_many}, ?P:expand_uid_ranges(Ranges, 100000)),
    ?assertEqual(4294967295, ?P:uid_count(Ranges)),
    %% the parser itself stays small too
    {untagged, {vanished, false, R}} = ?P:parse_response(<<"* VANISHED 1:4294967295">>),
    ?assertEqual([{1, 4294967295}], R).

uid_set_garbage_does_not_crash_test() ->
    ?assertEqual([{7, 7}], ?P:parse_uid_ranges(<<"abc,1:x,7,:,,99999999999999">>)),
    ?assertEqual([], ?P:parse_uid_ranges(<<>>)).

%% A line that arrives in small pieces is framed in linear work: each call
%% resumes where the last one stopped.
fragmented_line_is_framed_in_linear_work_test() ->
    N = 20000,
    Line = binary:copy(<<"x">>, N),
    {reductions, R0} = process_info(self(), reductions),
    Result = feed(Line, <<>>, start, 1),
    {reductions, R1} = process_info(self(), reductions),
    ?assertEqual(done, Result),
    %% a rescan from the start each time would cost about N*N/2 steps
    ?assert(R1 - R0 < N * 60).

feed(<<>>, Buf, Scan, _Step) ->
    case ?P:read_response(<<Buf/binary, "\r\n">>, #{max_line => 100000}, Scan) of
        {ok, _, <<>>} -> done;
        Other -> Other
    end;
feed(<<B, Rest/binary>>, Buf, Scan, Step) ->
    Buf1 = <<Buf/binary, B>>,
    case ?P:read_response(Buf1, #{max_line => 100000}, Scan) of
        {more, Scan1} -> feed(Rest, Buf1, Scan1, Step);
        Other -> Other
    end.

%% A section key that carries a field list stays in one piece, and the data
%% lands under it, also with other literals in the same response.
fetch_header_fields_key_test() ->
    H = <<"From: a@b\r\nTo: c\r\n\r\n">>,
    T = <<"hello">>,
    Raw = iolist_to_binary(
        [
            "* 4 FETCH (UID 9 BODY[HEADER.FIELDS (FROM TO)] {",
            integer_to_list(byte_size(H)),
            "}\r\n",
            H,
            " BODY[1]<0> {",
            integer_to_list(byte_size(T)),
            "}\r\n",
            T,
            " FLAGS (\\Seen))\r\n"
        ]
    ),
    {ok, Line, <<>>} = mailio_imap_proto:read_response(Raw),
    {untagged, {fetch, 4, Items}} = mailio_imap_proto:parse_response(Line),
    ?assertEqual(9, proplists:get_value(uid, Items)),
    ?assertEqual(H, proplists:get_value(<<"BODY[HEADER.FIELDS (FROM TO)]">>, Items)),
    ?assertEqual(T, proplists:get_value(<<"BODY[1]<0>">>, Items)),
    ?assertEqual([<<"\\Seen">>], proplists:get_value(flags, Items)),
    ?assertEqual(undefined, proplists:get_value(<<"]">>, Items)).

fetch_header_fields_with_origin_test() ->
    H = <<"Subject: x\r\n\r\n">>,
    Raw = iolist_to_binary(
        [
            "* 1 FETCH (BODY[HEADER.FIELDS (SUBJECT)]<0> {",
            integer_to_list(byte_size(H)),
            "}\r\n",
            H,
            ")\r\n"
        ]
    ),
    {ok, Line, <<>>} = mailio_imap_proto:read_response(Raw),
    {untagged, {fetch, 1, Items}} = mailio_imap_proto:parse_response(Line),
    ?assertEqual(H, proplists:get_value(<<"BODY[HEADER.FIELDS (SUBJECT)]<0>">>, Items)).

%%==== framing across literals and packet boundaries ====

%% Frame a response that arrives one byte at a time. Resume = keep the state
%% the framer hands back; restart = ignore it and scan from the start each time.
frame_by_byte(Bin, Resume) -> frame_by_byte(Bin, <<>>, start, Resume, #{}).

frame_by_byte(<<>>, Buf, _St, _Mode, _Opts) ->
    {incomplete, Buf};
frame_by_byte(<<B, Rest/binary>>, Buf, St, Mode, Opts) ->
    Buf1 = <<Buf/binary, B>>,
    case ?P:read_response(Buf1, Opts, St) of
        {ok, Line, <<>>} ->
            {ok, Line};
        {more, St1} ->
            frame_by_byte(Rest, Buf1, next_state(Mode, St1), Mode, Opts);
        Other ->
            Other
    end.

next_state(resume, St) -> St;
next_state(restart, _) -> start.

reductions_of(Fun) ->
    {reductions, R0} = process_info(self(), reductions),
    Result = Fun(),
    {reductions, R1} = process_info(self(), reductions),
    {Result, R1 - R0}.

%% A continuation line after a literal that arrives in pieces: the work must
%% not grow with the square of the length.
fragmented_continuation_after_a_literal_is_linear_test() ->
    N = 20000,
    Resp = iolist_to_binary([
        <<"* 1 FETCH (BODY[] {5}\r\nabcde ">>, binary:copy(<<"x">>, N), <<")\r\n">>
    ]),
    Whole = binary:part(Resp, 0, byte_size(Resp) - 2),
    {Result, R} = reductions_of(fun() -> frame_by_byte(Resp, resume) end),
    ?assertEqual({ok, Whole}, Result),
    ?assert(R < byte_size(Resp) * 60).

%% Many literals in one response: earlier ones are not walked again each time.
many_literals_are_framed_in_linear_work_test_() ->
    {timeout, 60, fun many_literals_check/0}.

many_literals_check() ->
    Parts = [[<<" BODY[">>, integer_to_binary(I), <<"] {3}\r\nabc">>] || I <- lists:seq(1, 600)],
    Resp = iolist_to_binary([<<"* 1 FETCH (">>, Parts, <<")\r\n">>]),
    Whole = binary:part(Resp, 0, byte_size(Resp) - 2),
    {Result, Resumed} = reductions_of(fun() -> frame_by_byte(Resp, resume) end),
    ?assertEqual({ok, Whole}, Result),
    ?assert(Resumed < byte_size(Resp) * 60),
    %% the same input without resuming costs much more: the check can tell
    {Result2, Restarted} = reductions_of(fun() -> frame_by_byte(Resp, restart) end),
    ?assertEqual({ok, Whole}, Result2),
    ?assert(Restarted > Resumed * 5).

%% The same frame whatever the packet boundaries are.
framing_does_not_depend_on_packet_boundaries_test() ->
    Resp = <<"* 1 FETCH (BODY[1] {3}\r\nabc BODY[2] {2}\r\nde FLAGS (\\Seen))\r\n">>,
    Whole = binary:part(Resp, 0, byte_size(Resp) - 2),
    ?assertEqual({ok, Whole}, frame_by_byte(Resp, resume)),
    [
        begin
            <<A:K/binary, B/binary>> = Resp,
            {more, St} = ?P:read_response(A, #{}, start),
            ?assertEqual({ok, Whole, <<>>}, ?P:read_response(<<A/binary, B/binary>>, #{}, St))
        end
     || K <- lists:seq(1, byte_size(Resp) - 1)
    ].

%% max_line must mean the same whether the CR and the LF arrive together or not.
max_line_does_not_depend_on_where_the_packet_ends_test() ->
    Opts = #{max_line => 100},
    Line = binary:copy(<<"x">>, 100),
    Over = binary:copy(<<"x">>, 101),
    %% exactly at the limit: all of these are fine
    ?assertMatch({ok, Line, <<>>}, ?P:read_response(<<Line/binary, "\r\n">>, Opts, start)),
    ?assertMatch({more, _}, ?P:read_response(Line, Opts, start)),
    {more, S1} = ?P:read_response(<<Line/binary, "\r">>, Opts, start),
    ?assertMatch({ok, Line, <<>>}, ?P:read_response(<<Line/binary, "\r\n">>, Opts, S1)),
    %% one byte over: refused in every chunking
    ?assertEqual(
        {error, response_too_large}, ?P:read_response(<<Over/binary, "\r\n">>, Opts, start)
    ),
    ?assertEqual({error, response_too_large}, ?P:read_response(Over, Opts, start)),
    ?assertEqual({error, response_too_large}, ?P:read_response(<<Over/binary, "\r">>, Opts, start)).

%%==== VANISHED on the wire path ====

vanished_marker_is_case_insensitive_test() ->
    ?assertEqual(
        {untagged, {vanished, true, [{41, 41}, {43, 45}]}},
        ?P:parse_response(<<"* VANISHED (earlier) 41,43:45">>)
    ),
    ?assertEqual(
        {untagged, {vanished, true, [{7, 7}]}},
        ?P:parse_response(<<"* VANISHED (EaRlIeR) 7">>)
    ).

vanished_without_marker_test() ->
    ?assertEqual({untagged, {vanished, false, [{3, 3}]}}, ?P:parse_response(<<"* VANISHED 3">>)),
    ?assertEqual(
        {untagged, {vanished, false, [{1, 2}, {9, 9}]}}, ?P:parse_response(<<"* VANISHED 2:1,9">>)
    ).

%% A UID is 1*DIGIT without a sign and without a leading zero.
vanished_rejects_things_that_are_not_uids_test() ->
    [
        ?assertEqual({untagged, {vanished, false, []}}, ?P:parse_response(Wire))
     || Wire <- [
            <<"* VANISHED 01">>,
            <<"* VANISHED +2">>,
            <<"* VANISHED 007">>,
            <<"* VANISHED -3">>,
            <<"* VANISHED 0">>,
            <<"* VANISHED 4294967296">>
        ]
    ].
