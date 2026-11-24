%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Static credential provider.
%%%
%%% ProviderArgs is a map keyed by `{AccountId, Service}' (or `AccountId'
%%% alone, applied to every service) whose values are credentials. Intended
%%% for tests and simple single-user deployments where secrets come from
%%% config rather than an external store.
-module(mailio_credentials_static).
-behaviour(mailio_credentials).

-export([fetch/3, invalidate/3]).

-spec fetch(binary(), mailio_credentials:service(), map()) ->
    {ok, mailio_credentials:cred()} | {error, term()}.
fetch(AccountId, Service, Map) when is_map(Map) ->
    case maps:find({AccountId, Service}, Map) of
        {ok, Cred} ->
            {ok, Cred};
        error ->
            case maps:find(AccountId, Map) of
                {ok, Cred} -> {ok, Cred};
                error -> {error, no_credentials}
            end
    end.

-spec invalidate(binary(), mailio_credentials:service(), map()) -> ok.
invalidate(_AccountId, _Service, _Map) ->
    %% Static credentials cannot be refreshed; nothing to invalidate.
    ok.
