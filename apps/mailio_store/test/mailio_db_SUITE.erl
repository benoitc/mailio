%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Listing documents by id prefix must reach the last one, however many
%%% there are: the database answers in chunks.
-module(mailio_db_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    by_id_prefix_returns_every_document/1, fold_visits_every_document_in_batches/1, fold_can_stop/1
]).

all() ->
    [
        by_id_prefix_returns_every_document,
        fold_visits_every_document_in_batches,
        fold_can_stop
    ].

init_per_suite(Config) ->
    Priv = ?config(priv_dir, Config),
    application:set_env(barrel_docdb, data_dir, Priv),
    application:set_env(mailio_store, data_dir, Priv),
    {ok, _} = application:ensure_all_started(mailio_store),
    Config.

end_per_suite(_Config) ->
    application:stop(mailio_store),
    application:stop(barrel_docdb),
    ok.

init_per_testcase(_Case, Config) ->
    Db = list_to_binary("dbs" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = mailio_db:ensure_db(Db),
    [mailio_db:put(Db, #{<<"id">> => doc_id(N), <<"n">> => N}) || N <- lists:seq(1, 2500)],
    %% a neighbour that must not be listed
    {ok, _, _} = mailio_db:put(Db, #{<<"id">> => <<"other/1">>, <<"n">> => 0}),
    [{db, Db} | Config].

end_per_testcase(_Case, Config) ->
    try
        mailio_db:delete_db(?config(db, Config))
    catch
        _:_ -> ok
    end,
    ok.

doc_id(N) -> iolist_to_binary(["item/", string:pad(integer_to_list(N), 6, leading, $0)]).

by_id_prefix_returns_every_document(Config) ->
    {ok, Docs} = mailio_db:by_id_prefix(?config(db, Config), <<"item/">>),
    ?assertEqual(2500, length(Docs)),
    ?assertEqual(2500, length(lists:usort([maps:get(<<"id">>, D) || D <- Docs]))).

fold_visits_every_document_in_batches(Config) ->
    Self = self(),
    Fun = fun(Docs, Acc) ->
        Self ! {batch, length(Docs)},
        {ok, Acc + length(Docs)}
    end,
    {ok, Total} = mailio_db:fold_id_prefix(?config(db, Config), <<"item/">>, 400, Fun, 0),
    ?assertEqual(2500, Total),
    Sizes = drain(),
    ?assert(length(Sizes) >= 7),
    ?assert(lists:max(Sizes) =< 400).

fold_can_stop(Config) ->
    Fun = fun(_Docs, Acc) -> {stop, Acc + 1} end,
    ?assertEqual(
        {stopped, 1}, mailio_db:fold_id_prefix(?config(db, Config), <<"item/">>, 400, Fun, 0)
    ).

drain() ->
    receive
        {batch, N} -> [N | drain()]
    after 0 -> []
    end.
