%%% @doc Root supervisor.
%%%
%%% Holds the static infrastructure layer. The dynamic per-account session
%%% layer lives under {@link mailio_accounts_sup}. Milestones add children
%%% here (events, pools, workflow, submit) as those subsystems land.
-module(mailio_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 3,
                 period => 30},
    Children = [
        #{id => mailio_registry,
          start => {mailio_registry, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mailio_registry]},
        #{id => mailio_events,
          start => {mailio_events, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mailio_events]},
        #{id => mailio_accounts_sup,
          start => {mailio_accounts_sup, start_link, []},
          restart => permanent,
          shutdown => infinity,
          type => supervisor,
          modules => [mailio_accounts_sup]}
    ],
    {ok, {SupFlags, Children}}.
