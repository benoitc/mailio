%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Dynamic supervisor for per-account session subtrees.
%%%
%%% Uses the modern dynamic-child pattern: a regular `one_for_one'
%%% supervisor with full map child specs added at runtime via
%%% {@link supervisor:start_child/2}. Each account's subtree is keyed by
%%% `{account, AccountId}' so it can be terminated and deleted by id.
%%% No `simple_one_for_one'.
-module(mailio_accounts_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([start_account/1, start_account/2, stop_account/1, which_accounts/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Start a per-account subtree. Idempotent-ish: returns the existing
%% child if already started.
-spec start_account(binary()) -> {ok, pid()} | {error, term()}.
start_account(AccountId) ->
    start_account(AccountId, #{}).

%% @doc Start a per-account subtree. `Opts' may contain `imap =>
%% AdapterConfig' to also start the sync engine.
-spec start_account(binary(), map()) -> {ok, pid()} | {error, term()}.
start_account(AccountId, Opts) when is_binary(AccountId), is_map(Opts) ->
    Spec = #{
        id => {account, AccountId},
        start => {mailio_account_sup, start_link, [AccountId, Opts]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [mailio_account_sup]
    },
    case supervisor:start_child(?SERVER, Spec) of
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} ->
            {ok, Pid};
        {error, already_present} ->
            _ = supervisor:delete_child(?SERVER, {account, AccountId}),
            start_account(AccountId, Opts);
        {error, _} = Err ->
            Err
    end.

-spec stop_account(binary()) -> ok | {error, not_found}.
stop_account(AccountId) when is_binary(AccountId) ->
    Id = {account, AccountId},
    case supervisor:terminate_child(?SERVER, Id) of
        ok -> supervisor:delete_child(?SERVER, Id);
        {error, _} = Err -> Err
    end.

-spec which_accounts() -> [binary()].
which_accounts() ->
    [
        AccountId
     || {{account, AccountId}, _Pid, _Type, _Mods} <-
            supervisor:which_children(?SERVER)
    ].

-spec init([]) -> {ok, {supervisor:sup_flags(), []}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
