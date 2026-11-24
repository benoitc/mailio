%%% @doc Application callback: loads configuration, starts the supervisor
%%% and registers the MCP tools.
-module(mailio_mcp_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = mailio_mcp_config:load_env_file(),
    case mailio_mcp_sup:start_link() of
        {ok, Pid} ->
            ok = mailio_mcp_tools:register(),
            {ok, Pid};
        Other ->
            Other
    end.

stop(_State) ->
    ok.
