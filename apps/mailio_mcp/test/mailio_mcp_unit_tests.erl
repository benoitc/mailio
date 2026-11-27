%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_mcp_unit_tests).
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Time: DST windows and bounds

paris_day_lengths_test() ->
    {ok, S1, E1} = mailio_mcp_time:day_window(<<"2026-03-29">>, <<"Europe/Paris">>),
    ?assertEqual(23 * 3600, E1 - S1),
    ?assertEqual(<<"2026-03-28T23:00:00Z">>, mailio_mcp_time:to_rfc3339(S1)),
    {ok, S2, E2} = mailio_mcp_time:day_window(<<"2026-10-25">>, <<"Europe/Paris">>),
    ?assertEqual(25 * 3600, E2 - S2),
    {ok, S3, E3} = mailio_mcp_time:day_window(<<"2026-07-10">>, <<"Europe/Paris">>),
    ?assertEqual(24 * 3600, E3 - S3),
    ?assertEqual(<<"2026-07-09T22:00:00Z">>, mailio_mcp_time:to_rfc3339(S3)).

far_future_uses_posix_rule_test() ->
    {ok, S, E} = mailio_mcp_time:day_window(<<"2045-03-26">>, <<"Europe/Paris">>),
    ?assertEqual(23 * 3600, E - S).

other_zone_test() ->
    {ok, S, E} = mailio_mcp_time:day_window(<<"2026-03-08">>, <<"America/New_York">>),
    ?assertEqual(23 * 3600, E - S).

bounds_test() ->
    ?assertMatch(
        {ok, _, instant}, mailio_mcp_time:parse_bound(<<"2026-03-29T10:00:00+02:00">>, undefined)
    ),
    ?assertEqual(
        {error, time_zone_required}, mailio_mcp_time:parse_bound(<<"2026-03-29">>, undefined)
    ),
    ?assertMatch(
        {error, {bad_time, _}}, mailio_mcp_time:parse_bound(<<"yesterday">>, <<"Europe/Paris">>)
    ),
    ?assertMatch(
        {error, {unknown_time_zone, _}},
        mailio_mcp_time:parse_bound(<<"2026-03-29">>, <<"Mars/Base">>)
    ),
    ?assertMatch(
        {error, {unknown_time_zone, _}},
        mailio_mcp_time:parse_bound(<<"2026-03-29">>, <<"../etc/passwd">>)
    ).

gap_and_fold_test() ->
    %% 02:30 on 2026-03-29 does not exist in Paris; 02:30 on 2026-10-25 happens twice.
    Local = fun(Y, M, D, H, Mi) ->
        calendar:datetime_to_gregorian_seconds({{Y, M, D}, {H, Mi, 0}}) - 62167219200
    end,
    {ok, Gap} = mailio_mcp_time:local_to_utc(Local(2026, 3, 29, 2, 30), <<"Europe/Paris">>),
    ?assertEqual(<<"2026-03-29T01:30:00Z">>, mailio_mcp_time:to_rfc3339(Gap)),
    {ok, Fold} = mailio_mcp_time:local_to_utc(Local(2026, 10, 25, 2, 30), <<"Europe/Paris">>),
    ?assertEqual(<<"2026-10-25T00:30:00Z">>, mailio_mcp_time:to_rfc3339(Fold)).

dates_test() ->
    ?assertEqual(
        {ok, 1795510800}, mailio_mcp_time:parse_header_date(<<"Tue, 24 Nov 2026 10:00:00 +0100">>)
    ),
    ?assertEqual(
        {ok, 1795510800}, mailio_mcp_time:parse_imap_date(<<"24-Nov-2026 10:00:00 +0100">>)
    ),
    ?assertEqual(error, mailio_mcp_time:parse_header_date(<<"not a date">>)).

%%--------------------------------------------------------------------
%% IMAP tokenizer, UTF-7, bodystructure

utf7_test() ->
    ?assertEqual(
        <<"Envoy", 195, 169, "s"/utf8>>, mailio_mcp_imap_io:utf7_decode(<<"Envoy&AOk-s">>)
    ),
    ?assertEqual(
        <<"Envoy&AOk-s">>, mailio_mcp_imap_io:utf7_encode(<<"Envoy", 195, 169, "s"/utf8>>)
    ),
    ?assertEqual(<<"A&-B">>, mailio_mcp_imap_io:utf7_encode(<<"A&B">>)).

bodystructure_attachment_test() ->
    Line =
        <<
            "* 1 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 10 1 NIL NIL NIL)"
            "(\"APPLICATION\" \"PDF\" (\"NAME\" \"inv.pdf\") NIL NIL \"BASE64\" 2000 NIL (\"ATTACHMENT\" (\"FILENAME\" \"inv.pdf\")) NIL) \"MIXED\" NIL NIL NIL))"
        >>,
    {untagged, {fetch, 1, Items}} = mailio_imap_proto:parse_response(Line),
    Tokens = mailio_mcp_imap_io:tokens_to_term(proplists:get_value(<<"BODYSTRUCTURE">>, Items)),
    Parts = mailio_mcp_imap:parse_bodystructure(Tokens),
    ?assertEqual([<<"1">>, <<"2">>], [maps:get(id, P) || P <- Parts]),
    ?assertEqual([false, true], [mailio_mcp_imap:is_attachment(P) || P <- Parts]),
    ?assertEqual(<<"inv.pdf">>, maps:get(name, lists:nth(2, Parts))),
    ?assertEqual(<<"1">>, maps:get(id, mailio_mcp_imap:body_part(Parts))).

%%--------------------------------------------------------------------
%% MIME

mime_words_test() ->
    ?assertEqual(
        <<"Fa", 195, 167, "ade"/utf8>>,
        mailio_mcp_mime:decode_words(<<"=?UTF-8?Q?Fa=C3=A7ade?=">>)
    ),
    ?assertEqual(
        <<"Caf", 195, 169, " "/utf8, "noir"/utf8>>,
        mailio_mcp_mime:decode_words(<<"=?iso-8859-1?B?Q2Fm6Q==?= noir">>)
    ).

strip_quoted_test() ->
    Text = <<"Thanks.\n\nOn Mon, 1 Jan 2026, Bob wrote:\n> old text\n> more\n">>,
    ?assertEqual(<<"Thanks.">>, mailio_mcp_mime:strip_quoted(Text)),
    ?assertEqual(<<"a\nb">>, mailio_mcp_mime:strip_quoted(<<"a\n> q\nb\n">>)).

page_test() ->
    T = <<"abcdefghij">>,
    ?assertEqual({<<"abcd">>, 4}, mailio_mcp_mime:page(T, 0, 4)),
    ?assertEqual({<<"ghij">>, undefined}, mailio_mcp_mime:page(T, 6, 10)),
    %% never cuts inside a UTF-8 character
    U = <<"aé"/utf8, "b">>,
    {P, _} = mailio_mcp_mime:page(U, 0, 2),
    ?assertEqual(<<"a">>, P).

addresses_test() ->
    [A] = mailio_mcp_mime:addresses(<<"=?UTF-8?Q?J=C3=BCrgen?= <j@example.test>">>),
    ?assertEqual(<<"j@example.test">>, maps:get(address, A)),
    ?assertEqual(<<"J", 195, 188, "rgen"/utf8>>, maps:get(name, A)).

%%--------------------------------------------------------------------
%% Budget

budget_test() ->
    Hits = [
        #{
            <<"handle">> => binary:copy(<<"h">>, 60),
            <<"account">> => <<"work">>,
            <<"mailbox">> => <<"INBOX">>,
            <<"subject">> => binary:copy(<<"s">>, 5000),
            <<"from">> => binary:copy(<<"f">>, 500)
        }
     || _ <- lists:seq(1, 20)
    ],
    R = mailio_mcp_budget:fit(#{<<"count">> => 99}, Hits, fun(_) -> <<"cur">> end, false),
    ?assert(mailio_mcp_budget:size(R) =< 8192),
    #{<<"hits">> := Kept} = R,
    ?assert(length(Kept) >= 1),
    ?assert(byte_size(maps:get(<<"subject">>, hd(Kept))) < 400).

budget_truncation_reports_cursor_test() ->
    Hits = [#{<<"handle">> => binary:copy(<<"h">>, 400), <<"n">> => I} || I <- lists:seq(1, 20)],
    R = mailio_mcp_budget:fit(#{}, Hits, fun(_) -> <<"next">> end, false),
    ?assert(mailio_mcp_budget:size(R) =< 8192),
    ?assertMatch(#{<<"truncated">> := #{<<"dropped">> := D}} when D > 0, R),
    ?assertEqual(<<"next">>, maps:get(<<"next_cursor">>, R)).

page_size_cap_test() ->
    ?assertEqual(20, mailio_mcp_budget:page_size(undefined)),
    ?assertEqual(20, mailio_mcp_budget:page_size(500)),
    ?assertEqual(5, mailio_mcp_budget:page_size(5)).

%%--------------------------------------------------------------------
%% Search cache: mailbox invalidation must reach search entries

cache_mailbox_invalidation_test_() ->
    {setup,
        fun() ->
            {ok, P} = mailio_mcp_cache:start_link(),
            P
        end,
        fun(P) ->
            unlink(P),
            exit(P, shutdown),
            timer:sleep(50)
        end,
        fun(_) ->
            [
                fun() ->
                    Acc = <<"acc1">>,
                    mailio_mcp_cache:put(
                        Acc, {search, [<<"INBOX">>, <<"Archive">>], <<"h1">>}, v1
                    ),
                    mailio_mcp_cache:put(Acc, {search, [<<"Archive">>], <<"h2">>}, v2),
                    mailio_mcp_cache:put(Acc, {other, <<"INBOX">>}, v3),
                    %% a search over INBOX is dropped, the Archive-only one stays
                    mailio_mcp_cache:invalidate_mailbox(Acc, <<"INBOX">>),
                    ?assertEqual(
                        miss,
                        mailio_mcp_cache:get(Acc, {search, [<<"INBOX">>, <<"Archive">>], <<"h1">>})
                    ),
                    ?assertMatch(
                        {ok, v2, _}, mailio_mcp_cache:get(Acc, {search, [<<"Archive">>], <<"h2">>})
                    ),
                    ?assertMatch({ok, v3, _}, mailio_mcp_cache:get(Acc, {other, <<"INBOX">>})),
                    mailio_mcp_cache:invalidate_mailbox(Acc, <<"Archive">>),
                    ?assertEqual(
                        miss, mailio_mcp_cache:get(Acc, {search, [<<"Archive">>], <<"h2">>})
                    ),
                    %% other accounts are untouched
                    mailio_mcp_cache:put(<<"acc2">>, {search, [<<"INBOX">>], <<"h3">>}, v4),
                    mailio_mcp_cache:invalidate_mailbox(Acc, <<"INBOX">>),
                    ?assertMatch(
                        {ok, v4, _},
                        mailio_mcp_cache:get(<<"acc2">>, {search, [<<"INBOX">>], <<"h3">>})
                    )
                end
            ]
        end}.

%% A search that captured the account's cache generation before an
%% invalidation must not land its stale result after the invalidation ran.
cache_generation_blocks_stale_write_test_() ->
    {setup,
        fun() ->
            {ok, P} = mailio_mcp_cache:start_link(),
            P
        end,
        fun(P) ->
            unlink(P),
            exit(P, shutdown),
            timer:sleep(50)
        end,
        fun(_) ->
            [
                fun() ->
                    Acc = <<"accg">>,
                    Key = {search, [<<"INBOX">>], <<"h">>},
                    E0 = mailio_mcp_cache:epoch(Acc),
                    ?assertEqual(ok, mailio_mcp_cache:put(Acc, Key, v0, E0)),
                    ok = mailio_mcp_cache:invalidate_mailbox(Acc, <<"INBOX">>),
                    %% the write of a search that started before the
                    %% invalidation is refused
                    ?assertEqual(stale, mailio_mcp_cache:put(Acc, Key, stale, E0)),
                    ?assertEqual(miss, mailio_mcp_cache:get(Acc, Key)),
                    %% a search that started after it is kept
                    E1 = mailio_mcp_cache:epoch(Acc),
                    ?assert(E1 > E0),
                    ?assertEqual(ok, mailio_mcp_cache:put(Acc, Key, v1, E1)),
                    ?assertMatch({ok, v1, _}, mailio_mcp_cache:get(Acc, Key)),
                    %% invalidate_account bumps the generation too
                    E2 = mailio_mcp_cache:epoch(Acc),
                    ok = mailio_mcp_cache:invalidate_account(Acc),
                    ?assertEqual(stale, mailio_mcp_cache:put(Acc, Key, v2, E2)),
                    ?assertEqual(miss, mailio_mcp_cache:get(Acc, Key))
                end
            ]
        end}.

%%--------------------------------------------------------------------
%% Query-centered excerpts

center_excerpt_test() ->
    %% no query: starts at the beginning
    ?assertEqual(<<"Hello world">>, mailio_mcp_imap:center_excerpt(<<"Hello world">>, undefined)),
    %% centered on the first matching term, case-insensitive
    Long = <<
        "The meeting is scheduled for next week and the agenda is attached. "
        "Your invoice 2026-114 total is due. "
        "Please pay promptly."
    >>,
    Ex = mailio_mcp_imap:center_excerpt(Long, <<"invoice">>),
    ?assertMatch(<<"…"/utf8, _/binary>>, Ex),
    ?assert(string:find(Ex, <<"invoice 2026-114">>) =/= nomatch),
    %% no matching term: starts at the beginning
    ?assertEqual(
        <<"Hello world">>, mailio_mcp_imap:center_excerpt(<<"Hello world">>, <<"nothing here">>)
    ),
    %% never cut inside a UTF-8 code point
    U = <<"a", 195, 169, "b"/utf8, " caf", 195, 169, " date target">>,
    UEx = mailio_mcp_imap:center_excerpt(U, <<"date">>),
    ?assertEqual(true, is_binary(UEx)),
    %% re-decoding the bytes as UTF-8 succeeds, so no code point was cut
    ?assertEqual(UEx, unicode:characters_to_binary(UEx, utf8)).

excerpt_bounded_test() ->
    Text = binary:copy(<<"word ">>, 400),
    Ex = mailio_mcp_imap:center_excerpt(Text, <<"word">>),
    ?assert(string:length(Ex) =< 160).

%% Punctuation, regex metacharacters and non-ASCII terms are matched
%% literally, and the excerpt centers on them.
center_excerpt_punctuation_and_unicode_test() ->
    Pad = binary:copy(<<"padding ">>, 25),
    Long =
        <<
            Pad/binary,
            "Write to foo@example.test about invoice 2026-114 (net 30). "
            "Trailing padding keeps the window away from the end as well."
        >>,
    %% digits and a dash, matched literally
    Ex1 = mailio_mcp_imap:center_excerpt(Long, <<"2026-114">>),
    ?assertMatch(<<"…"/utf8, _/binary>>, Ex1),
    ?assert(string:find(Ex1, <<"invoice 2026-114">>) =/= nomatch),
    %% an address with a dot and an at sign
    Ex2 = mailio_mcp_imap:center_excerpt(Long, <<"foo@example.test">>),
    ?assertMatch(<<"…"/utf8, _/binary>>, Ex2),
    ?assert(string:find(Ex2, <<"foo@example.test">>) =/= nomatch),
    %% regex metacharacters in the query are ordinary characters
    ?assertEqual(
        <<"Hello (a|b) world">>,
        mailio_mcp_imap:center_excerpt(<<"Hello (a|b) world">>, <<"(a|b)">>)
    ),
    %% non-ASCII, case folded through the unicode option
    U =
        <<
            "Du texte de remplissage, assez long pour dépasser la fenêtre de l'extrait sans "/utf8,
            Pad/binary,
            "fin. Le café est servi ici, loin du début du message. Encore du remplissage."/utf8
        >>,
    Ex3 = mailio_mcp_imap:center_excerpt(U, <<"CAFÉ"/utf8>>),
    ?assertMatch(<<"…"/utf8, _/binary>>, Ex3),
    ?assert(string:find(Ex3, <<"caf"/utf8>>) =/= nomatch).

%%--------------------------------------------------------------------
%% Handles and authorization

handle_test_() ->
    {setup,
        fun() ->
            application:set_env(
                mailio_mcp,
                data_dir,
                "/tmp/mcp_unit_" ++ integer_to_list(erlang:unique_integer([positive]))
            ),
            {ok, P} = mailio_mcp_store:start_link(),
            P
        end,
        fun(P) ->
            unlink(P),
            exit(P, shutdown),
            timer:sleep(50)
        end,
        fun(_) ->
            [
                fun() ->
                    T = mailio_mcp_handle:encode(msg, <<"p1">>, #{
                        <<"a">> => <<"work">>, <<"u">> => 7
                    }),
                    ?assertEqual(
                        {ok, #{<<"a">> => <<"work">>, <<"u">> => 7}},
                        mailio_mcp_handle:decode(msg, <<"p1">>, T)
                    ),
                    %% another caller, another kind, a tampered token
                    ?assertEqual(
                        {error, invalid_handle}, mailio_mcp_handle:decode(msg, <<"p2">>, T)
                    ),
                    ?assertEqual(
                        {error, invalid_handle}, mailio_mcp_handle:decode(cursor, <<"p1">>, T)
                    ),
                    [Body, Mac] = binary:split(T, <<".">>),
                    ?assertEqual(
                        {error, invalid_handle},
                        mailio_mcp_handle:decode(msg, <<"p1">>, <<Body/binary, "x.", Mac/binary>>)
                    ),
                    ?assertEqual(
                        {error, invalid_handle},
                        mailio_mcp_handle:decode(msg, <<"p1">>, <<"garbage">>)
                    )
                end
            ]
        end}.

authz_test_() ->
    {setup,
        fun() ->
            application:set_env(mailio_mcp, accounts, [
                #{
                    id => <<"work">>,
                    incoming => #{host => "h"},
                    auth => #{},
                    identities => [#{address => <<"w@x">>, name => <<"W">>}]
                },
                #{
                    id => <<"home">>,
                    incoming => #{host => "h"},
                    auth => #{},
                    identities => [#{address => <<"h@x">>, name => <<"H">>}]
                }
            ]),
            application:set_env(mailio_mcp, principals, [
                #{
                    id => <<"both">>,
                    grants => #{
                        <<"work">> => #{role => send, identities => all},
                        <<"home">> => #{role => read, identities => []}
                    }
                },
                #{id => <<"one">>, grants => #{<<"home">> => #{role => read, identities => []}}}
            ])
        end,
        fun(_) ->
            application:unset_env(mailio_mcp, accounts),
            application:unset_env(mailio_mcp, principals)
        end,
        fun(_) ->
            [
                ?_assertEqual(
                    {error, account_ids_required},
                    mailio_mcp_authz:select_accounts(<<"both">>, #{})
                ),
                ?_assertEqual(
                    {ok, [<<"home">>]}, mailio_mcp_authz:select_accounts(<<"one">>, #{})
                ),
                ?_assertEqual(
                    {ok, [<<"home">>, <<"work">>]},
                    mailio_mcp_authz:select_accounts(<<"both">>, #{<<"account_ids">> => <<"all">>})
                ),
                ?_assertEqual(
                    {ok, [<<"home">>]},
                    mailio_mcp_authz:select_accounts(<<"one">>, #{<<"account_ids">> => <<"all">>})
                ),
                %% an account that exists but is not granted looks like one that does not exist
                ?_assertEqual(
                    mailio_mcp_authz:select_accounts(<<"one">>, #{
                        <<"account_ids">> => [<<"work">>]
                    }),
                    mailio_mcp_authz:select_accounts(<<"one">>, #{
                        <<"account_ids">> => [<<"nope">>]
                    })
                ),
                ?_assertEqual(
                    {error, unknown_account},
                    mailio_mcp_authz:select_accounts(<<"one">>, #{
                        <<"account_ids">> => [<<"home">>, <<"work">>]
                    })
                ),
                ?_assertEqual(
                    {error, unknown_account}, mailio_mcp_authz:check(<<"one">>, <<"work">>, read)
                ),
                ?_assertEqual(
                    {error, {forbidden, send}},
                    mailio_mcp_authz:check(<<"one">>, <<"home">>, send)
                ),
                ?_assertEqual(ok, mailio_mcp_authz:check(<<"both">>, <<"work">>, send)),
                ?_assertEqual([], mailio_mcp_authz:identities(<<"one">>, <<"work">>)),
                ?_assertMatch(
                    {error, {identity_not_permitted, _}},
                    mailio_mcp_authz:check_identity(<<"both">>, <<"work">>, <<"h@x">>)
                )
            ]
        end}.

request_state_key_test_() ->
    Cleanup = fun(_) ->
        application:unset_env(mailio_mcp, request_state_key),
        application:unset_env(barrel_mcp, request_state_key)
    end,
    {setup, fun() -> ok end, Cleanup, [
        fun() ->
            ?assertEqual(ok, mailio_mcp_config:apply_request_state_key()),
            ?assertEqual(undefined, application:get_env(barrel_mcp, request_state_key, undefined))
        end,
        fun() ->
            Key = binary:copy(<<"k">>, 40),
            application:set_env(mailio_mcp, request_state_key, {value, Key}),
            ?assertEqual(ok, mailio_mcp_config:apply_request_state_key()),
            ?assertEqual({ok, Key}, application:get_env(barrel_mcp, request_state_key))
        end,
        fun() ->
            application:set_env(mailio_mcp, request_state_key, {value, <<"short">>}),
            ?assertEqual(
                {error, request_state_key_too_short}, mailio_mcp_config:apply_request_state_key()
            )
        end,
        fun() ->
            application:set_env(mailio_mcp, request_state_key, {env, "MAILIO_NO_SUCH_VAR_XYZ"}),
            ?assertMatch({error, {missing_env, _}}, mailio_mcp_config:apply_request_state_key())
        end
    ]}.

http_options_test_() ->
    Cleanup = fun(_) -> application:unset_env(mailio_mcp, http) end,
    {setup, fun() -> ok end, Cleanup, [
        fun() ->
            application:unset_env(mailio_mcp, http),
            ?assertEqual({ok, #{port => 8420}}, mailio_mcp_config:http_options())
        end,
        fun() ->
            application:set_env(mailio_mcp, http, #{port => 1, ip => "0.0.0.0"}),
            ?assertEqual({ok, #{port => 1, ip => {0, 0, 0, 0}}}, mailio_mcp_config:http_options())
        end,
        fun() ->
            application:set_env(mailio_mcp, http, #{ip => "not an address"}),
            ?assertMatch({error, {bad_ip, _}}, mailio_mcp_config:http_options())
        end,
        fun() ->
            application:set_env(mailio_mcp, http, #{
                port => 1,
                auth => #{
                    provider => barrel_mcp_auth_bearer,
                    provider_opts => #{secret => {value, <<"s3cret">>}, audience => <<"mail">>}
                }
            }),
            {ok, #{auth := #{provider_opts := PO}}} = mailio_mcp_config:http_options(),
            ?assertEqual(<<"s3cret">>, maps:get(secret, PO)),
            ?assertEqual(<<"mail">>, maps:get(audience, PO))
        end
    ]}.
