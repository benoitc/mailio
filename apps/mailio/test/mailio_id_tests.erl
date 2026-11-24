%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_id_tests).
-include_lib("eunit/include/eunit.hrl").

email_id_is_deterministic_test() ->
    Raw = <<"From: a@b\r\n\r\nhi">>,
    ?assertEqual(mailio_id:email_id(Raw), mailio_id:email_id(Raw)).

email_id_differs_on_content_test() ->
    ?assertNotEqual(mailio_id:email_id(<<"a">>), mailio_id:email_id(<<"b">>)).

email_id_is_26_chars_test() ->
    ?assertEqual(26, byte_size(mailio_id:email_id(<<"x">>))).

email_id_is_lowercase_base32_test() ->
    Id = mailio_id:email_id(<<"hello world">>),
    ?assert(
        lists:all(
            fun(C) ->
                (C >= $0 andalso C =< $9) orelse
                    (C >= $a andalso C =< $z)
            end,
            binary_to_list(Id)
        )
    ).

ulid_is_26_chars_test() ->
    ?assertEqual(26, byte_size(mailio_id:ulid())).

ulid_is_unique_test() ->
    Ids = [mailio_id:ulid() || _ <- lists:seq(1, 1000)],
    ?assertEqual(1000, length(lists:usort(Ids))).

ulid_is_time_sortable_test() ->
    A = mailio_id:ulid(),
    timer:sleep(2),
    B = mailio_id:ulid(),
    ?assert(A < B).

blob_id_format_test() ->
    Bid = mailio_id:blob_id(<<"data">>),
    ?assertMatch(<<"sha256-", _/binary>>, Bid),
    ?assertEqual(<<"sha256-", (mailio_id:blob_hex(<<"data">>))/binary>>, Bid).

blob_hex_is_64_chars_test() ->
    ?assertEqual(64, byte_size(mailio_id:blob_hex(<<"x">>))).

msgid_hash_is_deterministic_test() ->
    ?assertEqual(
        mailio_id:msgid_hash(<<"<a@b>">>),
        mailio_id:msgid_hash(<<"<a@b>">>)
    ).
