-module(mailio_imap_map_tests).
-include_lib("eunit/include/eunit.hrl").
-include("mailio.hrl").

flag_keyword_roundtrip_test() ->
    ?assertEqual(?KW_SEEN, mailio_imap_map:flag_to_keyword(<<"\\Seen">>)),
    ?assertEqual(<<"\\Seen">>, mailio_imap_map:keyword_to_flag(?KW_SEEN)),
    ?assertEqual(?KW_FLAGGED, mailio_imap_map:flag_to_keyword(<<"\\Flagged">>)),
    ?assertEqual(<<"\\Draft">>, mailio_imap_map:keyword_to_flag(?KW_DRAFT)).

custom_keyword_test() ->
    ?assertEqual(<<"important">>, mailio_imap_map:flag_to_keyword(<<"Important">>)),
    ?assertEqual(<<"important">>, mailio_imap_map:keyword_to_flag(<<"important">>)).

non_representable_keyword_test() ->
    %% A keyword with characters not valid in an IMAP atom stays local-only.
    ?assertEqual(undefined, mailio_imap_map:keyword_to_flag(<<"has space">>)),
    ?assertNot(mailio_imap_map:is_representable_keyword(<<"has space">>)).

flags_to_keywords_drops_recent_test() ->
    KW = mailio_imap_map:flags_to_keywords([<<"\\Seen">>, <<"\\Recent">>, <<"NonJunk">>]),
    ?assert(maps:is_key(?KW_SEEN, KW)),
    ?assert(maps:is_key(<<"nonjunk">>, KW)),
    ?assertNot(maps:is_key(<<"$recent">>, KW)).

role_from_special_use_test() ->
    ?assertEqual(sent, mailio_imap_map:role_of([<<"\\Sent">>, <<"\\HasNoChildren">>], <<"Whatever">>)),
    ?assertEqual(trash, mailio_imap_map:role_of([<<"\\Trash">>], <<"X">>)).

role_from_name_test() ->
    ?assertEqual(inbox, mailio_imap_map:role_of([], <<"INBOX">>)),
    ?assertEqual(sent, mailio_imap_map:role_of([], <<"Sent Items">>)),
    ?assertEqual(junk, mailio_imap_map:role_of([], <<"Spam">>)),
    ?assertEqual(undefined, mailio_imap_map:role_of([], <<"Projects">>)).

state_roundtrip_test() ->
    State = mailio_imap_map:encode_state(#{uidvalidity => 123,
                                           highestmodseq => 999,
                                           uidnext => 50}),
    ?assertEqual(123, mailio_imap_map:state_uidvalidity(State)),
    ?assertEqual(999, mailio_imap_map:state_modseq(State)),
    ?assertEqual(50, mailio_imap_map:state_uidnext(State)).

state_initial_test() ->
    ?assertEqual(undefined, mailio_imap_map:state_uidvalidity(initial)),
    ?assertEqual(undefined, mailio_imap_map:state_modseq(initial)).
