%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Credential provider behaviour and facade.
%%%
%%% Account documents never store secrets; they reference a provider as
%%% `{Module, ProviderArgs}'. The provider resolves credentials on demand,
%%% which keeps OAuth2 access-token refresh and external secret stores out
%%% of the persistence layer.
%%%
%%% A credential is one of:
%%% <ul>
%%%   <li>`{password, User, Pass}' - plain SASL PLAIN/LOGIN</li>
%%%   <li>`{oauth2, User, AccessToken}' - XOAUTH2 bearer token (OAUTHBEARER is not implemented)</li>
%%%   <li>`{token_fun, Fun}' - lazy/refreshable; Fun/0 yields one of the above</li>
%%%   <li>`{ref, Name}' - a credential kept under a name with `register_ref/2'; the
%%%   name is what a supervised connection is given, so that no secret is in its
%%%   start arguments</li>
%%%   <li>`{provider, {Module, Args}, AccountId, Service}' - a reference: the
%%%   secret is fetched from `Module' each time it is needed and is never part of
%%%   the configuration, which is what lets a supervisor hold the configuration
%%%   without a crash report showing the secret</li>
%%% </ul>
-module(mailio_credentials).

-export([fetch/3, invalidate/3, resolve/1, resolve/2, register_ref/2, forget_ref/1]).

-define(DEFAULT_TIMEOUT, 10000).
-define(DEFAULT_MAX_DEPTH, 8).

-export_type([provider/0, service/0, cred/0]).

-type provider() :: {module(), ProviderArgs :: term()}.
-type service() :: imap | smtp | jmap.
-type cred() ::
    {ref, term()}
    | {provider, provider(), binary(), service()}
    | {password, binary(), binary()}
    | {oauth2, binary(), binary()}
    | {token_fun, fun(() -> {ok, cred()} | {error, term()})}.

-callback fetch(AccountId :: binary(), Service :: service(), ProviderArgs :: term()) ->
    {ok, cred()} | {error, term()}.
-callback invalidate(AccountId :: binary(), Service :: service(), ProviderArgs :: term()) ->
    ok.

%% @doc The credential a provider holds for an account and a service. It is
%% resolved like any other: the provider, and whatever it returns, in one
%% worker under one time limit and one depth limit.
-spec fetch(provider(), binary(), service()) -> {ok, cred()} | {error, term()}.
fetch({Module, _} = Provider, AccountId, Service) when
    is_atom(Module), is_binary(AccountId)
->
    resolve({provider, Provider, AccountId, Service}, #{}).

-spec invalidate(provider(), binary(), service()) -> ok.
invalidate({Module, Args}, AccountId, Service) when
    is_atom(Module), is_binary(AccountId)
->
    Module:invalidate(AccountId, Service, Args).

%% @doc Keep a credential under a name. A supervisor writes the arguments of its
%% children in its reports, so a connection that is supervised is given the name
%% (`{ref, Name}') and not the credential, or a provider's arguments, which may hold
%% a secret. The credential is kept in the node, not in any process's state.
-spec register_ref(term(), cred()) -> ok.
register_ref(Name, Cred) ->
    persistent_term:put({?MODULE, ref, Name}, Cred).

-spec forget_ref(term()) -> ok.
forget_ref(Name) ->
    _ = persistent_term:erase({?MODULE, ref, Name}),
    ok.

%% @doc Turn a credential into a concrete one. A `{password, _, _}' or
%% `{oauth2, _, _}' is returned as it is. Anything else is followed in one worker
%% process that is not the caller: a `{token_fun, F}' is called, a `{provider, ...}'
%% is fetched, a `{ref, Name}' is looked up, and what comes back is followed in
%% turn. The whole chain has one time limit and one depth limit, and when the time
%% is up the worker is killed with whatever it started and linked. Errors:
%% `credentials_loop' (more than `max_depth' links, default 8),
%% `credentials_timeout' (more than `timeout' ms, default 10000 for the whole
%% chain) and `{credentials_failed, Reason}'.
-spec resolve(cred()) -> {ok, cred()} | {error, term()}.
resolve(Cred) ->
    resolve(Cred, #{}).

-spec resolve(cred(), #{timeout => timeout(), max_depth => pos_integer()}) ->
    {ok, cred()} | {error, term()}.
resolve({error, _} = Error, _Opts) ->
    Error;
resolve({password, _, _} = Cred, _Opts) ->
    {ok, Cred};
resolve({oauth2, _, _} = Cred, _Opts) ->
    {ok, Cred};
resolve(Cred, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    MaxDepth = maps:get(max_depth, Opts, ?DEFAULT_MAX_DEPTH),
    Ref = make_ref(),
    Self = self(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Self ! {Ref, chase(Cred, MaxDepth)}
    end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {credentials_failed, Reason}}
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(MRef, [flush]),
        receive
            {Ref, Result} -> Result
        after 0 -> {error, credentials_timeout}
        end
    end.

%% one step at a time, `Left' steps at most
chase(_Cred, 0) ->
    {error, credentials_loop};
chase({password, _, _} = Cred, _Left) ->
    {ok, Cred};
chase({oauth2, _, _} = Cred, _Left) ->
    {ok, Cred};
chase({token_fun, Fun}, Left) when is_function(Fun, 0) ->
    step(Fun, Left);
chase({provider, {Module, Args}, AccountId, Service}, Left) when is_atom(Module) ->
    step(fun() -> Module:fetch(AccountId, Service, Args) end, Left);
chase({ref, Name}, Left) ->
    case persistent_term:get({?MODULE, ref, Name}, undefined) of
        undefined -> {error, {credentials_failed, unknown_reference}};
        Cred -> chase(Cred, Left - 1)
    end;
chase(Other, _Left) ->
    {error, {credentials_failed, {bad_credential, Other}}}.

step(Fun, Left) ->
    try Fun() of
        {ok, Next} -> chase(Next, Left - 1);
        {error, Reason} -> {error, {credentials_failed, Reason}};
        Other -> {error, {credentials_failed, {bad_result, Other}}}
    catch
        Class:Reason -> {error, {credentials_failed, {Class, Reason}}}
    end.
