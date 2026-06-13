%%% @doc Per-account supervision subtree.
%%%
%%% Holds the processes for one account. In M3 that is the account process
%%% and its sole writer; the adapter, sync, and ingest workers join here in
%%% later milestones. `one_for_one' so the writer and account fail
%%% independently.
-module(mailio_account_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(AccountId) ->
    supervisor:start_link(?MODULE, AccountId).

-spec init(binary()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(AccountId) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 5,
                 period => 60},
    Children = [
        #{id => account,
          start => {mailio_account, start_link, [AccountId]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mailio_account]},
        #{id => writer,
          start => {mailio_account_writer, start_link, [AccountId]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mailio_account_writer]}
    ],
    {ok, {SupFlags, Children}}.
