%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_mime_render_tests).
-include_lib("eunit/include/eunit.hrl").

%%==== rendering ====

render_simple_leaf_test() ->
    Part = #{
        type => <<"text">>,
        subtype => <<"plain">>,
        charset => <<"utf-8">>,
        encoding => <<"7bit">>,
        body => <<"Hello">>
    },
    Bytes = mailio_mime_render:render(Part),
    P2 = mailio_mime:parse(Bytes),
    ?assertEqual(<<"text">>, mailio_mime:type(P2)),
    ?assertEqual(<<"utf-8">>, mailio_mime:charset(P2)),
    ?assertEqual(<<"Hello">>, mailio_mime:body(P2)).

render_base64_roundtrip_test() ->
    Body = <<"Binary ", 0, 1, 2, 255, " data">>,
    Part = #{
        type => <<"application">>,
        subtype => <<"octet-stream">>,
        encoding => <<"base64">>,
        body => Body
    },
    P2 = mailio_mime:parse(mailio_mime_render:render(Part)),
    ?assertEqual(Body, mailio_mime:body(P2)).

render_qp_roundtrip_test() ->
    Body = <<"café = test"/utf8>>,
    Part = #{
        type => <<"text">>,
        subtype => <<"plain">>,
        encoding => <<"quoted-printable">>,
        body => Body
    },
    P2 = mailio_mime:parse(mailio_mime_render:render(Part)),
    ?assertEqual(Body, mailio_mime:body(P2)).

render_multipart_roundtrip_test() ->
    Part = #{
        type => <<"multipart">>,
        subtype => <<"alternative">>,
        params => #{<<"boundary">> => <<"BOUND1">>},
        parts => [
            #{
                type => <<"text">>,
                subtype => <<"plain">>,
                encoding => <<"7bit">>,
                body => <<"plain">>
            },
            #{
                type => <<"text">>,
                subtype => <<"html">>,
                encoding => <<"7bit">>,
                body => <<"<b>html</b>">>
            }
        ]
    },
    P2 = mailio_mime:parse(mailio_mime_render:render(Part)),
    ?assert(mailio_mime:is_multipart(P2)),
    [A, B] = mailio_mime:parts(P2),
    ?assertEqual(<<"plain">>, mailio_mime:body(A)),
    ?assertEqual(<<"<b>html</b>">>, mailio_mime:body(B)).

%%==== outbound build ====

build_text_message_test() ->
    Msg = mailio_mime_render:build(
        #{
            from => [#{name => <<"Alice">>, email => <<"alice@x.com">>}],
            to => [#{name => undefined, email => <<"bob@y.com">>}],
            subject => <<"Hello">>,
            text => <<"Hi Bob">>
        }
    ),
    {H, _} = mailio_rfc5322:split(Msg),
    ?assertEqual(<<"Alice <alice@x.com>">>, mailio_rfc5322:header(<<"From">>, H)),
    ?assertEqual(<<"bob@y.com">>, mailio_rfc5322:header(<<"To">>, H)),
    ?assertEqual(<<"Hello">>, mailio_rfc5322:header(<<"Subject">>, H)),
    P = mailio_mime:parse(Msg),
    ?assertEqual(<<"Hi Bob">>, mailio_mime:body(P)).

build_non_ascii_subject_test() ->
    Msg = mailio_mime_render:build(
        #{
            from => [#{name => undefined, email => <<"a@x">>}],
            to => [#{name => undefined, email => <<"b@y">>}],
            subject => <<"Re: café"/utf8>>,
            text => <<"body">>
        }
    ),
    {H, _} = mailio_rfc5322:split(Msg),
    Subj = mailio_rfc5322:header(<<"Subject">>, H),
    %% Encoded on the wire, decodes back to the original.
    ?assertEqual(<<"Re: café"/utf8>>, mailio_rfc5322:decode_unstructured(Subj)).

build_html_alternative_test() ->
    Msg = mailio_mime_render:build(
        #{
            from => [#{name => undefined, email => <<"a@x">>}],
            to => [#{name => undefined, email => <<"b@y">>}],
            subject => <<"hi">>,
            text => <<"plain body">>,
            html => <<"<p>html body</p>">>
        }
    ),
    P = mailio_mime:parse(Msg),
    ?assertEqual(<<"multipart">>, mailio_mime:type(P)),
    ?assertEqual(<<"alternative">>, mailio_mime:subtype(P)),
    [Plain, Html] = mailio_mime:parts(P),
    ?assertEqual(<<"plain body">>, mailio_mime:body(Plain)),
    ?assertEqual(<<"<p>html body</p>">>, mailio_mime:body(Html)).

format_address_non_ascii_test() ->
    A = #{name => <<"Iñtërnâtiônàl"/utf8>>, email => <<"i@x.com">>},
    Formatted = mailio_mime_render:format_address(A),
    ?assertMatch(<<"=?UTF-8?B?", _/binary>>, Formatted).

%%====================================================================
%% What is generated follows the format (RFC 2047, 2045, 5322)
%%====================================================================

%% random text with characters of one to four bytes, spaces and tabs
random_text(N) ->
    Alphabet = [$a, $b, $\s, $\t, $=, $?, 233, 8364, 16#1F600, 16#4E2D, $., $_],
    unicode:characters_to_binary([
        lists:nth(rand:uniform(length(Alphabet)), Alphabet)
     || _ <- lists:seq(1, N)
    ]).

header_block(Mail) ->
    [Head, _] = binary:split(Mail, <<"\r\n\r\n">>),
    Head.

%% every encoded word is at most 75 characters, no line is longer than 998, and
%% the subject reads back as it was written
encoded_words_stay_within_75_and_round_trip_test() ->
    rand:seed(exsss, {1, 2, 3}),
    [
        begin
            Subject = random_text(rand:uniform(300)),
            Mail = mailio_mime_render:build(#{
                from => [#{email => <<"a@x">>}],
                to => [#{email => <<"b@y">>, name => random_text(rand:uniform(80))}],
                subject => Subject,
                text => <<"hi">>
            }),
            Head = header_block(Mail),
            Lines = binary:split(Head, <<"\r\n">>, [global]),
            [?assert(byte_size(L) =< 998) || L <- Lines],
            Words = [
                W
             || [W] <- element(
                    2, re:run(Head, <<"=\\?[^ ]*\\?=">>, [global, {capture, first, binary}])
                )
            ],
            [?assert(byte_size(W) =< 75) || W <- Words],
            [Subj] = [V || <<"Subject: ", V/binary>> <- unfold(Lines)],
            ?assertEqual(
                unicode:characters_to_binary(Subject), mailio_mime_decode:decode_words(Subj)
            )
        end
     || _ <- lists:seq(1, 200)
    ],
    ok.

unfold(Lines) ->
    lists:reverse(
        lists:foldl(
            fun
                (<<" ", Rest/binary>>, [Prev | Acc]) -> [<<Prev/binary, " ", Rest/binary>> | Acc];
                (L, Acc) -> [L | Acc]
            end,
            [],
            Lines
        )
    ).

%% a long ASCII subject is folded onto lines that are not too long
a_long_ascii_subject_is_folded_test() ->
    Subject = iolist_to_binary(lists:join(<<" ">>, lists:duplicate(400, <<"word">>))),
    Mail = mailio_mime_render:build(#{
        from => [#{email => <<"a@x">>}],
        to => [#{email => <<"b@y">>}],
        subject => Subject,
        text => <<"hi">>
    }),
    Lines = binary:split(header_block(Mail), <<"\r\n">>, [global]),
    [?assert(byte_size(L) =< 78) || L <- Lines],
    [Subj] = [V || <<"Subject: ", V/binary>> <- unfold(Lines)],
    ?assertEqual(Subject, Subj).

%% quoted-printable lines are at most 76 characters and decode to the text
quoted_printable_lines_stay_within_76_and_round_trip_test() ->
    rand:seed(exsss, {4, 5, 6}),
    [
        begin
            Text = iolist_to_binary(
                lists:join(<<"\r\n">>, [
                    random_text(rand:uniform(200))
                 || _ <- lists:seq(1, 1 + rand:uniform(4))
                ])
            ),
            Mail = mailio_mime_render:render(#{
                type => <<"text">>,
                subtype => <<"plain">>,
                charset => <<"utf-8">>,
                encoding => <<"quoted-printable">>,
                headers => [],
                body => Text
            }),
            [_, Body] = binary:split(Mail, <<"\r\n\r\n">>),
            [?assert(byte_size(L) =< 76) || L <- binary:split(Body, <<"\r\n">>, [global])],
            ?assertEqual(Text, mailio_mime_decode:decode_quoted_printable(Body))
        end
     || _ <- lists:seq(1, 200)
    ],
    ok.

%% a space or tab that ends a line is escaped, or a server may strip it
trailing_white_space_is_escaped_in_quoted_printable_test() ->
    Mail = mailio_mime_render:render(#{
        type => <<"text">>,
        subtype => <<"plain">>,
        encoding => <<"quoted-printable">>,
        headers => [],
        body => <<"end \r\ntab\t\r\nlast ">>
    }),
    [_, Body] = binary:split(Mail, <<"\r\n\r\n">>),
    ?assertEqual(<<"end=20\r\ntab=09\r\nlast=20">>, Body).

%% every built message has a Date, unless the caller gave one
build_adds_a_date_test() ->
    Spec = #{from => [#{email => <<"a@x">>}], to => [#{email => <<"b@y">>}], text => <<"hi">>},
    Head = header_block(mailio_mime_render:build(Spec#{date => 1795619045})),
    ?assertMatch({match, _}, re:run(Head, <<"\r\nDate: Wed, 25 Nov 2026 15:04:05 \\+0000\r\n">>)),
    {ok, _} = mailio_rfc5322:parse_date(<<"Wed, 25 Nov 2026 15:04:05 +0000">>),
    Now = header_block(mailio_mime_render:build(Spec)),
    ?assertMatch({match, _}, re:run(Now, <<"\r\nDate: ">>)),
    Given = header_block(
        mailio_mime_render:build(Spec#{
            headers => [{<<"Date">>, <<"Mon, 1 Jan 2024 00:00:00 +0000">>}]
        })
    ),
    ?assertEqual(1, length(binary:matches(Given, <<"Date: ">>))).
