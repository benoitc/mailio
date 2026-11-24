%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_filter_tests).
-include_lib("eunit/include/eunit.hrl").
-include("mailio_store.hrl").

email() ->
    #{
        <<"id">> => <<"email/x">>,
        <<"subject">> => <<"Project Kickoff">>,
        <<"from">> => [#{<<"name">> => <<"Alice">>, <<"email">> => <<"alice@example.com">>}],
        <<"to">> => [#{<<"name">> => null, <<"email">> => <<"bob@example.com">>}],
        <<"mailboxIds">> => #{<<"inbox">> => true},
        <<"keywords">> => #{?KW_FLAGGED => true},
        <<"size">> => 2048,
        <<"hasAttachment">> => true,
        <<"threadId">> => <<"t1">>,
        ?MAILIO_NS => #{<<"received_ts">> => 1748000000}
    }.

body() -> fun() -> <<"let us kickoff this week">> end.

m(Filter) -> mailio_filter:matches(email(), body(), Filter).

in_mailbox_test() ->
    ?assert(m(#{inMailbox => <<"inbox">>})),
    ?assertNot(m(#{inMailbox => <<"archive">>})).

keyword_test() ->
    ?assert(m(#{hasKeyword => ?KW_FLAGGED})),
    ?assert(m(#{notKeyword => ?KW_SEEN})),
    ?assertNot(m(#{hasKeyword => ?KW_SEEN})).

substring_case_insensitive_test() ->
    ?assert(m(#{subject => <<"kickoff">>})),
    ?assert(m(#{from => <<"ALICE">>})),
    ?assert(m(#{to => <<"bob">>})),
    ?assertNot(m(#{subject => <<"invoice">>})).

text_matches_any_field_test() ->
    %% address
    ?assert(m(#{text => <<"alice">>})),
    %% subject
    ?assert(m(#{text => <<"project">>})),
    %% body
    ?assert(m(#{text => <<"this week">>})),
    ?assertNot(m(#{text => <<"nonexistent">>})).

size_test() ->
    ?assert(m(#{minSize => 1000})),
    ?assert(m(#{maxSize => 4096})),
    ?assertNot(m(#{minSize => 4096})).

date_test() ->
    ?assert(m(#{after_ => 1747000000})),
    ?assert(m(#{before => 1749000000})),
    ?assertNot(m(#{after_ => 1749000000})).

attachment_test() ->
    ?assert(m(#{hasAttachment => true})),
    ?assertNot(m(#{hasAttachment => false})).

operators_test() ->
    ?assert(
        m(#{
            operator => 'AND',
            conditions => [#{subject => <<"kickoff">>}, #{inMailbox => <<"inbox">>}]
        })
    ),
    ?assertNot(
        m(#{
            operator => 'AND',
            conditions => [#{subject => <<"kickoff">>}, #{inMailbox => <<"archive">>}]
        })
    ),
    ?assert(
        m(#{
            operator => 'OR',
            conditions => [#{inMailbox => <<"archive">>}, #{hasKeyword => ?KW_FLAGGED}]
        })
    ),
    ?assert(
        m(#{
            operator => 'NOT',
            conditions => [#{inMailbox => <<"archive">>}]
        })
    ).

empty_filter_matches_test() ->
    ?assert(m(#{})).

index_query_pushes_structural_test() ->
    {where, Wheres} = mailio_filter:index_query(
        #{
            operator => 'AND',
            conditions => [#{inMailbox => <<"inbox">>}, #{subject => <<"x">>}]
        }
    ),
    %% inMailbox pushed; subject (substring) not.
    ?assert(lists:member({path, [<<"mailboxIds">>, <<"inbox">>], true}, Wheres)),
    ?assertEqual(1, length(Wheres)).

index_query_or_is_full_scan_test() ->
    ?assertEqual(
        all,
        mailio_filter:index_query(
            #{operator => 'OR', conditions => [#{inMailbox => <<"inbox">>}]}
        )
    ).

needs_body_test() ->
    ?assert(mailio_filter:needs_body(#{body => <<"x">>})),
    ?assert(mailio_filter:needs_body(#{text => <<"x">>})),
    ?assertNot(mailio_filter:needs_body(#{subject => <<"x">>})).
