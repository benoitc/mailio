%%% @doc Permission checks. Every search, read, resource fetch and write
%%% goes through here. An unknown account and an account the caller may not
%%% see produce the same error, so the response never reveals which exists.
-module(mailio_mcp_authz).

-export([
    principal_from_ctx/1,
    visible_accounts/1,
    select_accounts/2,
    check/3,
    check_identity/3,
    identities/2,
    role/2
]).

-type role() :: read | draft | send.
-export_type([role/0]).

principal_from_ctx(#{mcp_ctx := Inner}) ->
    principal_from_ctx(Inner);
principal_from_ctx(Ctx) ->
    case barrel_mcp_ctx:principal(Ctx) of
        anonymous -> mailio_mcp_config:stdio_principal();
        P when is_binary(P) -> P;
        {_Provider, _Namespace, Subject} when is_binary(Subject) -> Subject;
        _ -> <<"unknown">>
    end.

grants(Principal) ->
    case mailio_mcp_config:principal(Principal) of
        {ok, #{grants := G}} -> G;
        error -> #{}
    end.

-spec visible_accounts(binary()) -> [binary()].
visible_accounts(Principal) ->
    Known = [Id || #{id := Id} <- mailio_mcp_config:accounts()],
    [Id || Id <- Known, maps:is_key(Id, grants(Principal))].

-spec role(binary(), binary()) -> role() | none.
role(Principal, AccountId) ->
    case maps:find(AccountId, grants(Principal)) of
        {ok, #{role := R}} -> R;
        _ -> none
    end.

rank(read) -> 1;
rank(draft) -> 2;
rank(send) -> 3;
rank(_) -> 0.

%% @doc Resolve the accounts a call addresses.
%% `account_ids' is a list of ids or the string "all" (all authorized).
%% Omitting it is allowed only when exactly one account is visible.
-spec select_accounts(binary(), map()) -> {ok, [binary()]} | {error, term()}.
select_accounts(Principal, Args) ->
    Visible = visible_accounts(Principal),
    case maps:get(<<"account_ids">>, Args, undefined) of
        undefined ->
            case Visible of
                [One] -> {ok, [One]};
                [] -> {error, no_accounts};
                _ -> {error, account_ids_required}
            end;
        <<"all">> ->
            {ok, lists:sort(Visible)};
        Ids when is_list(Ids), Ids =/= [] ->
            case lists:all(fun(I) -> lists:member(I, Visible) end, Ids) of
                true -> {ok, lists:usort(Ids)};
                false -> {error, unknown_account}
            end;
        _ ->
            {error, bad_account_ids}
    end.

-spec check(binary(), binary(), role()) -> ok | {error, term()}.
check(Principal, AccountId, Need) ->
    case role(Principal, AccountId) of
        none ->
            {error, unknown_account};
        Have ->
            case rank(Have) >= rank(Need) of
                true -> ok;
                false -> {error, {forbidden, Need}}
            end
    end.

%% @doc Sender addresses the principal may use on an account.
-spec identities(binary(), binary()) -> [map()].
identities(Principal, AccountId) ->
    case mailio_mcp_config:account(AccountId) of
        {ok, #{identities := All}} ->
            case maps:find(AccountId, grants(Principal)) of
                {ok, #{identities := all}} ->
                    All;
                {ok, #{identities := Allowed}} ->
                    [I || I = #{address := A} <- All, lists:member(A, Allowed)];
                error ->
                    []
            end;
        error ->
            []
    end.

check_identity(Principal, AccountId, Address) ->
    case [I || I = #{address := A} <- identities(Principal, AccountId), A =:= Address] of
        [I | _] -> {ok, I};
        [] -> {error, {identity_not_permitted, Address}}
    end.
