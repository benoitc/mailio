%%% @doc Per-account supervision subtree.
%%%
%%% Holds the processes for one account: the account process, its sole
%%% writer, and (when `imap' config is supplied) the sync engine. The
%%% adapter, parser, and submission workers join here in later milestones.
%%% `one_for_one' so the writer, account, and sync engine fail independently
%%% — a sync/adapter crash must not lose the writer's in-memory cursor work.
-module(mailio_account_sup).
-behaviour(supervisor).

-export([start_link/1, start_link/2]).
-export([init/1]).

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(AccountId) ->
    start_link(AccountId, #{}).

-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(AccountId, Opts) ->
    supervisor:start_link(?MODULE, {AccountId, Opts}).

-spec init({binary(), map()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({AccountId, Opts}) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 5,
                 period => 60},
    Base = [
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
    Children = Base ++ sync_child(AccountId, Opts),
    {ok, {SupFlags, Children}}.

sync_child(AccountId, #{imap := AdapterConfig} = Opts) ->
    Args = #{account_id => AccountId,
             adapter => maps:get(adapter, Opts, mailio_imap),
             adapter_config => AdapterConfig,
             watch_mailbox => maps:get(watch_mailbox, Opts, <<"INBOX">>)},
    [#{id => sync,
       start => {mailio_sync_mgr, start_link, [Args]},
       restart => transient,
       shutdown => 5000,
       type => worker,
       modules => [mailio_sync_mgr]}];
sync_child(_AccountId, _Opts) ->
    [].
