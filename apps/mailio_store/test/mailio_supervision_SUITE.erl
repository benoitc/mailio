%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Supervision tree behaviour: restarts and isolation.
-module(mailio_supervision_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    registry_restart_restarts_accounts/1,
    unreachable_server_keeps_account_up/1,
    sync_connects_when_server_appears/1,
    sync_crash_loop_spares_the_writer/1
]).

all() ->
    [
        registry_restart_restarts_accounts,
        unreachable_server_keeps_account_up,
        sync_connects_when_server_appears,
        sync_crash_loop_spares_the_writer
    ].

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

free_port() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, P} = inet:port(L),
    gen_tcp:close(L),
    P.

imap_cfg(Port) ->
    #{
        host => <<"127.0.0.1">>,
        port => Port,
        tls => false,
        username => <<"u">>,
        password => <<"p">>
    }.

unreachable_server_keeps_account_up(_Config) ->
    Acc = <<"SUP2">>,
    {ok, AccSup} = mailio_accounts_sup:start_account(Acc, #{
        imap => imap_cfg(free_port()), connect_retry_ms => 100
    }),
    %% longer than the old restart window
    timer:sleep(1500),
    ?assert(is_process_alive(AccSup)),
    ?assertEqual([Acc], mailio_accounts_sup:which_accounts()),
    ?assertMatch({ok, _}, mailio_registry:lookup({writer, Acc})),
    ?assertEqual({error, not_connected}, mailio_sync_mgr:sync_all(Acc)),
    ok = mailio_accounts_sup:stop_account(Acc).

sync_connects_when_server_appears(_Config) ->
    Acc = <<"SUP3">>,
    Port = free_port(),
    {ok, _} = mailio_accounts_sup:start_account(Acc, #{
        imap => imap_cfg(Port), connect_retry_ms => 100
    }),
    ?assertEqual({error, not_connected}, mailio_sync_mgr:sync_all(Acc)),
    Srv = mailio_fake_imap:start(#{port => Port}),
    Result = wait_for(fun() ->
        case mailio_sync_mgr:sync_all(Acc) of
            {ok, _} = Ok -> Ok;
            _ -> undefined
        end
    end),
    ?assertMatch({ok, _}, Result),
    mailio_fake_imap:stop(Srv),
    ok = mailio_accounts_sup:stop_account(Acc).

sync_crash_loop_spares_the_writer(_Config) ->
    Acc = <<"SUP4">>,
    Srv = mailio_fake_imap:start(),
    {ok, AccSup} = mailio_accounts_sup:start_account(Acc, #{
        imap => imap_cfg(mailio_fake_imap:port(Srv))
    }),
    {ok, Writer} = mailio_registry:lookup({writer, Acc}),
    lists:foreach(
        fun(_) ->
            case mailio_registry:lookup({sync, Acc}) of
                {ok, P} -> exit(P, kill);
                _ -> ok
            end,
            timer:sleep(100)
        end,
        lists:seq(1, 15)
    ),
    timer:sleep(300),
    ?assert(is_process_alive(AccSup)),
    ?assertEqual({ok, Writer}, mailio_registry:lookup({writer, Acc})),
    mailio_fake_imap:stop(Srv),
    ok = mailio_accounts_sup:stop_account(Acc).
