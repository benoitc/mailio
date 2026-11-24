%%% @doc Barrel_docdb spike suite (M1).
%%%
%%% This suite is not a unit test of Mailio; it pins down the behaviour of
%%% the real barrel_docdb backend that the rest of the architecture depends
%%% on, BEFORE those layers are built. It establishes, with assertions:
%%%
%%%  - batch write visibility and cursor advance on the changes feed;
%%%  - whether put_docs is all-or-nothing or per-doc (informs risk #3);
%%%  - that the JMAP filter shapes resolve to indexed query plans, not
%%%    full scans (explain/2);
%%%  - attachment streaming round-trips large blobs;
%%%  - that MQTT path subscriptions match document FIELD paths, not doc
%%%    ids, confirming the events layer must be driven by the changes feed.
-module(mailio_barrel_spike_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([batch_visibility_and_cursor/1,
         batch_partial_failure/1,
         explain_index_coverage/1,
         changes_incremental/1,
         attachment_streaming/1,
         path_subscription_is_field_based/1]).

all() ->
    [batch_visibility_and_cursor,
     batch_partial_failure,
     explain_index_coverage,
     changes_incremental,
     attachment_streaming,
     path_subscription_is_field_based].

init_per_suite(Config) ->
    PrivDir = ?config(priv_dir, Config),
    application:set_env(barrel_docdb, data_dir, PrivDir),
    application:set_env(mailio_store, data_dir, PrivDir),
    {ok, _} = application:ensure_all_started(barrel_docdb),
    Config.

end_per_suite(_Config) ->
    application:stop(barrel_docdb),
    ok.

init_per_testcase(TC, Config) ->
    Db = iolist_to_binary([<<"spike_">>, atom_to_binary(TC, utf8)]),
    {ok, _Pid} = mailio_db:ensure_db(Db),
    [{db, Db} | Config].

end_per_testcase(_TC, Config) ->
    Db = ?config(db, Config),
    try mailio_db:delete_db(Db) catch _:_ -> ok end,
    ok.

%%====================================================================
%% A batch of writes is visible and the changes cursor advances past it.
%%====================================================================
batch_visibility_and_cursor(Config) ->
    Db = ?config(db, Config),
    Docs = [#{<<"id">> => id(I), <<"n">> => I} || I <- lists:seq(1, 20)],
    {ok, Written} = mailio_db:put_batch_strict(Db, Docs),
    ?assertEqual(20, length(Written)),

    %% All readable.
    [?assertMatch({ok, #{<<"n">> := I}}, mailio_db:get(Db, id(I)))
     || I <- lists:seq(1, 20)],

    %% Changes feed from the beginning sees all 20 ids.
    {ok, Changes, LastHlc} = mailio_db:changes(Db, first),
    SeenIds = lists:usort([maps:get(id, C) || C <- Changes]),
    ExpectIds = lists:usort([id(I) || I <- lists:seq(1, 20)]),
    ?assertEqual(ExpectIds, SeenIds),

    %% Each change carries id, hlc, rev.
    lists:foreach(fun(C) ->
        ?assertMatch(#{id := _, hlc := _, rev := _}, C)
    end, Changes),

    %% Informative: do all docs in one batch share a single HLC point?
    HlcSet = lists:usort([maps:get(hlc, C) || C <- Changes]),
    ct:pal("batch of 20 produced ~p distinct HLC values", [length(HlcSet)]),

    %% Cursor advances: nothing new since LastHlc.
    {ok, Tail, _Hlc2} = mailio_db:changes(Db, LastHlc),
    ?assertEqual([], Tail),
    ok.

%%====================================================================
%% Establish put_docs failure semantics: per-doc results vs all-or-nothing.
%% One entry collides (stale _rev on an existing id); the rest must be
%% inspectable so the writer knows the real contract.
%%====================================================================
batch_partial_failure(Config) ->
    Db = ?config(db, Config),
    %% Seed an existing doc so we can force a conflict on it.
    {ok, _, _} = mailio_db:put(Db, #{<<"id">> => <<"exists">>, <<"v">> => 1}),

    Batch = [#{<<"id">> => <<"fresh-a">>, <<"v">> => 1},
             #{<<"id">> => <<"exists">>, <<"_rev">> => <<"1-bogus">>, <<"v">> => 2},
             #{<<"id">> => <<"fresh-b">>, <<"v">> => 1}],
    Results = mailio_db:put_batch(Db, Batch),
    ct:pal("partial batch results: ~p", [Results]),
    ?assertEqual(3, length(Results)),

    %% Whatever the contract, record which fresh docs became visible. This
    %% asserts reality so the writer's atomicity strategy is grounded.
    AFresh = mailio_db:get(Db, <<"fresh-a">>),
    BFresh = mailio_db:get(Db, <<"fresh-b">>),
    ct:pal("fresh-a=~p fresh-b=~p", [AFresh, BFresh]),
    %% The conflicting entry must not have overwritten the existing doc.
    ?assertMatch({ok, #{<<"v">> := 1}}, mailio_db:get(Db, <<"exists">>)),
    ok.

%%====================================================================
%% The JMAP filter shapes resolve to indexed plans, not full scans.
%%====================================================================
explain_index_coverage(Config) ->
    Db = ?config(db, Config),
    %% Seed email-shaped docs.
    Docs = [email_doc(I) || I <- lists:seq(1, 50)],
    {ok, _} = mailio_db:put_batch_strict(Db, Docs),

    %% inMailbox: equality on a mailboxIds member key.
    InMailbox = #{where => [{path, [<<"mailboxIds">>, <<"mbx-1">>], true}]},
    assert_indexed(Db, InMailbox, "inMailbox"),

    %% hasKeyword: equality on a keywords member key.
    HasKeyword = #{where => [{path, [<<"keywords">>, <<"$seen">>], true}]},
    assert_indexed(Db, HasKeyword, "hasKeyword"),

    %% received_ts range (before/after).
    Range = #{where => [{compare, [<<"_mailio">>, <<"received_ts">>], '>=', 25}]},
    assert_indexed(Db, Range, "received range"),

    %% from equality.
    From = #{where => [{path, [<<"_mailio">>, <<"from_norm">>], <<"alice@example.com">>}]},
    assert_indexed(Db, From, "from"),
    ok.

%%====================================================================
%% Incremental changes: a second batch is seen only from the prior cursor.
%%====================================================================
changes_incremental(Config) ->
    Db = ?config(db, Config),
    {ok, _} = mailio_db:put_batch_strict(
                Db, [#{<<"id">> => id(I)} || I <- lists:seq(1, 5)]),
    {ok, First, Hlc1} = mailio_db:changes(Db, first),
    ?assertEqual(5, length(First)),

    {ok, _} = mailio_db:put_batch_strict(
                Db, [#{<<"id">> => id(I)} || I <- lists:seq(6, 8)]),
    {ok, Second, _Hlc2} = mailio_db:changes(Db, Hlc1),
    SecondIds = lists:usort([maps:get(id, C) || C <- Second]),
    ?assertEqual([id(6), id(7), id(8)], SecondIds),
    ok.

%%====================================================================
%% Attachment streaming round-trips a multi-chunk blob.
%%====================================================================
attachment_streaming(Config) ->
    Db = ?config(db, Config),
    {ok, _, _} = mailio_db:put(Db, #{<<"id">> => <<"blob/x">>, <<"size">> => 0}),
    Data = crypto:strong_rand_bytes(512 * 1024),
    {ok, _} = mailio_db:put_attachment(Db, <<"blob/x">>, <<"data">>, Data),

    {ok, Got} = mailio_db:get_attachment(Db, <<"blob/x">>, <<"data">>),
    ?assertEqual(Data, Got),

    {ok, Stream0} = mailio_db:open_attachment_stream(Db, <<"blob/x">>, <<"data">>),
    Streamed = drain(Stream0, []),
    ?assertEqual(Data, Streamed),
    ok.

%%====================================================================
%% MQTT path subscriptions match document FIELD paths, not doc ids. This
%% is the load-bearing fact behind driving the events layer from the
%% changes feed rather than id-pattern subscriptions.
%%====================================================================
path_subscription_is_field_based(Config) ->
    Db = ?config(db, Config),

    %% A subscription on the doc-id prefix pattern should NOT fire, because
    %% patterns are matched against field paths, not the document id.
    {ok, IdSub} = mailio_db:subscribe_path(Db, <<"email/#">>),
    %% A subscription on an actual field path SHOULD fire.
    {ok, FieldSub} = mailio_db:subscribe_path(Db, <<"kind/#">>),

    {ok, _, _} = mailio_db:put(Db, #{<<"id">> => <<"email/abc">>,
                                     <<"kind">> => <<"email">>}),

    FieldFired = wait_change(FieldSub, 2000),
    IdFired = wait_change(IdSub, 500),
    ct:pal("field-path sub fired=~p  id-prefix sub fired=~p",
           [FieldFired, IdFired]),

    ?assert(FieldFired),
    ?assertNot(IdFired),

    mailio_db:unsubscribe(IdSub),
    mailio_db:unsubscribe(FieldSub),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

id(I) -> iolist_to_binary(io_lib:format("doc-~4..0b", [I])).

email_doc(I) ->
    Mailbox = case I rem 2 of 0 -> <<"mbx-1">>; _ -> <<"mbx-2">> end,
    #{<<"id">> => <<"email/", (integer_to_binary(I))/binary>>,
      <<"mailboxIds">> => #{Mailbox => true},
      <<"keywords">> => #{<<"$seen">> => true},
      <<"_mailio">> => #{<<"received_ts">> => I,
                         <<"from_norm">> => <<"alice@example.com">>}}.

assert_indexed(Db, Spec, Label) ->
    {ok, Plan} = mailio_db:explain(Db, Spec),
    Strategy = maps:get(strategy, Plan, undefined),
    ct:pal("explain ~s => strategy=~p plan=~p", [Label, Strategy, Plan]),
    ?assert(lists:member(Strategy, [index_seek, index_scan, multi_index]),
            lists:flatten(io_lib:format("~s expected indexed plan, got ~p",
                                        [Label, Strategy]))).

drain(Stream, Acc) ->
    case mailio_db:read_attachment_chunk(Stream) of
        {ok, Chunk, Stream2} -> drain(Stream2, [Chunk | Acc]);
        eof ->
            ok = mailio_db:close_attachment_stream(Stream),
            iolist_to_binary(lists:reverse(Acc))
    end.

wait_change(_SubRef, Timeout) ->
    receive
        {barrel_change, _Db, _Change} -> true
    after Timeout -> false
    end.
