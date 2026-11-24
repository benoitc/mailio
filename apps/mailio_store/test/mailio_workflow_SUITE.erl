%%% @doc M8 mutations, actions, and rules-engine suite.
-module(mailio_workflow_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("mailio_store.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    set_keyword_patch/1,
    set_move_and_destroy/1,
    actions_batch/1,
    rule_auto_tag_and_move/1,
    rule_no_match_untouched/1,
    rule_effectively_once/1,
    rule_stop_processing/1,
    slow_handler_does_not_block/1,
    failed_handler_is_retried/1,
    attempts_are_bounded/1,
    failed_effect_fails_the_job/1,
    flaky_effect/2
]).

all() ->
    [
        set_keyword_patch,
        set_move_and_destroy,
        actions_batch,
        rule_auto_tag_and_move,
        rule_no_match_untouched,
        rule_effectively_once,
        rule_stop_processing,
        slow_handler_does_not_block,
        failed_handler_is_retried,
        attempts_are_bounded,
        failed_effect_fails_the_job
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

init_per_testcase(_TC, Config) ->
    Account = list_to_binary("WF" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    [{account, Account} | Config].

end_per_testcase(_TC, Config) ->
    Account = ?config(account, Config),
    try
        mailio_accounts_sup:stop_account(Account)
    catch
        _:_ -> ok
    end,
    try
        mailio_db:delete_db(mailio_account:db_name(Account))
    catch
        _:_ -> ok
    end,
    ok.

%%====================================================================
%% Email/set
%%====================================================================

set_keyword_patch(Config) ->
    Account = ?config(account, Config),
    {ok, Id} = ingest(Account, <<"inbox">>, msg(<<"a@x">>, <<"Hi">>), []),

    {ok, #{<<"updated">> := Up}} = mailio_email:set(
        Account, #{update => #{Id => #{<<"keywords/$flagged">> => true}}}, #{}
    ),
    ?assert(maps:is_key(Id, Up)),
    ?assert(has_kw(Account, Id, ?KW_FLAGGED)),

    {ok, _} = mailio_email:set(
        Account,
        #{
            update => #{
                Id => #{
                    <<"keywords/$flagged">> => null,
                    <<"keywords/$seen">> => true
                }
            }
        },
        #{}
    ),
    ?assertNot(has_kw(Account, Id, ?KW_FLAGGED)),
    ?assert(has_kw(Account, Id, ?KW_SEEN)),

    %% Marking seen dropped the unread counter.
    {ok, Mbx} = mailio_db:get(db(Account), <<?ID_MAILBOX, "inbox">>),
    ?assertEqual(0, maps:get(<<"unreadEmails">>, Mbx)).

set_move_and_destroy(Config) ->
    Account = ?config(account, Config),
    {ok, Id} = ingest(Account, <<"inbox">>, msg(<<"a@x">>, <<"Hi">>), []),

    {ok, _} = mailio_email:set(
        Account, #{update => #{Id => #{<<"mailboxIds">> => #{<<"archive">> => true}}}}, #{}
    ),
    {ok, E} = mailio_db:get(db(Account), <<?ID_EMAIL, Id/binary>>),
    ?assertEqual([<<"archive">>], maps:keys(maps:get(<<"mailboxIds">>, E))),

    {ok, #{<<"destroyed">> := D}} = mailio_email:set(
        Account, #{destroy => [Id]}, #{}
    ),
    ?assertEqual([Id], D),
    ?assertEqual({error, not_found}, mailio_db:get(db(Account), <<?ID_EMAIL, Id/binary>>)).

actions_batch(Config) ->
    Account = ?config(account, Config),
    {ok, Id} = ingest(Account, <<"inbox">>, msg(<<"a@x">>, <<"Hi">>), []),
    ok = mailio_actions:apply(Account, Id, [{mark, read}, {add_keywords, [<<"tag1">>]}]),
    ?assert(has_kw(Account, Id, ?KW_SEEN)),
    ?assert(has_kw(Account, Id, <<"tag1">>)).

%%====================================================================
%% Rules engine
%%====================================================================

rule_auto_tag_and_move(Config) ->
    Account = ?config(account, Config),
    {ok, _} = mailio_rules:add(
        Account,
        #{
            name => <<"github">>,
            'when' => #{from => <<"github">>},
            actions => [
                #{<<"type">> => <<"add_keywords">>, <<"keywords">> => [<<"notif">>]},
                #{<<"type">> => <<"move">>, <<"mailbox">> => <<"archive">>}
            ]
        }
    ),
    {ok, Pid} = mailio_rules:start_consumer(Account),

    {ok, Id} = ingest(Account, <<"inbox">>, msg(<<"notifications@github.com">>, <<"PR">>), []),
    {ok, N} = mailio_workflow_consumer:run(Pid),
    ?assert(N >= 1),

    {ok, E} = mailio_db:get(db(Account), <<?ID_EMAIL, Id/binary>>),
    ?assert(maps:is_key(<<"notif">>, maps:get(<<"keywords">>, E))),
    ?assertEqual([<<"archive">>], maps:keys(maps:get(<<"mailboxIds">>, E))).

rule_no_match_untouched(Config) ->
    Account = ?config(account, Config),
    {ok, _} = mailio_rules:add(
        Account,
        #{
            'when' => #{from => <<"github">>},
            actions => [#{<<"type">> => <<"add_keywords">>, <<"keywords">> => [<<"notif">>]}]
        }
    ),
    {ok, Pid} = mailio_rules:start_consumer(Account),
    {ok, Id} = ingest(Account, <<"inbox">>, msg(<<"alice@example.com">>, <<"Hi">>), []),
    {ok, _} = mailio_workflow_consumer:run(Pid),
    ?assertNot(has_kw(Account, Id, <<"notif">>)).

rule_effectively_once(Config) ->
    Account = ?config(account, Config),
    {ok, _} = mailio_rules:add(
        Account,
        #{
            'when' => #{from => <<"github">>},
            actions => [#{<<"type">> => <<"add_keywords">>, <<"keywords">> => [<<"notif">>]}]
        }
    ),
    {ok, Pid} = mailio_rules:start_consumer(Account),
    {ok, _Id} = ingest(Account, <<"inbox">>, msg(<<"x@github.com">>, <<"PR">>), []),
    {ok, N1} = mailio_workflow_consumer:run(Pid),
    ?assert(N1 >= 1),
    %% Second drain processes nothing new (job docs already claimed).
    {ok, N2} = mailio_workflow_consumer:run(Pid),
    ?assertEqual(0, N2).

rule_stop_processing(Config) ->
    Account = ?config(account, Config),
    %% Higher-priority rule stops processing; the lower one must not run.
    {ok, _} = mailio_rules:add(
        Account,
        #{
            priority => 10,
            stop_processing => true,
            'when' => #{from => <<"github">>},
            actions => [#{<<"type">> => <<"add_keywords">>, <<"keywords">> => [<<"first">>]}]
        }
    ),
    {ok, _} = mailio_rules:add(
        Account,
        #{
            priority => 1,
            'when' => #{from => <<"github">>},
            actions => [#{<<"type">> => <<"add_keywords">>, <<"keywords">> => [<<"second">>]}]
        }
    ),
    {ok, Pid} = mailio_rules:start_consumer(Account),
    {ok, Id} = ingest(Account, <<"inbox">>, msg(<<"x@github.com">>, <<"PR">>), []),
    {ok, _} = mailio_workflow_consumer:run(Pid),
    ?assert(has_kw(Account, Id, <<"first">>)),
    ?assertNot(has_kw(Account, Id, <<"second">>)).

%%====================================================================
%% Handler isolation and retries
%%====================================================================

consumer(Account, Name, Handler) ->
    {ok, Pid} = mailio_workflow_consumer:start_link(#{
        account_id => Account,
        name => Name,
        types => [email],
        verbs => [created],
        handler => Handler
    }),
    unlink(Pid),
    Pid.

slow_handler_does_not_block(Config) ->
    Account = ?config(account, Config),
    application:set_env(mailio_store, handler_timeout, 300),
    Pid = consumer(Account, <<"slow">>, fun(_A, _E) -> timer:sleep(infinity) end),
    {ok, _} = ingest(Account, <<"inbox">>, msg(<<"a@x">>, <<"one">>), []),
    {Micros, {ok, 0}} = timer:tc(fun() -> mailio_workflow_consumer:run(Pid) end),
    ?assert(Micros < 3000000),
    ?assert(is_process_alive(Pid)),
    application:unset_env(mailio_store, handler_timeout).

failed_handler_is_retried(Config) ->
    Account = ?config(account, Config),
    Tab = ets:new(attempts, [public]),
    Handler = fun(_A, _E) ->
        case ets:update_counter(Tab, n, 1, {n, 0}) of
            1 -> error(first_try_fails);
            _ -> ok
        end
    end,
    Pid = consumer(Account, <<"retry">>, Handler),
    {ok, _} = ingest(Account, <<"inbox">>, msg(<<"a@x">>, <<"one">>), []),
    ?assertEqual({ok, 0}, mailio_workflow_consumer:run(Pid)),
    ?assertEqual({ok, 1}, mailio_workflow_consumer:run(Pid)),
    %% done: never run again
    ?assertEqual({ok, 0}, mailio_workflow_consumer:run(Pid)),
    ?assertEqual(2, ets:lookup_element(Tab, n, 2)).

attempts_are_bounded(Config) ->
    Account = ?config(account, Config),
    Tab = ets:new(attempts, [public]),
    Handler = fun(_A, _E) ->
        ets:update_counter(Tab, n, 1, {n, 0}),
        error(always_fails)
    end,
    Pid = consumer(Account, <<"bounded">>, Handler),
    {ok, _} = ingest(Account, <<"inbox">>, msg(<<"a@x">>, <<"one">>), []),
    [{ok, 0} = mailio_workflow_consumer:run(Pid) || _ <- lists:seq(1, 8)],
    ?assertEqual(3, ets:lookup_element(Tab, n, 2)).

failed_effect_fails_the_job(Config) ->
    Account = ?config(account, Config),
    Tab = ets:new(attempts, [public]),
    application:set_env(mailio_store, actions_call_allowlist, [?MODULE]),
    application:set_env(mailio_store, effect_probe, Tab),
    Handler = fun(A, #{object_id := Id}) ->
        ok = mailio_actions:apply(A, Id, [{call, {?MODULE, flaky_effect}}])
    end,
    Pid = consumer(Account, <<"effects">>, Handler),
    {ok, _} = ingest(Account, <<"inbox">>, msg(<<"a@x">>, <<"one">>), []),
    ?assertEqual({ok, 0}, mailio_workflow_consumer:run(Pid)),
    ?assertEqual({ok, 1}, mailio_workflow_consumer:run(Pid)),
    application:unset_env(mailio_store, actions_call_allowlist),
    application:unset_env(mailio_store, effect_probe).

%% allowlisted effect used above: fails the first time
flaky_effect(_Account, _EmailId) ->
    {ok, Tab} = application:get_env(mailio_store, effect_probe),
    case ets:update_counter(Tab, n, 1, {n, 0}) of
        1 -> error(effect_failed);
        _ -> ok
    end.

%%====================================================================
%% Helpers
%%====================================================================

ingest(Account, Mailbox, Raw, Keywords) ->
    mailio_account:ingest_raw(Account, Mailbox, Raw, #{keywords => Keywords}).

db(Account) -> mailio_account:db_name(Account).

has_kw(Account, EmailId, Kw) ->
    {ok, E} = mailio_db:get(db(Account), <<?ID_EMAIL, EmailId/binary>>),
    mailio_email:has_keyword(E, Kw).

msg(From, Subject) ->
    <<"From: ", From/binary, "\r\n", "To: me@example.com\r\n", "Subject: ", Subject/binary, "\r\n",
        "Message-ID: <", (integer_to_binary(erlang:unique_integer([positive])))/binary, "@x>\r\n",
        "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\n",
        "Content-Type: text/plain; charset=utf-8\r\n\r\n", "Body.\r\n">>.
