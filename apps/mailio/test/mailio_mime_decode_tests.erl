%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_mime_decode_tests).
-include_lib("eunit/include/eunit.hrl").

qp_basic_test() ->
    ?assertEqual(
        <<"Hello World">>,
        mailio_mime_decode:decode_quoted_printable(<<"Hello World">>)
    ),
    ?assertEqual(
        <<"a=b">>,
        mailio_mime_decode:decode_quoted_printable(<<"a=3Db">>)
    ).

qp_soft_break_test() ->
    ?assertEqual(
        <<"abcdef">>,
        mailio_mime_decode:decode_quoted_printable(<<"abc=\r\ndef">>)
    ),
    ?assertEqual(
        <<"abcdef">>,
        mailio_mime_decode:decode_quoted_printable(<<"abc=\ndef">>)
    ).

qp_underscore_literal_test() ->
    %% In body mode underscore stays underscore.
    ?assertEqual(
        <<"a_b">>,
        mailio_mime_decode:decode_quoted_printable(<<"a_b">>)
    ).

qp_lenient_bad_hex_test() ->
    ?assertEqual(
        <<"=zz">>,
        mailio_mime_decode:decode_quoted_printable(<<"=zz">>)
    ).

base64_basic_test() ->
    ?assertEqual(<<"Hello">>, mailio_mime_decode:decode_base64(<<"SGVsbG8=">>)).

base64_with_newlines_test() ->
    ?assertEqual(
        <<"Hello World">>,
        mailio_mime_decode:decode_base64(<<"SGVsbG8g\r\nV29ybGQ=">>)
    ).

base64_missing_padding_test() ->
    ?assertEqual(<<"Hello">>, mailio_mime_decode:decode_base64(<<"SGVsbG8">>)).

words_b_encoded_test() ->
    %% =?utf-8?B?...?= of "Héllo"
    Enc = <<"=?utf-8?B?", (base64:encode(<<"Héllo"/utf8>>))/binary, "?=">>,
    ?assertEqual(<<"Héllo"/utf8>>, mailio_mime_decode:decode_words(Enc)).

words_q_encoded_test() ->
    ?assertEqual(
        <<"Keith Moore">>,
        mailio_mime_decode:decode_words(<<"=?US-ASCII?Q?Keith_Moore?=">>)
    ).

words_q_latin1_test() ->
    %% =?ISO-8859-1?Q?=E9?= is é
    ?assertEqual(
        <<"é"/utf8>>,
        mailio_mime_decode:decode_words(<<"=?ISO-8859-1?Q?=E9?=">>)
    ).

words_adjacent_ws_removed_test() ->
    %% RFC 2047 s6.2: whitespace between two encoded-words is removed.
    In = <<"=?ISO-8859-1?Q?a?= =?ISO-8859-1?Q?b?=">>,
    ?assertEqual(<<"ab">>, mailio_mime_decode:decode_words(In)).

words_mixed_text_test() ->
    In = <<"Subject is =?US-ASCII?Q?clear?= here">>,
    ?assertEqual(
        <<"Subject is clear here">>,
        mailio_mime_decode:decode_words(In)
    ).

words_plain_passthrough_test() ->
    ?assertEqual(
        <<"no encoded words">>,
        mailio_mime_decode:decode_words(<<"no encoded words">>)
    ).

charset_cp1252_test() ->
    %% 0x80 in cp1252 is the euro sign.
    ?assertEqual(<<"€"/utf8>>, mailio_mime_decode:to_utf8(<<16#80>>, <<"windows-1252">>)).

charset_latin1_test() ->
    ?assertEqual(<<"é"/utf8>>, mailio_mime_decode:to_utf8(<<16#E9>>, <<"iso-8859-1">>)).

charset_utf8_passthrough_test() ->
    ?assertEqual(<<"€"/utf8>>, mailio_mime_decode:to_utf8(<<"€"/utf8>>, <<"utf-8">>)).

transfer_dispatch_test() ->
    ?assertEqual(<<"Hi">>, mailio_mime_decode:decode_transfer(<<"SGk=">>, <<"base64">>)),
    ?assertEqual(
        <<"a b">>, mailio_mime_decode:decode_transfer(<<"a=20b">>, <<"quoted-printable">>)
    ),
    ?assertEqual(<<"raw">>, mailio_mime_decode:decode_transfer(<<"raw">>, <<"7bit">>)),
    ?assertEqual(<<"raw">>, mailio_mime_decode:decode_transfer(<<"raw">>, undefined)).
