%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Converts an account's incoming or outgoing settings into the
%%% connection config the mailio protocol clients take. Secrets are resolved
%%% when the connection is made, never stored.
-module(mailio_mcp_net).

-export([config/2]).

-spec config(map(), map()) -> map().
config(Section, Auth) ->
    Base = #{
        host => to_bin(maps:get(host, Section)),
        tls => tls(maps:get(tls, Section, implicit)),
        verify =>
            case maps:get(verify, Section, true) of
                false -> verify_none;
                _ -> verify_peer
            end,
        credentials => credentials(Auth)
    },
    Opt = lists:foldl(
        fun(K, A) ->
            case maps:find(K, Section) of
                {ok, V} -> A#{K => V};
                error -> A
            end
        end,
        Base,
        [port, cacertfile, ehlo_name]
    ),
    Opt.

tls(implicit) -> true;
tls(starttls) -> starttls;
tls(none) -> false.

credentials(#{user := User, secret := Ref} = Auth) ->
    {token_fun, fun() ->
        case mailio_mcp_config:resolve_secret(Ref) of
            {ok, Secret} ->
                case maps:get(mechanism, Auth, plain) of
                    xoauth2 -> {ok, {oauth2, User, Secret}};
                    _ -> {ok, {password, User, Secret}}
                end;
            {error, _} = E ->
                E
        end
    end}.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
