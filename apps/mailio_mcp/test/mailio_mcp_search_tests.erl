%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% Search regressions against mailio_fake_imap: a refused metadata FETCH is
%%% an error and not an empty mailbox, the cache key isolates queries, a
%%% count_only search does no fingerprint work, and one deadline covers every
%%% account of a request. The POP3 index scan is tested against the store.
-module(mailio_mcp_search_tests).
-include_lib("eunit/include/eunit.hrl").

imap_account(Id, Port) ->
    #{
        id => Id,
        incoming => #{protocol => imap, host => "127.0.0.1", port => Port, tls => none},
        auth => #{user => <<"u">>, secret => {value, <<"p">>}, mechanism => login}
    }.

with(Fun) ->
    ok = mailio_mcp_stats:init(),
    application:set_env(
        mailio_mcp,
        data_dir,
        "/tmp/mcp_search_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, Store} = mailio_mcp_store:start_link(),
    {ok, Cache} = mailio_mcp_cache:start_link(),
    Srv = mailio_fake_imap:start(),
    Acc = imap_account(<<"fake">>, mailio_fake_imap:port(Srv)),
    ok = application:set_env(mailio_mcp, accounts, [Acc]),
    ok = application:set_env(mailio_mcp, principals, [
        #{id => <<"p1">>, grants => #{<<"fake">> => #{role => read, identities => []}}}
    ]),
    try
        Fun(Srv, Acc)
    after
        mailio_fake_imap:stop(Srv),
        unlink(Cache),
        exit(Cache, shutdown),
        unlink(Store),
        exit(Store, shutdown),
        timer:sleep(50),
        ok = application:unset_env(mailio_mcp, accounts),
        ok = application:unset_env(mailio_mcp, principals),
        ok = application:unset_env(mailio_mcp, limits),
        ok = application:unset_env(mailio_mcp, data_dir)
    end.

run(Args) -> mailio_mcp_search:run(<<"p1">>, Args#{<<"account_ids">> => [<<"fake">>]}).

has_text_fetch(Cmds) ->
    lists:any(fun(C) -> re:run(C, <<"BODY.PEEK\\[TEXT\\]">>) =/= nomatch end, Cmds).

%% A refused metadata FETCH is an error for the account, not a complete,
%% empty result.
meta_fetch_refusal_is_an_error_test() ->
    with(fun(Srv, Acc) ->
        ok = mailio_fake_imap:set_failure(Srv, meta, true),
        ?assertMatch(
            {error, {server_no, _}}, mailio_mcp_imap:search(Acc, #{mailboxes => [<<"INBOX">>]})
        )
    end).

%% Two different queries whose phash2 bucket collided under the old cache
%% key: the second query must reach the server again instead of being served
%% the first query's cached result. The texts below are a verified collision
%% pair for the per-account query map this suite builds.
cache_key_isolates_queries_test() ->
    with(fun(Srv, _Acc) ->
        {ok, _} = run(#{<<"text">> => <<"gb84940c4u">>}),
        N1 = length(mailio_fake_imap:commands(Srv)),
        {ok, _} = run(#{<<"text">> => <<"1qjz4qd03w">>}),
        N2 = length(mailio_fake_imap:commands(Srv)),
        ?assert(N2 > N1)
    end).

%% count_only does no fingerprint work: no body fetch, and the occurrence
%% count is reported as approximate because copies may have to be merged.
count_only_skips_fingerprints_test() ->
    with(fun(Srv, _Acc) ->
        ok = mailio_fake_imap:set_option(Srv, meta_headers, true),
        ok = mailio_fake_imap:deliver(Srv, <<"Dup one">>),
        ok = mailio_fake_imap:deliver(Srv, <<"Dup two">>),
        {ok, Env} = run(#{<<"count_only">> => true}),
        ?assertEqual(4, maps:get(<<"count">>, Env)),
        ?assert(maps:get(<<"count_approximate">>, Env)),
        ?assertNot(has_text_fetch(mailio_fake_imap:commands(Srv)))
    end).

%% Without count_only the copy grouping still runs: the two delivered
%% messages share a Message-ID, so the provider is asked for fingerprints.
grouping_still_runs_without_count_only_test() ->
    with(fun(Srv, _Acc) ->
        ok = mailio_fake_imap:set_option(Srv, meta_headers, true),
        ok = mailio_fake_imap:deliver(Srv, <<"Dup one">>),
        ok = mailio_fake_imap:deliver(Srv, <<"Dup two">>),
        {ok, _} = run(#{<<"fields">> => [<<"subject">>, <<"copies">>]}),
        ?assert(has_text_fetch(mailio_fake_imap:commands(Srv)))
    end).

%% The deadline created once in run/2 covers every stage: account workers,
%% fingerprint workers and excerpt fetching. One account never answers, so
%% the account stage consumes the whole budget; the other account returns
%% two hits sharing a Message-ID, whose fingerprint fetches then hang on a
%% server that never answers a body-section fetch. A deadline that restarts
%% for the fingerprint stage would let them wait the full budget again.
deadline_covers_stalled_stages_test_() ->
    {timeout, 30, fun deadline_covers_stalled_stages/0}.

deadline_covers_stalled_stages() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Stall = spawn(fun() -> stall(L) end),
    ok = mailio_mcp_stats:init(),
    application:set_env(
        mailio_mcp,
        data_dir,
        "/tmp/mcp_search_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, Store} = mailio_mcp_store:start_link(),
    {ok, Cache} = mailio_mcp_cache:start_link(),
    Srv = mailio_fake_imap:start(),
    Accs = [
        imap_account(<<"silent">>, Port),
        imap_account(<<"dup">>, mailio_fake_imap:port(Srv))
    ],
    ok = application:set_env(mailio_mcp, accounts, Accs),
    ok = application:set_env(mailio_mcp, principals, [
        #{
            id => <<"p4">>,
            grants => #{
                <<"silent">> => #{role => read, identities => []},
                <<"dup">> => #{role => read, identities => []}
            }
        }
    ]),
    ok = application:set_env(mailio_mcp, limits, #{search_deadline_ms => 3000}),
    ok = mailio_fake_imap:set_option(Srv, meta_headers, true),
    ok = mailio_fake_imap:set_option(Srv, stall_section, true),
    ok = mailio_fake_imap:deliver(Srv, <<"Dup one">>),
    ok = mailio_fake_imap:deliver(Srv, <<"Dup two">>),
    T0 = erlang:monotonic_time(millisecond),
    try
        {ok, Env} = mailio_mcp_search:run(<<"p4">>, #{
            <<"account_ids">> => [<<"silent">>, <<"dup">>], <<"excerpt">> => true
        }),
        Elapsed = erlang:monotonic_time(millisecond) - T0,
        %% the account stage used the whole budget on the silent account
        ?assert(Elapsed > 2500),
        %% a deadline that restarts for the fingerprint stage would double
        %% the total wait
        ?assert(Elapsed < 5000),
        #{<<"coverage">> := [Cov]} = Env,
        ?assertEqual(<<"offline">>, maps:get(<<"status">>, Cov)),
        ?assertEqual(<<"silent">>, maps:get(<<"account">>, Cov))
    after
        exit(Stall, kill),
        mailio_fake_imap:stop(Srv),
        unlink(Cache),
        exit(Cache, shutdown),
        unlink(Store),
        exit(Store, shutdown),
        timer:sleep(50),
        ok = application:unset_env(mailio_mcp, accounts),
        ok = application:unset_env(mailio_mcp, principals),
        ok = application:unset_env(mailio_mcp, limits),
        ok = application:unset_env(mailio_mcp, data_dir)
    end.

%% Accounts whose servers never answer are all cut off by one shared
%% deadline: the total wait stays at the deadline no matter how many accounts
%% are searched. A deadline that restarts per account (or per stage) would
%% take four times as long here.
shared_deadline_test() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Stall = spawn(fun() -> stall(L) end),
    ok = mailio_mcp_stats:init(),
    application:set_env(
        mailio_mcp,
        data_dir,
        "/tmp/mcp_search_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, Store} = mailio_mcp_store:start_link(),
    {ok, Cache} = mailio_mcp_cache:start_link(),
    Accs = [
        imap_account(<<"slow1">>, Port),
        imap_account(<<"slow2">>, Port),
        imap_account(<<"slow3">>, Port),
        imap_account(<<"slow4">>, Port)
    ],
    ok = application:set_env(mailio_mcp, accounts, Accs),
    ok = application:set_env(mailio_mcp, principals, [
        #{
            id => <<"p2">>,
            grants => #{
                <<"slow1">> => #{role => read, identities => []},
                <<"slow2">> => #{role => read, identities => []},
                <<"slow3">> => #{role => read, identities => []},
                <<"slow4">> => #{role => read, identities => []}
            }
        }
    ]),
    ok = application:set_env(mailio_mcp, limits, #{search_deadline_ms => 500}),
    T0 = erlang:monotonic_time(millisecond),
    try
        {ok, Env} = mailio_mcp_search:run(<<"p2">>, #{
            <<"account_ids">> => [<<"slow1">>, <<"slow2">>, <<"slow3">>, <<"slow4">>]
        }),
        Elapsed = erlang:monotonic_time(millisecond) - T0,
        %% one deadline, not one per account: four waits of 500 ms would
        %% take 2000 ms
        ?assert(Elapsed < 1500),
        #{<<"coverage">> := Cov} = Env,
        ?assertEqual(4, length(Cov)),
        ?assert(lists:all(fun(C) -> maps:get(<<"status">>, C) =:= <<"offline">> end, Cov))
    after
        exit(Stall, kill),
        unlink(Cache),
        exit(Cache, shutdown),
        unlink(Store),
        exit(Store, shutdown),
        timer:sleep(50),
        ok = application:unset_env(mailio_mcp, accounts),
        ok = application:unset_env(mailio_mcp, principals),
        ok = application:unset_env(mailio_mcp, limits),
        ok = application:unset_env(mailio_mcp, data_dir)
    end.

%% Accept connections and never answer, so the client waits for a greeting.
%% The processes are linked, so killing the first one closes every socket.
stall(L) ->
    {ok, S} = gen_tcp:accept(L),
    _ = S,
    spawn_link(fun() -> stall(L) end),
    receive
        never -> ok
    end.

%% On the no-UIDL fallback the header-hash identity can only resolve the
%% newest batch. A mailbox bigger than the batch must report the unresolved
%% messages and partial coverage, not a complete result over a fraction of
%% the mailbox.
pop3_short_batch_is_partial_test() ->
    ok = mailio_mcp_stats:init(),
    application:set_env(
        mailio_mcp,
        data_dir,
        "/tmp/mcp_search_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, Store} = mailio_mcp_store:start_link(),
    {ok, Cache} = mailio_mcp_cache:start_link(),
    Msg =
        <<
            "From: a@x.test\r\nTo: me@x.test\r\nSubject: Batch\r\n"
            "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\nMessage-ID: <b@x>\r\n\r\nBody.\r\n"
        >>,
    Srv = mailio_fake_pop3:start(#{
        messages => [{<<"m1">>, Msg}, {<<"m2">>, Msg}], uidl => false, caps => [<<"TOP">>]
    }),
    Acc = #{
        id => <<"p3acc">>,
        incoming => #{
            protocol => pop3, host => "127.0.0.1", port => mailio_fake_pop3:port(Srv), tls => none
        },
        auth => #{user => <<"u">>, secret => {value, <<"p">>}, mechanism => plain}
    },
    ok = application:set_env(mailio_mcp, accounts, [Acc]),
    ok = application:set_env(mailio_mcp, principals, [
        #{id => <<"p3">>, grants => #{<<"p3acc">> => #{role => read, identities => []}}}
    ]),
    ok = application:set_env(mailio_mcp, limits, #{pop3_index_batch => 1}),
    try
        {ok, Env} = mailio_mcp_search:run(<<"p3">>, #{
            <<"account_ids">> => [<<"p3acc">>],
            <<"subject">> => <<"Batch">>,
            <<"time_basis">> => <<"sent_at">>
        }),
        ?assertEqual(1, maps:get(<<"count">>, Env)),
        ?assert(maps:get(<<"count_approximate">>, Env)),
        #{<<"coverage">> := [Cov]} = Env,
        ?assertEqual(<<"partial">>, maps:get(<<"status">>, Cov))
    after
        mailio_fake_pop3:stop(Srv),
        unlink(Cache),
        exit(Cache, shutdown),
        unlink(Store),
        exit(Store, shutdown),
        timer:sleep(50),
        ok = application:unset_env(mailio_mcp, accounts),
        ok = application:unset_env(mailio_mcp, principals),
        ok = application:unset_env(mailio_mcp, limits),
        ok = application:unset_env(mailio_mcp, data_dir)
    end.

%%--------------------------------------------------------------------
%% POP3 index scan

pop3_index_scan_test_() ->
    {setup,
        fun() ->
            application:set_env(
                mailio_mcp,
                data_dir,
                "/tmp/mcp_search_" ++ integer_to_list(erlang:unique_integer([positive]))
            ),
            {ok, P} = mailio_mcp_store:start_link(),
            P
        end,
        fun(P) ->
            unlink(P),
            exit(P, shutdown),
            timer:sleep(50),
            ok = application:unset_env(mailio_mcp, data_dir)
        end,
        fun(_) ->
            [
                fun() ->
                    Acc = #{id => <<"accp">>},
                    Q = #{mailboxes => [<<"INBOX">>]},
                    Meta = #{
                        from => [],
                        to => [],
                        cc => [],
                        subject => <<"Hello">>,
                        sent_at => undefined,
                        content_type => <<"text/plain">>,
                        size => 10
                    },
                    ok = mailio_mcp_store:put(pop3idx, {<<"accp">>, <<"id1">>}, Meta),
                    {ok, [H], Info} = mailio_mcp_pop3:index_hits(
                        Acc, Q, [{1, <<"id1">>, 10}], #{1 => <<"id1">>}, <<"accp">>, false, 0
                    ),
                    ?assertEqual(<<"Hello">>, maps:get(subject, H)),
                    ?assertNot(maps:get(index_incomplete, Info)),
                    %% an entry whose metadata cannot be read is not a
                    %% non-match: the scan reports an incomplete index
                    {ok, [], Info2} = mailio_mcp_pop3:index_hits(
                        Acc, Q, [{2, <<"id2">>, 10}], #{2 => <<"id2">>}, <<"accp">>, false, 0
                    ),
                    ?assert(maps:get(index_incomplete, Info2))
                end
            ]
        end}.
