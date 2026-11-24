-module(mailio_mime_render_tests).
-include_lib("eunit/include/eunit.hrl").

%%==== rendering ====

render_simple_leaf_test() ->
    Part = #{type => <<"text">>, subtype => <<"plain">>,
             charset => <<"utf-8">>, encoding => <<"7bit">>,
             body => <<"Hello">>},
    Bytes = mailio_mime_render:render(Part),
    P2 = mailio_mime:parse(Bytes),
    ?assertEqual(<<"text">>, mailio_mime:type(P2)),
    ?assertEqual(<<"utf-8">>, mailio_mime:charset(P2)),
    ?assertEqual(<<"Hello">>, mailio_mime:body(P2)).

render_base64_roundtrip_test() ->
    Body = <<"Binary ", 0, 1, 2, 255, " data">>,
    Part = #{type => <<"application">>, subtype => <<"octet-stream">>,
             encoding => <<"base64">>, body => Body},
    P2 = mailio_mime:parse(mailio_mime_render:render(Part)),
    ?assertEqual(Body, mailio_mime:body(P2)).

render_qp_roundtrip_test() ->
    Body = <<"café = test"/utf8>>,
    Part = #{type => <<"text">>, subtype => <<"plain">>,
             encoding => <<"quoted-printable">>, body => Body},
    P2 = mailio_mime:parse(mailio_mime_render:render(Part)),
    ?assertEqual(Body, mailio_mime:body(P2)).

render_multipart_roundtrip_test() ->
    Part = #{type => <<"multipart">>, subtype => <<"alternative">>,
             params => #{<<"boundary">> => <<"BOUND1">>},
             parts => [#{type => <<"text">>, subtype => <<"plain">>,
                         encoding => <<"7bit">>, body => <<"plain">>},
                       #{type => <<"text">>, subtype => <<"html">>,
                         encoding => <<"7bit">>, body => <<"<b>html</b>">>}]},
    P2 = mailio_mime:parse(mailio_mime_render:render(Part)),
    ?assert(mailio_mime:is_multipart(P2)),
    [A, B] = mailio_mime:parts(P2),
    ?assertEqual(<<"plain">>, mailio_mime:body(A)),
    ?assertEqual(<<"<b>html</b>">>, mailio_mime:body(B)).

%%==== outbound build ====

build_text_message_test() ->
    Msg = mailio_mime_render:build(
            #{from => [#{name => <<"Alice">>, email => <<"alice@x.com">>}],
              to => [#{name => undefined, email => <<"bob@y.com">>}],
              subject => <<"Hello">>,
              text => <<"Hi Bob">>}),
    {H, _} = mailio_rfc5322:split(Msg),
    ?assertEqual(<<"Alice <alice@x.com>">>, mailio_rfc5322:header(<<"From">>, H)),
    ?assertEqual(<<"bob@y.com">>, mailio_rfc5322:header(<<"To">>, H)),
    ?assertEqual(<<"Hello">>, mailio_rfc5322:header(<<"Subject">>, H)),
    P = mailio_mime:parse(Msg),
    ?assertEqual(<<"Hi Bob">>, mailio_mime:body(P)).

build_non_ascii_subject_test() ->
    Msg = mailio_mime_render:build(
            #{from => [#{name => undefined, email => <<"a@x">>}],
              to => [#{name => undefined, email => <<"b@y">>}],
              subject => <<"Re: café"/utf8>>,
              text => <<"body">>}),
    {H, _} = mailio_rfc5322:split(Msg),
    Subj = mailio_rfc5322:header(<<"Subject">>, H),
    %% Encoded on the wire, decodes back to the original.
    ?assertEqual(<<"Re: café"/utf8>>, mailio_rfc5322:decode_unstructured(Subj)).

build_html_alternative_test() ->
    Msg = mailio_mime_render:build(
            #{from => [#{name => undefined, email => <<"a@x">>}],
              to => [#{name => undefined, email => <<"b@y">>}],
              subject => <<"hi">>,
              text => <<"plain body">>,
              html => <<"<p>html body</p>">>}),
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
