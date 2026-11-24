-module(mailio_html_text_tests).
-include_lib("eunit/include/eunit.hrl").

strip_tags_test() ->
    ?assertEqual(
        <<"Hello world">>,
        mailio_html_text:to_text(<<"<p>Hello <b>world</b></p>">>)
    ).

drop_script_test() ->
    In = <<"<div>keep<script>var x = 1; alert('no')</script> this</div>">>,
    Out = mailio_html_text:to_text(In),
    ?assertEqual(nomatch, binary:match(Out, <<"alert">>)),
    ?assertEqual(<<"keep this">>, Out).

drop_style_test() ->
    In = <<"<style>.a{color:red}</style><p>text</p>">>,
    ?assertEqual(<<"text">>, mailio_html_text:to_text(In)).

entities_test() ->
    ?assertEqual(
        <<"a & b < c > d \"e\"">>,
        mailio_html_text:to_text(
            <<"a &amp; b &lt; c &gt; d &quot;e&quot;">>
        )
    ).

numeric_entities_test() ->
    ?assertEqual(<<"€"/utf8>>, mailio_html_text:to_text(<<"&#8364;">>)),
    ?assertEqual(<<"€"/utf8>>, mailio_html_text:to_text(<<"&#x20AC;">>)).

block_breaks_test() ->
    ?assertEqual(
        <<"line1\nline2">>,
        mailio_html_text:to_text(<<"line1<br>line2">>)
    ).

collapse_whitespace_test() ->
    ?assertEqual(
        <<"a b c">>,
        mailio_html_text:to_text(<<"a    b\t\tc">>)
    ).

bad_entity_passthrough_test() ->
    ?assertEqual(
        <<"100% sure">>,
        mailio_html_text:to_text(<<"100% sure">>)
    ).

preview_truncates_test() ->
    Html = <<"<p>", (binary:copy(<<"x">>, 500))/binary, "</p>">>,
    ?assertEqual(100, string:length(mailio_html_text:preview(Html, 100))).

never_crashes_on_unclosed_tag_test() ->
    ?assertEqual(<<"text">>, mailio_html_text:to_text(<<"<div>text">>)),
    ?assertEqual(<<>>, mailio_html_text:to_text(<<"<unclosed">>)).
