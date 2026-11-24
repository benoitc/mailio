%%% Send workers: crash, timeout and concurrency cap, with a fake SMTP module.
-module(mailio_mcp_send_tests).
-include_lib("eunit/include/eunit.hrl").

-export([submit/4]).

-define(P, <<"tester">>).
-define(ACC, <<"acc">>).

%% The fake submission module: runs the fun in the app env.
submit(_Account, _From, _Rcpts, _Raw) ->
    {ok, F} = application:get_env(mailio_mcp, test_smtp),
    F().

ok_result() ->
    {ok, #{accepted => [<<"b@example.test">>], rejected => [], code => 250, reply => <<"queued">>}}.

send_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun accepted/0,
        fun crashing_worker/0,
        fun hanging_worker/0,
        fun concurrency_cap/0,
        fun restart_stops_workers/0
    ]}.

setup() ->
    Dir = filename:join(
        "/tmp", "mailio_send_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Acc = mailio_mcp_lib:acct(?ACC, "u", [{<<"me@example.test">>, <<"Me">>}], #{}),
    application:set_env(mailio_mcp, smtp_module, ?MODULE),
    ok = mailio_mcp_lib:start_app(
        Dir,
        [Acc],
        [#{id => ?P, grants => #{?ACC => #{role => send, identities => all}}}]
    ),
    Dir.

cleanup(_Dir) ->
    mailio_mcp_lib:stop_app(),
    application:unset_env(mailio_mcp, smtp_module),
    application:unset_env(mailio_mcp, test_smtp),
    application:unset_env(mailio_mcp, send_timeout),
    application:unset_env(mailio_mcp, max_concurrent_sends).

draft() ->
    {ok, S} = mailio_mcp_draft:save(?P, #{
        <<"account_ids">> => [?ACC],
        <<"to">> => [<<"b@example.test">>],
        <<"subject">> => <<"s">>,
        <<"body">> => <<"hello">>
    }),
    {maps:get(<<"draft_id">>, S), maps:get(<<"revision">>, S)}.

send(Id, Rev, Key) -> mailio_mcp_send:submit(?P, Id, Rev, Key).

status_of({ok, #{<<"status">> := S}}) -> S.

accepted() ->
    application:set_env(mailio_mcp, test_smtp, fun ok_result/0),
    {Id, Rev} = draft(),
    ?assertEqual(<<"accepted">>, status_of(send(Id, Rev, <<"k1">>))).

crashing_worker() ->
    application:set_env(mailio_mcp, test_smtp, fun() -> exit(boom) end),
    {Id, Rev} = draft(),
    %% never reported as a clean failure: the body may have gone out
    ?assertEqual(<<"outcome_unknown">>, status_of(send(Id, Rev, <<"k1">>))),
    %% and never resent
    ?assertMatch({error, {already_submitted, _}}, send(Id, Rev, <<"k2">>)),
    ?assert(is_process_alive(whereis(mailio_mcp_send))).

hanging_worker() ->
    Me = self(),
    application:set_env(mailio_mcp, send_timeout, 200),
    application:set_env(mailio_mcp, test_smtp, fun() ->
        Me ! {worker, self()},
        timer:sleep(infinity)
    end),
    {Id, Rev} = draft(),
    ?assertEqual(<<"outcome_unknown">>, status_of(send(Id, Rev, <<"k1">>))),
    receive
        {worker, W} ->
            timer:sleep(50),
            ?assertNot(is_process_alive(W))
    after 1000 -> ?assert(false)
    end.

concurrency_cap() ->
    Me = self(),
    application:set_env(mailio_mcp, max_concurrent_sends, 2),
    application:set_env(mailio_mcp, test_smtp, fun() ->
        Me ! {up, self()},
        receive
            go -> ok_result()
        end
    end),
    Drafts = [draft() || _ <- lists:seq(1, 3)],
    [{Id1, R1}, {Id2, R2}, {Id3, R3}] = Drafts,
    Spawn = fun(Id, R, K) ->
        spawn_link(fun() -> Me ! {result, K, send(Id, R, K)} end)
    end,
    Spawn(Id1, R1, <<"k1">>),
    Spawn(Id2, R2, <<"k2">>),
    Workers = [
        receive
            {up, W} -> W
        after 2000 -> ?assert(false)
        end
     || _ <- [1, 2]
    ],
    ?assertEqual({error, too_many_sends}, send(Id3, R3, <<"k3">>)),
    %% refused before anything was recorded
    {ok, #{records := Recs}} = mailio_mcp_send:status(?P, Id3),
    ?assertEqual([], Recs),
    [W ! go || W <- Workers],
    [
        receive
            {result, K, R} -> ?assertEqual(<<"accepted">>, status_of(R))
        after 2000 -> ?assert(false)
        end
     || K <- [<<"k1">>, <<"k2">>]
    ],
    %% a slot is free again
    application:set_env(mailio_mcp, test_smtp, fun ok_result/0),
    ?assertEqual(<<"accepted">>, status_of(send(Id3, R3, <<"k3">>))).

restart_stops_workers() ->
    Me = self(),
    application:set_env(mailio_mcp, test_smtp, fun() ->
        Me ! {worker, self()},
        timer:sleep(infinity)
    end),
    {Id, Rev} = draft(),
    Caller = spawn(fun() ->
        try
            send(Id, Rev, <<"k1">>)
        catch
            _:_ -> ok
        end
    end),
    W =
        receive
            {worker, P} -> P
        after 2000 -> ?assert(false)
        end,
    Old = whereis(mailio_mcp_send),
    exit(Old, kill),
    timer:sleep(300),
    ?assertNot(is_process_alive(W)),
    ?assertNotEqual(Old, whereis(mailio_mcp_send)),
    exit(Caller, kill),
    %% the interrupted send is recorded as unknown, not left "sending"
    {ok, #{records := [{_, Rec}]}} = mailio_mcp_send:status(?P, Id),
    ?assertEqual(outcome_unknown, maps:get(status, Rec)).
