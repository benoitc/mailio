-module(mailio_blob_files_tests).
-include_lib("eunit/include/eunit.hrl").

with_root(Fun) ->
    Root = filename:join(
        "/tmp", "mailio_blob_files_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Root, "x")),
    try
        Fun(Root)
    after
        os:cmd("rm -rf " ++ Root)
    end.

hex(Bin) -> mailio_id:blob_hex(Bin).

roundtrip_test() ->
    with_root(fun(Root) ->
        Data = <<"From: a@b\r\n\r\nhello">>,
        H = hex(Data),
        ?assertNot(mailio_blob_files:exists(Root, <<"acct">>, H)),
        ?assertEqual(ok, mailio_blob_files:put(Root, <<"acct">>, H, Data)),
        ?assert(mailio_blob_files:exists(Root, <<"acct">>, H)),
        ?assertEqual({ok, Data}, mailio_blob_files:get(Root, <<"acct">>, H)),
        ?assertEqual({ok, byte_size(Data)}, mailio_blob_files:size(Root, <<"acct">>, H)),
        %% the layout: a two-digit shard, then the full hash
        {ok, Path} = mailio_blob_files:path(Root, <<"acct">>, H),
        ?assertEqual(
            filename:join([Root, "acct", binary_to_list(binary:part(H, 0, 2)), binary_to_list(H)]),
            Path
        ),
        ?assertEqual([H], mailio_blob_files:list(Root, <<"acct">>))
    end).

identical_content_is_one_file_test() ->
    with_root(fun(Root) ->
        Data = <<"same bytes">>,
        H = hex(Data),
        ok = mailio_blob_files:put(Root, <<"a">>, H, Data),
        ok = mailio_blob_files:put(Root, <<"a">>, H, Data),
        ?assertEqual([H], mailio_blob_files:list(Root, <<"a">>)),
        %% the same content in another account is stored there, separately
        ok = mailio_blob_files:put(Root, <<"b">>, H, Data),
        ?assertEqual([H], mailio_blob_files:list(Root, <<"b">>))
    end).

wrong_bytes_for_a_name_are_refused_test() ->
    with_root(fun(Root) ->
        H = hex(<<"what the name promises">>),
        ?assertEqual(
            {error, hash_mismatch}, mailio_blob_files:put(Root, <<"a">>, H, <<"something else">>)
        ),
        ?assertNot(mailio_blob_files:exists(Root, <<"a">>, H)),
        ?assertEqual([], mailio_blob_files:list(Root, <<"a">>))
    end).

names_cannot_escape_the_store_test() ->
    with_root(fun(Root) ->
        Data = <<"x">>,
        H = hex(Data),
        Bad = [<<"..">>, <<"../etc">>, <<"a/b">>, <<"">>, <<"tmp">>, <<"corrupt">>, <<".hidden">>],
        lists:foreach(
            fun(S) -> ?assertEqual({error, bad_name}, mailio_blob_files:put(Root, S, H, Data)) end,
            Bad
        ),
        BadHex = [
            <<"../../etc/passwd">>, <<"ABCDEF">>, binary:copy(<<"g">>, 64), binary:copy(<<"a">>, 63)
        ],
        lists:foreach(
            fun(X) ->
                ?assertEqual({error, bad_name}, mailio_blob_files:put(Root, <<"a">>, X, Data))
            end,
            BadHex
        ),
        ?assertEqual({error, bad_name}, mailio_blob_files:get(Root, <<"a">>, <<"../x">>)),
        %% nothing was written, anywhere
        ?assertEqual([], filelib:wildcard(filename:join(Root, "**")))
    end).

delete_is_idempotent_test() ->
    with_root(fun(Root) ->
        Data = <<"gone soon">>,
        H = hex(Data),
        ok = mailio_blob_files:put(Root, <<"a">>, H, Data),
        ?assertEqual(ok, mailio_blob_files:delete(Root, <<"a">>, H)),
        ?assertEqual(ok, mailio_blob_files:delete(Root, <<"a">>, H)),
        ?assertEqual({error, not_found}, mailio_blob_files:get(Root, <<"a">>, H))
    end).

verify_finds_a_damaged_file_test() ->
    with_root(fun(Root) ->
        Data = <<"original">>,
        H = hex(Data),
        ok = mailio_blob_files:put(Root, <<"a">>, H, Data),
        ?assertEqual(ok, mailio_blob_files:verify(Root, <<"a">>, H)),
        {ok, Path} = mailio_blob_files:path(Root, <<"a">>, H),
        ok = file:write_file(Path, <<"tampered">>),
        ?assertEqual({error, corrupt}, mailio_blob_files:verify(Root, <<"a">>, H)),
        ?assertEqual(
            {error, not_found}, mailio_blob_files:verify(Root, <<"a">>, hex(<<"never stored">>))
        ),
        %% a damaged file is moved aside, not served and not lost
        ?assertEqual(ok, mailio_blob_files:quarantine(Root, <<"a">>, H)),
        ?assertNot(mailio_blob_files:exists(Root, <<"a">>, H)),
        ?assert(filelib:is_regular(filename:join([Root, "a", "corrupt", binary_to_list(H)])))
    end).

%% A crash between writing and renaming leaves a temporary file. Readers never
%% see it, and it is cleaned up once it is old enough.
interrupted_write_leaves_only_tmp_test() ->
    with_root(fun(Root) ->
        TmpDir = filename:join([Root, "a", "tmp"]),
        ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
        ok = file:write_file(filename:join(TmpDir, "half-written"), <<"part">>),
        ?assertEqual([], mailio_blob_files:list(Root, <<"a">>)),
        ?assertEqual(0, mailio_blob_files:clean_tmp(Root, <<"a">>, 3600)),
        ?assertEqual(1, mailio_blob_files:clean_tmp(Root, <<"a">>, 0)),
        ?assertEqual({ok, []}, file:list_dir(TmpDir))
    end).

concurrent_writers_of_the_same_content_test() ->
    with_root(fun(Root) ->
        Data = binary:copy(<<"x">>, 200000),
        H = hex(Data),
        Self = self(),
        Pids = [
            spawn_link(fun() -> Self ! {self(), mailio_blob_files:put(Root, <<"a">>, H, Data)} end)
         || _ <- lists:seq(1, 8)
        ],
        Results = [
            receive
                {P, R} -> R
            after 5000 -> timeout
            end
         || P <- Pids
        ],
        ?assertEqual(lists:duplicate(8, ok), Results),
        ?assertEqual({ok, Data}, mailio_blob_files:get(Root, <<"a">>, H)),
        ?assertEqual([H], mailio_blob_files:list(Root, <<"a">>)),
        %% no temporary file is left behind
        ?assertEqual(0, mailio_blob_files:clean_tmp(Root, <<"a">>, 0))
    end).

binary_content_test() ->
    with_root(fun(Root) ->
        Data = crypto:strong_rand_bytes(100000),
        H = hex(Data),
        ok = mailio_blob_files:put(Root, <<"a">>, H, Data),
        ?assertEqual({ok, Data}, mailio_blob_files:get(Root, <<"a">>, H))
    end).
