%%% @doc Agent capability grants.
%%%
%%% A grant authorizes an AI agent to use a set of accounts with specific
%%% scopes and mailbox visibility. Grants live in the system database and
%%% are enforced by {@link mailio_agent} at the API boundary. This is a
%%% policy layer that prevents accidental over-reach through the supported
%%% API; it is not a sandbox against hostile in-VM code.
-module(mailio_grant).

-compile({no_auto_import, [get/1]}).

-include("mailio_store.hrl").

-export([create/1, get/1, revoke/1, delete/1]).

-export_type([grant/0, scope/0]).

-type scope() :: read | search | tag | mark | draft | submit | manage_rules.
-type grant() :: map().

%% @doc Create or replace a grant. Spec keys: `agent_id', `secret'
%% (optional shared secret; stored hashed), `accounts' => `#{AccountId =>
%% #{scopes => [scope()], mailbox_allow => all | [Id], mailbox_deny =>
%% [Id]}}', `rate_limit', `expires_at' (epoch seconds | undefined).
-spec create(map()) -> {ok, binary()}.
create(Spec) ->
    ok = ensure_system_db(),
    AgentId = maps:get(agent_id, Spec),
    Doc = #{
        <<"id">> => <<?ID_GRANT, AgentId/binary>>,
        <<"agentId">> => AgentId,
        <<"secretHash">> => hash_secret(maps:get(secret, Spec, undefined)),
        <<"accounts">> => accounts_to_doc(maps:get(accounts, Spec, #{})),
        <<"rateLimit">> => maps:get(rate_limit, Spec, #{}),
        <<"expiresAt">> => maps:get(expires_at, Spec, null),
        <<"revoked">> => false
    },
    {ok, _, _} = mailio_db:put(system_db(), Doc),
    {ok, AgentId}.

-spec get(binary()) -> {ok, grant()} | {error, not_found}.
get(AgentId) ->
    mailio_db:get(system_db(), <<?ID_GRANT, AgentId/binary>>).

-spec revoke(binary()) -> ok | {error, not_found}.
revoke(AgentId) ->
    case get(AgentId) of
        {ok, Doc} ->
            {ok, _, _} = mailio_db:put(system_db(), Doc#{<<"revoked">> => true}),
            ok;
        {error, _} = Err ->
            Err
    end.

-spec delete(binary()) -> ok.
delete(AgentId) ->
    _ = mailio_db:delete(system_db(), <<?ID_GRANT, AgentId/binary>>),
    ok.

%%====================================================================
%% Internal
%%====================================================================

system_db() -> mailio_config:system_db().

ensure_system_db() ->
    {ok, _} = mailio_db:ensure_db(system_db()),
    ok.

hash_secret(undefined) ->
    null;
hash_secret(Secret) when is_binary(Secret) ->
    binary:encode_hex(crypto:hash(sha256, Secret), lowercase).

%% Normalize account grant maps to JSON-safe documents.
accounts_to_doc(Accounts) ->
    maps:map(
        fun(_AccountId, Perm) ->
            #{
                <<"scopes">> => [atom_to_binary(S, utf8) || S <- maps:get(scopes, Perm, [])],
                <<"mailboxAllow">> => allow_to_doc(maps:get(mailbox_allow, Perm, all)),
                <<"mailboxDeny">> => maps:get(mailbox_deny, Perm, [])
            }
        end,
        Accounts
    ).

allow_to_doc(all) -> <<"all">>;
allow_to_doc(List) when is_list(List) -> List.
