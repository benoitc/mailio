%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_mime_tests).
-include_lib("eunit/include/eunit.hrl").

simple_text_test() ->
    Raw = <<"Content-Type: text/plain; charset=utf-8\r\n", "\r\n", "Hello world\r\n">>,
    P = mailio_mime:parse(Raw),
    ?assertEqual(<<"text">>, mailio_mime:type(P)),
    ?assertEqual(<<"plain">>, mailio_mime:subtype(P)),
    ?assertEqual(<<"utf-8">>, mailio_mime:charset(P)),
    ?assertEqual(<<"Hello world\r\n">>, mailio_mime:body(P)),
    ?assertNot(mailio_mime:is_multipart(P)).

default_content_type_test() ->
    %% No Content-Type defaults to text/plain.
    P = mailio_mime:parse(<<"Subject: x\r\n\r\nbody">>),
    ?assertEqual(<<"text">>, mailio_mime:type(P)),
    ?assertEqual(<<"plain">>, mailio_mime:subtype(P)),
    ?assertEqual(<<"body">>, mailio_mime:body(P)).

base64_leaf_test() ->
    Raw =
        <<"Content-Type: text/plain\r\n", "Content-Transfer-Encoding: base64\r\n", "\r\n",
            "SGVsbG8=\r\n">>,
    P = mailio_mime:parse(Raw),
    ?assertEqual(<<"Hello">>, mailio_mime:body(P)).

qp_leaf_test() ->
    Raw = <<"Content-Transfer-Encoding: quoted-printable\r\n", "\r\n", "caf=C3=A9">>,
    P = mailio_mime:parse(Raw),
    ?assertEqual(<<"café"/utf8>>, mailio_mime:body(P)).

multipart_two_parts_test() ->
    Raw =
        <<"Content-Type: multipart/alternative; boundary=\"BB\"\r\n", "\r\n", "preamble text\r\n",
            "--BB\r\n", "Content-Type: text/plain\r\n", "\r\n", "plain version\r\n", "--BB\r\n",
            "Content-Type: text/html\r\n", "\r\n", "<p>html version</p>\r\n", "--BB--\r\n",
            "epilogue\r\n">>,
    P = mailio_mime:parse(Raw),
    ?assert(mailio_mime:is_multipart(P)),
    Parts = mailio_mime:parts(P),
    ?assertEqual(2, length(Parts)),
    [Plain, Html] = Parts,
    ?assertEqual(<<"plain version">>, mailio_mime:body(Plain)),
    ?assertEqual(<<"text">>, mailio_mime:type(Html)),
    ?assertEqual(<<"html">>, mailio_mime:subtype(Html)),
    ?assertEqual(<<"<p>html version</p>">>, mailio_mime:body(Html)),
    ?assertEqual([], mailio_mime:defects(P)).

multipart_lf_only_test() ->
    Raw =
        <<"Content-Type: multipart/mixed; boundary=X\n", "\n", "--X\n",
            "Content-Type: text/plain\n", "\n", "one\n", "--X\n", "Content-Type: text/plain\n",
            "\n", "two\n", "--X--\n">>,
    P = mailio_mime:parse(Raw),
    [A, B] = mailio_mime:parts(P),
    ?assertEqual(<<"one">>, mailio_mime:body(A)),
    ?assertEqual(<<"two">>, mailio_mime:body(B)).

nested_multipart_test() ->
    Inner = <<"--IN\r\n", "Content-Type: text/plain\r\n\r\n", "deep text\r\n", "--IN--\r\n">>,
    Raw =
        <<"Content-Type: multipart/mixed; boundary=OUT\r\n\r\n", "--OUT\r\n",
            "Content-Type: multipart/alternative; boundary=IN\r\n\r\n", Inner/binary,
            "--OUT--\r\n">>,
    P = mailio_mime:parse(Raw),
    [Sub] = mailio_mime:parts(P),
    ?assert(mailio_mime:is_multipart(Sub)),
    [Leaf] = mailio_mime:parts(Sub),
    ?assertEqual(<<"deep text">>, mailio_mime:body(Leaf)),
    %% Exactly one leaf in the whole tree.
    ?assertEqual(
        [<<"deep text">>],
        [mailio_mime:body(L) || L <- mailio_mime:leaves(P)]
    ).

message_rfc822_test() ->
    Embedded = <<"From: inner@x\r\nSubject: Inner\r\n\r\ninner body">>,
    Raw = <<"Content-Type: message/rfc822\r\n\r\n", Embedded/binary>>,
    P = mailio_mime:parse(Raw),
    [Nested] = mailio_mime:parts(P),
    ?assertEqual(<<"Inner">>, mailio_mime:header(<<"subject">>, Nested)),
    ?assertEqual(<<"inner body">>, mailio_mime:body(Nested)).

attachment_detection_test() ->
    Raw =
        <<"Content-Type: application/pdf\r\n",
            "Content-Disposition: attachment; filename=\"report.pdf\"\r\n",
            "Content-Transfer-Encoding: base64\r\n\r\n",
            (base64:encode(<<"%PDF-1.4 fake">>))/binary, "\r\n">>,
    P = mailio_mime:parse(Raw),
    ?assert(mailio_mime:is_attachment(P)),
    ?assertEqual(<<"report.pdf">>, mailio_mime:filename(P)),
    ?assertEqual(<<"%PDF-1.4 fake">>, mailio_mime:body(P)).

missing_boundary_is_defect_test() ->
    Raw = <<"Content-Type: multipart/mixed\r\n\r\nno parts here">>,
    P = mailio_mime:parse(Raw),
    ?assert(lists:member(no_boundary, mailio_mime:defects(P))),
    ?assertEqual(<<"no parts here">>, mailio_mime:body(P)).

unclosed_boundary_is_defect_test() ->
    Raw =
        <<"Content-Type: multipart/mixed; boundary=Z\r\n\r\n", "--Z\r\n",
            "Content-Type: text/plain\r\n\r\n", "orphan\r\n">>,
    P = mailio_mime:parse(Raw),
    ?assert(lists:member(no_closing_boundary, mailio_mime:defects(P))),
    [Leaf] = mailio_mime:parts(P),
    %% With no closing delimiter to own it, the final CRLF stays as content.
    ?assertEqual(<<"orphan\r\n">>, mailio_mime:body(Leaf)).

empty_input_never_crashes_test() ->
    P = mailio_mime:parse(<<>>),
    ?assertEqual(<<"text">>, mailio_mime:type(P)),
    ?assertEqual(<<>>, mailio_mime:body(P)).

%%====================================================================
%% Part budget
%%====================================================================

count_parts(P) ->
    1 + lists:sum([count_parts(C) || C <- maps:get(parts, P, [])]).

flat_multipart(N) ->
    Parts = [<<"--b\r\nContent-Type: text/plain\r\n\r\np\r\n">> || _ <- lists:seq(1, N)],
    iolist_to_binary([
        <<"Content-Type: multipart/mixed; boundary=b\r\n\r\n">>, Parts, <<"--b--\r\n">>
    ]).

wide_message_stays_within_the_part_budget_test() ->
    P = mailio_mime:parse(flat_multipart(5000)),
    ?assertEqual(1000, count_parts(P)),
    ?assert(lists:member(too_many_parts, mailio_mime:defects(P))).

nested_message_is_bounded_too_test() ->
    Inner = flat_multipart(600),
    Outer = iolist_to_binary([
        <<"Content-Type: multipart/mixed; boundary=o\r\n\r\n">>,
        [
            [<<"--o\r\nContent-Type: message/rfc822\r\n\r\n">>, Inner, <<"\r\n">>]
         || _ <- lists:seq(1, 10)
        ],
        <<"--o--\r\n">>
    ]),
    ?assert(count_parts(mailio_mime:parse(Outer)) =< 1000).

message_under_the_budget_is_untouched_test() ->
    P = mailio_mime:parse(flat_multipart(20)),
    ?assertEqual(21, count_parts(P)),
    ?assertNot(lists:member(too_many_parts, mailio_mime:defects(P))).

part_budget_is_applied_before_building_the_segment_list_test() ->
    Raw = flat_multipart(20000),
    application:set_env(mailio, max_mime_parts, 4),
    Parent = self(),
    try
        {Pid, MRef} = spawn_monitor(fun() ->
            process_flag(max_heap_size, #{size => 50000, kill => true, error_logger => false}),
            Parent ! {parsed, count_parts(mailio_mime:parse(Raw))}
        end),
        receive
            {parsed, Count} ->
                erlang:demonitor(MRef, [flush]),
                ?assertEqual(4, Count);
            {'DOWN', MRef, process, Pid, Reason} ->
                error({parse_process_died, Reason})
        after 5000 ->
            exit(Pid, kill),
            ?assert(false)
        end
    after
        application:unset_env(mailio, max_mime_parts)
    end.
