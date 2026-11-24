%%% @doc Supervisor for one account's sync engine.
%%%
%%% Exists so that a sync engine that keeps crashing exhausts its own restart
%%% budget here, not the account supervisor's. When that happens this
%%% supervisor stops and the account supervisor restarts it, with a fresh
%%% budget; the account and writer processes are not touched.
-module(mailio_sync_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    supervisor:start_link(?MODULE, Args).

init(Args) ->
    Child = #{
        id => sync,
        start => {mailio_sync_mgr, start_link, [Args]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mailio_sync_mgr]
    },
    {ok, {#{strategy => one_for_one, intensity => 10, period => 30}, [Child]}}.
