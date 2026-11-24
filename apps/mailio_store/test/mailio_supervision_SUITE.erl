%%% @doc Supervision tree behaviour: restarts and isolation.
-module(mailio_supervision_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([registry_restart_restarts_accounts/1]).

all() ->
    [registry_restart_restarts_accounts].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    Priv = ?config(priv_dir, Config),
    application:set_env(barrel_docdb, data_dir, Priv),
    application:set_env(mailio_store, data_dir, Priv),
    {ok, _} = application:ensure_all_started(mailio_store),
    Config.

end_per_suite(_Config) ->
    application:stop(mailio_store),
    application:stop(barrel_docdb),
    ok.

wait_for(Fun) -> wait_for(Fun, 50).
wait_for(Fun, 0) ->
    Fun();
wait_for(Fun, N) ->
    case Fun() of
        undefined ->
            timer:sleep(100),
            wait_for(Fun, N - 1);
        false ->
            timer:sleep(100),
            wait_for(Fun, N - 1);
        V ->
            V
    end.

registry_restart_restarts_accounts(_Config) ->
    Acc = <<"SUP1">>,
    {ok, AccSup} = mailio_accounts_sup:start_account(Acc),
    OldRegistry = whereis(mailio_registry),
    OldAccounts = whereis(mailio_accounts_sup),
    exit(OldRegistry, kill),
    NewRegistry = wait_for(fun() ->
        case whereis(mailio_registry) of
            P when P =/= OldRegistry, is_pid(P) -> P;
            _ -> undefined
        end
    end),
    ?assert(is_pid(NewRegistry)),
    NewAccounts = wait_for(fun() ->
        case whereis(mailio_accounts_sup) of
            P when P =/= OldAccounts, is_pid(P) -> P;
            _ -> undefined
        end
    end),
    ?assert(is_pid(NewAccounts)),
    ?assertNot(is_process_alive(AccSup)),
    ?assertEqual([], mailio_accounts_sup:which_accounts()),
    {ok, _} = mailio_accounts_sup:start_account(Acc),
    ?assertMatch({ok, _}, mailio_registry:lookup({writer, Acc})),
    ok = mailio_accounts_sup:stop_account(Acc).
