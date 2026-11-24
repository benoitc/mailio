-module(mailio_mcp_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => store, start => {mailio_mcp_store, start_link, []}},
        #{id => cache, start => {mailio_mcp_cache, start_link, []}},
        #{id => send, start => {mailio_mcp_send, start_link, []}},
        %% After the send server: when it restarts, its workers are stopped.
        #{
            id => send_workers,
            start => {mailio_mcp_send_workers, start_link, []},
            type => supervisor
        }
    ],
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children}}.
