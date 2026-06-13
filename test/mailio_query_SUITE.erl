%%% @doc M7 JMAP Email/query, get, changes and search suite.
-module(mailio_query_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([query_in_mailbox/1,
         query_from_substring/1,
         query_subject_and_keyword/1,
         query_date_range/1,
         query_has_attachment/1,
         query_operator_or/1,
         query_sort_and_paginate/1,
         query_collapse_threads/1,
         get_property_projection/1,
         email_changes_delta/1,
         search_text_snippet/1]).

all() ->
    [query_in_mailbox,
     query_from_substring,
     query_subject_and_keyword,
     query_date_range,
     query_has_attachment,
     query_operator_or,
     query_sort_and_paginate,
     query_collapse_threads,
     get_property_projection,
     email_changes_delta,
     search_text_snippet].

init_per_suite(Config) ->
    Priv = ?config(priv_dir, Config),
    application:set_env(barrel_docdb, data_dir, Priv),
    application:set_env(mailio, data_dir, Priv),
    {ok, _} = application:ensure_all_started(mailio),
    Config.

end_per_suite(_Config) ->
    application:stop(mailio),
    application:stop(barrel_docdb),
    ok.

init_per_testcase(_TC, Config) ->
    Account = list_to_binary("Q" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    %% A small deterministic corpus.
    {ok, E1} = ingest(Account, <<"inbox">>, e1(),  ts(1), [?KW_FLAGGED]),
    {ok, E2} = ingest(Account, <<"inbox">>, e2(),  ts(2), []),
    {ok, E3} = ingest(Account, <<"inbox">>, e3(),  ts(3), [?KW_SEEN]),
    {ok, E4} = ingest(Account, <<"archive">>, e4(), ts(4), []),
    [{account, Account}, {e1, E1}, {e2, E2}, {e3, E3}, {e4, E4} | Config].

end_per_testcase(_TC, Config) ->
    Account = ?config(account, Config),
    try mailio_accounts_sup:stop_account(Account) catch _:_ -> ok end,
    try mailio_db:delete_db(mailio_account:db_name(Account)) catch _:_ -> ok end,
    ok.

%%====================================================================

query_in_mailbox(Config) ->
    Account = ?config(account, Config),
    {ok, #{<<"ids">> := Ids, <<"total">> := Total}} =
        mailio_email:query(Account, #{filter => #{inMailbox => <<"inbox">>}}),
    ?assertEqual(3, Total),
    ?assertEqual(3, length(Ids)),
    ?assertNot(lists:member(?config(e4, Config), Ids)).

query_from_substring(Config) ->
    Account = ?config(account, Config),
    {ok, #{<<"ids">> := Ids}} =
        mailio_email:query(Account, #{filter => #{from => <<"alice">>}}),
    %% e1 and e4 are from alice.
    ?assertEqual(2, length(Ids)),
    ?assert(lists:member(?config(e1, Config), Ids)),
    ?assert(lists:member(?config(e4, Config), Ids)).

query_subject_and_keyword(Config) ->
    Account = ?config(account, Config),
    Filter = #{operator => 'AND',
               conditions => [#{subject => <<"project">>},
                              #{hasKeyword => ?KW_FLAGGED}]},
    {ok, #{<<"ids">> := Ids}} = mailio_email:query(Account, #{filter => Filter}),
    ?assertEqual([?config(e1, Config)], Ids).

query_date_range(Config) ->
    Account = ?config(account, Config),
    {ok, #{<<"ids">> := Ids}} =
        mailio_email:query(Account, #{filter => #{after_ => ts(2), before => ts(4)}}),
    %% received_ts in [ts2, ts4): e2 and e3.
    ?assertEqual(2, length(Ids)),
    ?assert(lists:member(?config(e2, Config), Ids)),
    ?assert(lists:member(?config(e3, Config), Ids)).

query_has_attachment(Config) ->
    Account = ?config(account, Config),
    {ok, #{<<"ids">> := Ids}} =
        mailio_email:query(Account, #{filter => #{hasAttachment => true}}),
    ?assertEqual([?config(e1, Config)], Ids).

query_operator_or(Config) ->
    Account = ?config(account, Config),
    Filter = #{operator => 'OR',
               conditions => [#{hasKeyword => ?KW_FLAGGED},
                              #{hasKeyword => ?KW_SEEN}]},
    {ok, #{<<"ids">> := Ids}} = mailio_email:query(Account, #{filter => Filter}),
    ?assertEqual(2, length(Ids)),
    ?assert(lists:member(?config(e1, Config), Ids)),
    ?assert(lists:member(?config(e3, Config), Ids)).

query_sort_and_paginate(Config) ->
    Account = ?config(account, Config),
    Asc = [#{<<"property">> => <<"receivedAt">>, <<"isAscending">> => true}],
    {ok, #{<<"ids">> := All}} = mailio_email:query(Account, #{sort => Asc}),
    ?assertEqual([?config(e1, Config), ?config(e2, Config),
                  ?config(e3, Config), ?config(e4, Config)], All),
    %% Page: position 1, limit 2 -> e2, e3.
    {ok, #{<<"ids">> := Page, <<"total">> := Total}} =
        mailio_email:query(Account, #{sort => Asc, position => 1, limit => 2}),
    ?assertEqual([?config(e2, Config), ?config(e3, Config)], Page),
    ?assertEqual(4, Total).

query_collapse_threads(Config) ->
    Account = ?config(account, Config),
    %% e1 and e2 share a thread (e2 replies to e1).
    {ok, #{<<"total">> := Uncollapsed}} =
        mailio_email:query(Account, #{filter => #{inMailbox => <<"inbox">>}}),
    ?assertEqual(3, Uncollapsed),
    {ok, #{<<"ids">> := Ids, <<"total">> := Collapsed}} =
        mailio_email:query(Account, #{filter => #{inMailbox => <<"inbox">>},
                                      collapseThreads => true}),
    ?assertEqual(2, Collapsed),
    ?assertEqual(2, length(Ids)).

get_property_projection(Config) ->
    Account = ?config(account, Config),
    E1 = ?config(e1, Config),
    {ok, #{<<"list">> := [Email], <<"notFound">> := []}} =
        mailio_email:get(Account, [E1], [<<"subject">>, <<"keywords">>, <<"bodyValues">>]),
    ?assertEqual(E1, maps:get(<<"id">>, Email)),
    ?assertEqual(<<"Project kickoff">>, maps:get(<<"subject">>, Email)),
    %% Projected away.
    ?assertNot(maps:is_key(<<"from">>, Email)),
    %% Internal namespace never leaks.
    ?assertNot(maps:is_key(?MAILIO_NS, Email)),
    %% bodyValues carries the extracted text.
    BV = maps:get(<<"bodyValues">>, Email),
    Text = maps:get(<<"value">>, maps:get(<<"text">>, BV)),
    ?assert(binary:match(Text, <<"kickoff this week">>) =/= nomatch),

    {ok, #{<<"notFound">> := NF}} = mailio_email:get(Account, [<<"nope">>], all),
    ?assertEqual([<<"nope">>], NF).

email_changes_delta(Config) ->
    Account = ?config(account, Config),
    State0 = mailio_account:state_token(Account),
    {ok, E5} = ingest(Account, <<"inbox">>, e5(), ts(5), []),
    {ok, #{<<"created">> := Created, <<"newState">> := State1}} =
        mailio_email:changes(Account, State0, #{}),
    ?assert(lists:member(E5, Created)),
    ?assertNotEqual(State0, State1),
    %% Invalid state token is reported per JMAP.
    ?assertEqual({error, cannot_calculate_changes},
                 mailio_email:changes(Account, <<"!!!not-a-token">>, #{})).

search_text_snippet(Config) ->
    Account = ?config(account, Config),
    %% "kickoff" appears in e1 (subject + body) and e2 (subject), ranked by
    %% recency (e2 newer). Both are returned; the top snippet shows the term.
    {ok, Results} = mailio_search:text(Account, <<"kickoff">>),
    Ids = [maps:get(<<"emailId">>, R) || R <- Results],
    ?assert(lists:member(?config(e1, Config), Ids)),
    ?assert(lists:member(?config(e2, Config), Ids)),
    ?assert(binary:match(maps:get(<<"snippet">>, hd(Results)), <<"kickoff">>) =/= nomatch),

    %% A term unique to one message's body returns just that message.
    {ok, [Only]} = mailio_search:text(Account, <<"this week">>),
    ?assertEqual(?config(e1, Config), maps:get(<<"emailId">>, Only)).

%%====================================================================
%% Corpus
%%====================================================================

ingest(Account, Mailbox, Raw, Ts, Keywords) ->
    mailio_account:ingest_raw(Account, Mailbox, Raw,
                              #{received_at => Ts, keywords => Keywords}).

ts(N) -> 1748000000 + (N * 86400).

e1() ->
    <<"From: Alice <alice@example.com>\r\n",
      "To: Bob <bob@example.com>\r\n",
      "Subject: Project kickoff\r\n",
      "Message-ID: <e1@example.com>\r\n",
      "MIME-Version: 1.0\r\n",
      "Content-Type: multipart/mixed; boundary=BB\r\n\r\n",
      "--BB\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n\r\n",
      "Let's kickoff this week, team.\r\n",
      "--BB\r\n",
      "Content-Type: application/pdf\r\n",
      "Content-Disposition: attachment; filename=\"plan.pdf\"\r\n",
      "Content-Transfer-Encoding: base64\r\n\r\n",
      "JVBERi0xLjQ=\r\n",
      "--BB--\r\n">>.

e2() ->
    <<"From: Bob <bob@example.com>\r\n",
      "To: Alice <alice@example.com>\r\n",
      "Subject: Re: Project kickoff\r\n",
      "Message-ID: <e2@example.com>\r\n",
      "In-Reply-To: <e1@example.com>\r\n",
      "References: <e1@example.com>\r\n\r\n",
      "Sounds great.\r\n">>.

e3() ->
    <<"From: Carol <carol@example.com>\r\n",
      "To: Bob <bob@example.com>\r\n",
      "Subject: Lunch tomorrow\r\n",
      "Message-ID: <e3@example.com>\r\n\r\n",
      "Want to grab lunch?\r\n">>.

e4() ->
    <<"From: Alice <alice@example.com>\r\n",
      "To: Accounts <ap@example.com>\r\n",
      "Subject: Invoice 42\r\n",
      "Message-ID: <e4@example.com>\r\n\r\n",
      "Please find attached.\r\n">>.

e5() ->
    <<"From: Dave <dave@example.com>\r\n",
      "To: Bob <bob@example.com>\r\n",
      "Subject: New thing\r\n",
      "Message-ID: <e5@example.com>\r\n\r\n",
      "Brand new.\r\n">>.
