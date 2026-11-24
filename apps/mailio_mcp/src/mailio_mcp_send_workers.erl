%%% @doc Supervisor for submission workers. One short-lived process per send,
%%% never restarted: a send that died is reported as outcome_unknown by
%%% {@link mailio_mcp_send}, not run a second time.
-module(mailio_mcp_send_workers).
-behaviour(supervisor).

-export([start_link/0, start_worker/1, init/1]).
-export([run/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Run `Fun' in a supervised worker.
-spec start_worker(fun(() -> term())) -> {ok, pid()} | {error, term()}.
start_worker(Fun) when is_function(Fun, 0) ->
    case supervisor:start_child(?MODULE, [Fun]) of
        {ok, Pid} -> {ok, Pid};
        {error, _} = E -> E
    end.

%% @private
run(Fun) ->
    {ok, proc_lib:spawn_link(Fun)}.

init([]) ->
    Child = #{
        id => worker,
        start => {?MODULE, run, []},
        restart => temporary,
        shutdown => brutal_kill,
        type => worker
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, [Child]}}.
