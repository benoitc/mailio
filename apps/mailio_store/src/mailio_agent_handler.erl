%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Behaviour for AI-assisted processing handlers.
%%%
%%% An agent handler turns an `{agent_task, Kind, Opts}' action (raised by a
%%% rule or another agent) into more actions. The output goes through the
%%% same audited {@link mailio_actions} executor as rules, so AI suggestions
%%% are constrained to the supported, allowlisted action vocabulary — the
%%% model cannot invoke arbitrary code or bypass the writer.
%%%
%%% Handlers may be slow (a model call); they run in a worker isolated from
%%% the consumer, with the caller responsible for timeouts.
-module(mailio_agent_handler).

-callback handle_task(
    Kind :: binary(),
    Account :: binary(),
    EmailId :: binary(),
    Opts :: map()
) ->
    {ok, [term()]} | {error, term()}.
