%%% @doc Corpus-driven compliance suite (M2).
%%%
%%% Each case loads a real `.eml' fixture from the data directory and
%%% asserts the parse result. The fixtures encode the hard scenarios that
%%% the established libraries (gen_smtp, CPython email, MimeKit) regression
%%% test: RFC 2047 multi-charset subjects, deep multipart nesting with an
%%% embedded message/rfc822, windows-1252 + quoted-printable bodies, RFC
%%% 2231 split/extended parameters, and 76-column-wrapped base64. See
%%% test/VENDORED_TESTS.md for provenance and the external corpora to add.
-module(mailio_mime_corpus_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    rfc2047_multicharset_subject/1,
    nested_multipart_with_message/1,
    cp1252_quoted_printable/1,
    rfc2231_split_extended_filename/1,
    wrapped_base64_body/1
]).

all() ->
    [
        rfc2047_multicharset_subject,
        nested_multipart_with_message,
        cp1252_quoted_printable,
        rfc2231_split_extended_filename,
        wrapped_base64_body
    ].

load(Config, Name) ->
    Path = filename:join(?config(data_dir, Config), Name),
    {ok, Bin} = file:read_file(Path),
    Bin.

%%====================================================================

rfc2047_multicharset_subject(Config) ->
    Raw = load(Config, "rfc2047_subject.eml"),
    {H, _} = mailio_rfc5322:split(Raw),
    Subject = mailio_rfc5322:decode_unstructured(
        mailio_rfc5322:header(<<"subject">>, H)
    ),
    %% Two adjacent encoded-words (different charsets); inter-word ws dropped.
    ?assertEqual(<<"If you can read this how are you?">>, Subject),
    %% From display name has a latin1 encoded-word.
    [From] = mailio_rfc5322:parse_addresses(mailio_rfc5322:header(<<"from">>, H)),
    ?assertEqual(<<"André Pirard"/utf8>>, maps:get(name, From)),
    ?assertEqual(<<"PIRARD@vm1.ulg.ac.be">>, maps:get(email, From)),
    {ok, _Epoch} = mailio_rfc5322:parse_date(mailio_rfc5322:header(<<"date">>, H)).

nested_multipart_with_message(Config) ->
    Raw = load(Config, "nested_torture.eml"),
    P = mailio_mime:parse(Raw),
    ?assertEqual(<<"multipart/mixed">>, mailio_mime:content_type(P)),
    [Alt, Msg, Att] = mailio_mime:parts(P),

    %% First child: multipart/alternative with plain + html.
    ?assertEqual(<<"multipart/alternative">>, mailio_mime:content_type(Alt)),
    [Plain, Html] = mailio_mime:parts(Alt),
    ?assertEqual(<<"This is the plain text version.">>, mailio_mime:body(Plain)),
    ?assertMatch(<<"<html>", _/binary>>, mailio_mime:body(Html)),

    %% Second child: message/rfc822 with a parsed nested message.
    ?assertEqual(<<"message/rfc822">>, mailio_mime:content_type(Msg)),
    [Nested] = mailio_mime:parts(Msg),
    ?assertEqual(<<"Forwarded message">>, mailio_mime:header(<<"subject">>, Nested)),
    ?assertEqual(<<"The forwarded body.">>, mailio_mime:body(Nested)),

    %% Third child: base64 attachment.
    ?assert(mailio_mime:is_attachment(Att)),
    ?assertEqual(<<"data.bin">>, mailio_mime:filename(Att)),
    ?assertEqual(<<0, 1, 2, 3, 4, 5>>, mailio_mime:body(Att)),

    %% No structural defects.
    Defects = (mailio_mime:walk(fun(Pt, Acc) -> mailio_mime:defects(Pt) ++ Acc end, []))(P),
    ?assertEqual([], Defects),

    %% leaves/1 yields exactly the four leaf bodies in order.
    ?assertEqual(4, length(mailio_mime:leaves(P))).

cp1252_quoted_printable(Config) ->
    Raw = load(Config, "cp1252_qp.eml"),
    P = mailio_mime:parse(Raw),
    %% Body decodes QP -> windows-1252 bytes; charset conversion happens at
    %% the indexing layer, so verify the decoded cp1252 bytes here.
    Qp = mailio_mime:body(P),
    Utf8 = mailio_mime_decode:to_utf8(Qp, mailio_mime:charset(P)),
    ?assertEqual(
        <<"Smart quotes ‘here’ and a price of €100 with a dash – done."/utf8>>,
        mailio_ascii:trim_trailing(Utf8)
    ).

rfc2231_split_extended_filename(Config) ->
    Raw = load(Config, "rfc2231_filename.eml"),
    P = mailio_mime:parse(Raw),
    %% filename*0* (extended, percent-encoded UTF-8) + *1 + *2, reassembled.
    ?assertEqual(<<"€ report part1of2.pdf"/utf8>>, mailio_mime:filename(P)),
    ?assert(mailio_mime:is_attachment(P)).

wrapped_base64_body(Config) ->
    Raw = load(Config, "base64_wrapped.eml"),
    P = mailio_mime:parse(Raw),
    Body = mailio_mime:body(P),
    ?assertMatch(<<"Lorem ipsum dolor", _/binary>>, Body),
    ?assert(binary:match(Body, <<"minim veniam.">>) =/= nomatch).
