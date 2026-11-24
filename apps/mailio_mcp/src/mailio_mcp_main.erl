%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Entry point for running the service as an MCP server.
%%%
%%% stdio: `bin/mailio-mcp' (default). The protocol owns stdout, so
%%% logging goes to stderr.
%%% http:  set `{http, #{port => P, auth => ...}}' in the application env or
%%% run `bin/mailio-mcp http'.
-module(mailio_mcp_main).
-export([run/1]).

run([Mode]) -> run_mode(Mode);
run([]) -> run_mode(stdio).

run_mode(Mode) ->
    ok = to_stderr(),
    ok = mailio_mcp_config:load_env_file(),
    ok = mailio_mcp_config:apply_request_state_key(),
    {ok, _} = application:ensure_all_started(mailio_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    case Mode of
        M when M =:= stdio; M =:= "stdio" ->
            {ok, Pid} = barrel_mcp:start_stdio_link(),
            %% The client closing stdin ends the stdio loop. Exit then, or the
            %% server would run on with nobody to talk to.
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            end;
        M when M =:= http; M =:= "http" ->
            Opts = application:get_env(mailio_mcp, http, #{port => 8420}),
            {ok, _} = barrel_mcp:start_http_stream(Opts),
            wait_forever()
    end.

to_stderr() ->
    _ = logger:remove_handler(default),
    ok = logger:add_handler(stderr, logger_std_h, #{config => #{type => standard_error}}),
    ok.

wait_forever() ->
    receive
        stop -> ok
    end.
