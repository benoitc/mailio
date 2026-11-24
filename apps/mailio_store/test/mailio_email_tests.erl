-module(mailio_email_tests).
-include_lib("eunit/include/eunit.hrl").
-include("mailio_store.hrl").

base() ->
    #{<<"id">> => <<"email/abc">>,
      <<"blobId">> => <<"sha256-deadbeef">>,
      <<"mailboxIds">> => #{<<"mbx-1">> => true},
      <<"keywords">> => #{}}.

doc_id_roundtrip_test() ->
    ?assertEqual(<<"email/abc">>, mailio_email:doc_id(<<"abc">>)),
    ?assertEqual(<<"abc">>, mailio_email:id_of(base())).

mailbox_membership_test() ->
    E = base(),
    ?assert(mailio_email:in_mailbox(E, <<"mbx-1">>)),
    ?assertNot(mailio_email:in_mailbox(E, <<"mbx-2">>)),
    E2 = mailio_email:add_mailbox(E, <<"mbx-2">>),
    ?assert(mailio_email:in_mailbox(E2, <<"mbx-2">>)),
    E3 = mailio_email:remove_mailbox(E2, <<"mbx-1">>),
    ?assertEqual([<<"mbx-2">>], mailio_email:mailbox_ids(E3)).

keyword_helpers_test() ->
    E = base(),
    ?assertNot(mailio_email:is_seen(E)),
    E2 = mailio_email:add_keyword(E, ?KW_SEEN),
    ?assert(mailio_email:is_seen(E2)),
    ?assert(mailio_email:has_keyword(E2, ?KW_SEEN)),
    E3 = mailio_email:remove_keyword(E2, ?KW_SEEN),
    ?assertNot(mailio_email:is_seen(E3)),
    ?assertEqual([], mailio_email:keywords(E3)).

imap_entries_dedup_test() ->
    E = base(),
    Entry = #{<<"uid">> => 10, <<"uidvalidity">> => 1, <<"modseq">> => 5},
    E2 = mailio_email:add_imap_entry(E, <<"mbx-1">>, Entry),
    E3 = mailio_email:add_imap_entry(E2, <<"mbx-1">>, Entry),
    %% Same uid+uidvalidity collapses, not duplicated.
    ?assertEqual(1, length(mailio_email:imap_entries(E3, <<"mbx-1">>))).

imap_entries_duplicate_delivery_test() ->
    %% Two different UIDs in the same mailbox (duplicate delivery) are
    %% both retained under one email.
    E = base(),
    E2 = mailio_email:add_imap_entry(E, <<"mbx-1">>,
            #{<<"uid">> => 10, <<"uidvalidity">> => 1}),
    E3 = mailio_email:add_imap_entry(E2, <<"mbx-1">>,
            #{<<"uid">> => 11, <<"uidvalidity">> => 1}),
    ?assertEqual(2, length(mailio_email:imap_entries(E3, <<"mbx-1">>))).
