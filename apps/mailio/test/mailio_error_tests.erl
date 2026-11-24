%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_error_tests).
-include_lib("eunit/include/eunit.hrl").

source_derived_from_prefix_test() ->
    ?assertEqual(imap, mailio_error:source(mailio_error:new(imap_auth_failed))),
    ?assertEqual(smtp, mailio_error:source(mailio_error:new(smtp_transient))),
    ?assertEqual(mailio, mailio_error:source(mailio_error:new(not_found))).

retryable_defaults_test() ->
    ?assert(mailio_error:is_retryable(mailio_error:new(imap_disconnected))),
    ?assertNot(mailio_error:is_retryable(mailio_error:new(imap_auth_failed))).

detail_and_code_test() ->
    E = mailio_error:new(store_unavailable, #{db => <<"acct1">>}),
    ?assertEqual(store_unavailable, mailio_error:code(E)),
    ?assertEqual(#{db => <<"acct1">>}, mailio_error:detail(E)),
    ?assert(mailio_error:is_retryable(E)).

is_error_test() ->
    ?assert(mailio_error:is_error(mailio_error:new(mime_parse_failed))),
    ?assertNot(mailio_error:is_error({error, not_found})),
    ?assertNot(mailio_error:is_error(ok)).

format_test() ->
    E = mailio_error:new(imap_timeout, <<"connection timed out">>, #{}),
    ?assertEqual(<<"imap_timeout: connection timed out">>, mailio_error:format(E)).
