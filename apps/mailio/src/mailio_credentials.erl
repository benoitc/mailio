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

-export([fetch/3, invalidate/3]).

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
        {ok, {token_fun, Fun}} -> force(Fun);
        Other -> Other
    end.

-spec invalidate(provider(), binary(), service()) -> ok.
invalidate({Module, Args}, AccountId, Service) when
    is_atom(Module), is_binary(AccountId)
->
    Module:invalidate(AccountId, Service, Args).

%% Force a token_fun chain to a concrete credential (bounded against loops).
-spec force(fun(() -> {ok, cred()} | {error, term()})) ->
    {ok, cred()} | {error, term()}.
force(Fun) ->
    case Fun() of
        {ok, {token_fun, Inner}} -> force(Inner);
        Other -> Other
    end.
