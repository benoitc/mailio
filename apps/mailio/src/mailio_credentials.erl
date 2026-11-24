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
%%% </ul>
-module(mailio_credentials).

-export([fetch/3, invalidate/3, resolve/1, resolve/2]).

-define(DEFAULT_TIMEOUT, 10000).
-define(DEFAULT_MAX_DEPTH, 8).

-export_type([provider/0, service/0, cred/0]).

-type provider() :: {module(), ProviderArgs :: term()}.
-type service() :: imap | smtp | jmap.
-type cred() ::
    {password, binary(), binary()}
    | {oauth2, binary(), binary()}
    | {token_fun, fun(() -> {ok, cred()} | {error, term()})}.

-callback fetch(AccountId :: binary(), Service :: service(), ProviderArgs :: term()) ->
    {ok, cred()} | {error, term()}.
-callback invalidate(AccountId :: binary(), Service :: service(), ProviderArgs :: term()) ->
    ok.

%% @doc Resolve a credential, transparently forcing a `token_fun'.
-spec fetch(provider(), binary(), service()) -> {ok, cred()} | {error, term()}.
fetch({Module, Args}, AccountId, Service) when
    is_atom(Module), is_binary(AccountId)
->
    case Module:fetch(AccountId, Service, Args) of
        {ok, {token_fun, _} = Lazy} -> resolve(Lazy);
        Other -> Other
    end.

-spec invalidate(provider(), binary(), service()) -> ok.
invalidate({Module, Args}, AccountId, Service) when
    is_atom(Module), is_binary(AccountId)
->
    Module:invalidate(AccountId, Service, Args).

%% @doc Turn a credential into a concrete one. A `{password, _, _}' or
%% `{oauth2, _, _}' is returned as it is. A `{token_fun, F}' is called in a
%% process of its own and followed through the credentials it returns, so a
%% provider that loops, hangs or crashes cannot do that to the caller. Errors:
%% `credentials_loop' (more than `max_depth' links, default 8),
%% `credentials_timeout' (more than `timeout' ms, default 10000 for the whole
%% chain) and `{credentials_failed, Reason}'.
-spec resolve(cred()) -> {ok, cred()} | {error, term()}.
resolve(Cred) ->
    resolve(Cred, #{}).

-spec resolve(cred(), #{timeout => timeout(), max_depth => pos_integer()}) ->
    {ok, cred()} | {error, term()}.
resolve({token_fun, Fun}, Opts) when is_function(Fun, 0) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    MaxDepth = maps:get(max_depth, Opts, ?DEFAULT_MAX_DEPTH),
    Ref = make_ref(),
    Self = self(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Self ! {Ref, follow(Fun, MaxDepth)}
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
    end;
resolve({error, _} = Error, _Opts) ->
    Error;
resolve(Cred, _Opts) ->
    {ok, Cred}.

follow(_Fun, 0) ->
    {error, credentials_loop};
follow(Fun, Left) ->
    try Fun() of
        {ok, {token_fun, Next}} when is_function(Next, 0) -> follow(Next, Left - 1);
        {ok, Cred} -> {ok, Cred};
        {error, Reason} -> {error, {credentials_failed, Reason}};
        Other -> {error, {credentials_failed, {bad_result, Other}}}
    catch
        Class:Reason -> {error, {credentials_failed, {Class, Reason}}}
    end.
