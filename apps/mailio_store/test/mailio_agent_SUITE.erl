%%% @doc M8 agent surface suite: grants, scope/mailbox enforcement, search,
%%% context window, tag/mark + audit.
-module(mailio_agent_SUITE).

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
    open_requires_valid_grant/1,
    search_filters_to_visible_mailboxes/1,
    scope_enforced/1,
    tag_and_mark_with_audit/1,
    context_window_budget/1
]).

all() ->
    [
        open_requires_valid_grant,
        search_filters_to_visible_mailboxes,
        scope_enforced,
        tag_and_mark_with_audit,
        context_window_budget
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
    Account = list_to_binary("AG" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = mailio_accounts_sup:start_account(Account),
    {ok, I1} = ingest(
        Account,
        <<"inbox">>,
        msg(
            <<"alice@example.com">>,
            <<"Hello team">>,
            <<"e1@x">>,
            undefined
        )
    ),
    {ok, I2} = ingest(
        Account,
        <<"inbox">>,
        reply(
            <<"bob@example.com">>,
            <<"Re: Hello team">>,
            <<"e2@x">>,
            <<"e1@x">>
        )
    ),
    {ok, P1} = ingest(
        Account,
        <<"private">>,
        msg(
            <<"carol@example.com">>,
            <<"Secret">>,
            <<"p1@x">>,
            undefined
        )
    ),
    [{account, Account}, {i1, I1}, {i2, I2}, {p1, P1} | Config].

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
    try
        mailio_grant:delete(<<"agent1">>)
    catch
        _:_ -> ok
    end,
    ok.

%%====================================================================

open_requires_valid_grant(Config) ->
    Account = ?config(account, Config),
    {ok, _} = mailio_grant:create(#{
        agent_id => <<"agent1">>,
        secret => <<"s3cret">>,
        accounts => #{Account => #{scopes => [search, read]}}
    }),
    ?assertEqual({error, denied}, mailio_agent:open(<<"agent1">>, <<"wrong">>)),
    ?assertMatch({ok, _}, mailio_agent:open(<<"agent1">>, <<"s3cret">>)),
    ?assertEqual({error, denied}, mailio_agent:open(<<"ghost">>, <<"x">>)),

    ok = mailio_grant:revoke(<<"agent1">>),
    ?assertEqual({error, denied}, mailio_agent:open(<<"agent1">>, <<"s3cret">>)).

search_filters_to_visible_mailboxes(Config) ->
    Account = ?config(account, Config),
    %% Agent may see inbox only; the private mailbox is denied.
    {ok, _} = mailio_grant:create(#{
        agent_id => <<"agent1">>,
        accounts => #{
            Account => #{
                scopes => [search, read],
                mailbox_allow => [<<"inbox">>],
                mailbox_deny => [<<"private">>]
            }
        }
    }),
    {ok, S} = mailio_agent:open(<<"agent1">>),

    {ok, All} = mailio_agent:search(S, Account, #{}),
    Ids = [maps:get(<<"id">>, R) || R <- All],
    ?assert(lists:member(?config(i1, Config), Ids)),
    ?assert(lists:member(?config(i2, Config), Ids)),
    %% private hidden
    ?assertNot(lists:member(?config(p1, Config), Ids)),

    %% Even a direct text match in the private mailbox stays hidden.
    {ok, Secret} = mailio_agent:search(S, Account, #{text => <<"Secret">>}),
    ?assertEqual([], Secret).

scope_enforced(Config) ->
    Account = ?config(account, Config),
    {ok, _} = mailio_grant:create(#{
        agent_id => <<"agent1">>,
        %% no tag/mark/read
        accounts => #{Account => #{scopes => [search]}}
    }),
    {ok, S} = mailio_agent:open(<<"agent1">>),
    ?assertMatch({ok, _}, mailio_agent:search(S, Account, #{})),
    ?assertEqual(
        {error, denied},
        mailio_agent:tag(
            S,
            Account,
            [?config(i1, Config)],
            #{add => [<<"x">>]}
        )
    ),
    ?assertEqual({error, denied}, mailio_agent:get_thread(S, Account, <<"whatever">>)),
    %% Account not in the grant at all.
    ?assertEqual({error, denied}, mailio_agent:search(S, <<"OTHER">>, #{})).

tag_and_mark_with_audit(Config) ->
    Account = ?config(account, Config),
    I1 = ?config(i1, Config),
    {ok, _} = mailio_grant:create(#{
        agent_id => <<"agent1">>,
        accounts => #{Account => #{scopes => [tag, mark, read]}}
    }),
    {ok, S} = mailio_agent:open(<<"agent1">>),

    {ok, #{<<"updated">> := U}} = mailio_agent:tag(
        S,
        Account,
        [I1],
        #{add => [<<"todo">>, ?KW_SEEN]}
    ),
    ?assertEqual([I1], U),
    {ok, E} = mailio_db:get(db(Account), <<?ID_EMAIL, I1/binary>>),
    ?assert(maps:is_key(<<"todo">>, maps:get(<<"keywords">>, E))),
    %% System keyword not settable via tag.
    ?assertNot(maps:is_key(?KW_SEEN, maps:get(<<"keywords">>, E))),

    {ok, _} = mailio_agent:mark(S, Account, [I1], read),
    {ok, E2} = mailio_db:get(db(Account), <<?ID_EMAIL, I1/binary>>),
    ?assert(mailio_email:is_seen(E2)),

    %% Audit docs were written and stamped with the agent id.
    {ok, Audits} = mailio_db:by_id_prefix(db(Account), <<"audit/">>),
    ?assert(length(Audits) >= 2),
    ?assert(lists:all(fun(A) -> maps:get(<<"agentId">>, A) =:= <<"agent1">> end, Audits)).

context_window_budget(Config) ->
    Account = ?config(account, Config),
    I1 = ?config(i1, Config),
    {ok, _} = mailio_grant:create(#{
        agent_id => <<"agent1">>,
        accounts => #{Account => #{scopes => [read]}}
    }),
    {ok, S} = mailio_agent:open(<<"agent1">>),
    {ok, E} = mailio_db:get(db(Account), <<?ID_EMAIL, I1/binary>>),
    ThreadId = mailio_email:thread_id(E),

    {ok, Ctx} = mailio_agent:context_window(
        S,
        Account,
        {thread, ThreadId},
        #{max_tokens => 4000}
    ),
    Text = maps:get(<<"text">>, Ctx),
    ?assert(binary:match(Text, <<"Hello">>) =/= nomatch),
    ?assert(length(maps:get(<<"included">>, Ctx)) >= 1),
    ?assert(maps:get(<<"token_estimate">>, Ctx) > 0),

    %% A tiny budget truncates.
    {ok, Tiny} = mailio_agent:context_window(
        S,
        Account,
        {thread, ThreadId},
        #{max_tokens => 1}
    ),
    ?assert(maps:get(<<"truncated">>, Tiny)).

%%====================================================================
%% Helpers
%%====================================================================

ingest(Account, Mailbox, Raw) ->
    mailio_account:ingest_raw(Account, Mailbox, Raw, #{}).

db(Account) -> mailio_account:db_name(Account).

msg(From, Subject, MsgId, _Ref) ->
    <<"From: ", From/binary, "\r\n", "To: me@example.com\r\n", "Subject: ", Subject/binary, "\r\n",
        "Message-ID: <", MsgId/binary, ">\r\n", "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\n",
        "Content-Type: text/plain; charset=utf-8\r\n\r\n", "This is the body about ",
        Subject/binary, ".\r\n">>.

reply(From, Subject, MsgId, Ref) ->
    <<"From: ", From/binary, "\r\n", "To: me@example.com\r\n", "Subject: ", Subject/binary, "\r\n",
        "Message-ID: <", MsgId/binary, ">\r\n", "In-Reply-To: <", Ref/binary, ">\r\n",
        "References: <", Ref/binary, ">\r\n", "Date: Mon, 2 Jun 2025 10:00:00 +0000\r\n",
        "Content-Type: text/plain; charset=utf-8\r\n\r\n", "Replying about ", Subject/binary,
        ".\r\n">>.
