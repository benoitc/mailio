-module(mailio_rfc5322_tests).
-include_lib("eunit/include/eunit.hrl").

%%==== header/body split & unfolding ====

split_crlf_test() ->
    Raw = <<"From: a@b\r\nSubject: Hi\r\n\r\nBody here">>,
    {H, Body} = mailio_rfc5322:split(Raw),
    ?assertEqual(<<"a@b">>, mailio_rfc5322:header(<<"From">>, H)),
    ?assertEqual(<<"Hi">>, mailio_rfc5322:header(<<"Subject">>, H)),
    ?assertEqual(<<"Body here">>, Body).

split_lf_only_test() ->
    Raw = <<"From: a@b\nSubject: Hi\n\nBody">>,
    {H, Body} = mailio_rfc5322:split(Raw),
    ?assertEqual(<<"a@b">>, mailio_rfc5322:header(<<"from">>, H)),
    ?assertEqual(<<"Body">>, Body).

unfold_test() ->
    Raw = <<"Subject: this is\r\n a folded\r\n\tsubject\r\n\r\n">>,
    {H, _} = mailio_rfc5322:split(Raw),
    ?assertEqual(<<"this is a folded\tsubject">>,
                 mailio_rfc5322:header(<<"Subject">>, H)).

no_body_test() ->
    {H, Body} = mailio_rfc5322:split(<<"From: a@b\r\n">>),
    ?assertEqual(<<"a@b">>, mailio_rfc5322:header(<<"From">>, H)),
    ?assertEqual(<<>>, Body).

case_insensitive_lookup_test() ->
    {H, _} = mailio_rfc5322:split(<<"Content-Type: text/plain\r\n\r\n">>),
    ?assertEqual(<<"text/plain">>, mailio_rfc5322:header(<<"CONTENT-TYPE">>, H)).

multiple_received_test() ->
    Raw = <<"Received: by a\r\nReceived: by b\r\n\r\n">>,
    {H, _} = mailio_rfc5322:split(Raw),
    ?assertEqual([<<"by a">>, <<"by b">>],
                 mailio_rfc5322:all_headers(<<"received">>, H)).

%%==== addresses ====

addr_simple_test() ->
    ?assertEqual([#{name => undefined, email => <<"a@b.com">>}],
                 mailio_rfc5322:parse_addresses(<<"a@b.com">>)).

addr_display_name_test() ->
    ?assertEqual([#{name => <<"Alice Smith">>, email => <<"alice@b.com">>}],
                 mailio_rfc5322:parse_addresses(<<"Alice Smith <alice@b.com>">>)).

addr_quoted_name_test() ->
    ?assertEqual([#{name => <<"Smith, Alice">>, email => <<"alice@b.com">>}],
                 mailio_rfc5322:parse_addresses(<<"\"Smith, Alice\" <alice@b.com>">>)).

addr_list_test() ->
    Res = mailio_rfc5322:parse_addresses(<<"a@x.com, Bob <b@y.com>, c@z.com">>),
    ?assertEqual(3, length(Res)),
    ?assertEqual(<<"b@y.com">>, maps:get(email, lists:nth(2, Res))).

addr_comment_test() ->
    ?assertEqual([#{name => undefined, email => <<"a@b.com">>}],
                 mailio_rfc5322:parse_addresses(<<"a@b.com (Alice)">>)).

addr_encoded_name_test() ->
    In = <<"=?ISO-8859-1?Q?Andr=E9?= <andre@x.com>">>,
    ?assertEqual([#{name => <<"André"/utf8>>, email => <<"andre@x.com">>}],
                 mailio_rfc5322:parse_addresses(In)).

addr_group_test() ->
    In = <<"Friends: a@x.com, b@y.com;">>,
    Res = mailio_rfc5322:parse_addresses(In),
    ?assertEqual([<<"a@x.com">>, <<"b@y.com">>],
                 [maps:get(email, A) || A <- Res]).

%%==== message ids ====

message_id_test() ->
    ?assertEqual(<<"abc@host">>,
                 mailio_rfc5322:parse_message_id(<<"<abc@host>">>)).

references_test() ->
    In = <<"<a@h> <b@h>\r\n <c@h>">>,
    ?assertEqual([<<"a@h">>, <<"b@h">>, <<"c@h">>],
                 mailio_rfc5322:parse_message_ids(In)).

%%==== content-type / params ====

content_type_test() ->
    ?assertEqual({<<"text">>, <<"plain">>, #{<<"charset">> => <<"utf-8">>}},
                 mailio_rfc5322:parse_content_type(<<"text/plain; charset=utf-8">>)).

content_type_quoted_param_test() ->
    {T, S, P} = mailio_rfc5322:parse_content_type(
                  <<"multipart/mixed; boundary=\"==abc==\"">>),
    ?assertEqual({<<"multipart">>, <<"mixed">>}, {T, S}),
    ?assertEqual(<<"==abc==">>, maps:get(<<"boundary">>, P)).

content_type_default_test() ->
    ?assertEqual({<<"text">>, <<"plain">>, #{}},
                 mailio_rfc5322:parse_content_type(undefined)).

disposition_test() ->
    {D, P} = mailio_rfc5322:parse_content_disposition(
               <<"attachment; filename=report.pdf">>),
    ?assertEqual(<<"attachment">>, D),
    ?assertEqual(<<"report.pdf">>, maps:get(<<"filename">>, P)).

rfc2231_continuation_test() ->
    %% Split long parameter reassembled in order.
    In = <<"attachment; filename*0=\"long\"; filename*1=\"name.txt\"">>,
    {_, P} = mailio_rfc5322:parse_content_disposition(In),
    ?assertEqual(<<"longname.txt">>, maps:get(<<"filename">>, P)).

rfc2231_charset_test() ->
    %% filename*=UTF-8''%E2%82%AC.txt  (euro sign .txt)
    In = <<"attachment; filename*=UTF-8''%E2%82%AC.txt">>,
    {_, P} = mailio_rfc5322:parse_content_disposition(In),
    ?assertEqual(<<"€.txt"/utf8>>, maps:get(<<"filename">>, P)).

%%==== dates ====

date_basic_test() ->
    %% Tue, 1 Jul 2003 10:52:37 +0200 == 1057049557 epoch
    {ok, Epoch} = mailio_rfc5322:parse_date(<<"Tue, 1 Jul 2003 10:52:37 +0200">>),
    ?assertEqual(1057049557, Epoch).

date_no_dow_test() ->
    {ok, Epoch} = mailio_rfc5322:parse_date(<<"1 Jul 2003 08:52:37 +0000">>),
    ?assertEqual(1057049557, Epoch).

date_gmt_name_test() ->
    {ok, E1} = mailio_rfc5322:parse_date(<<"1 Jul 2003 08:52:37 GMT">>),
    ?assertEqual(1057049557, E1).

date_invalid_test() ->
    ?assertEqual(error, mailio_rfc5322:parse_date(<<"not a date">>)),
    ?assertEqual(error, mailio_rfc5322:parse_date(undefined)).

%%==== unstructured ====

decode_subject_test() ->
    ?assertEqual(<<"Héllo"/utf8>>,
                 mailio_rfc5322:decode_unstructured(
                   <<"=?utf-8?B?", (base64:encode(<<"Héllo"/utf8>>))/binary, "?=">>)).
