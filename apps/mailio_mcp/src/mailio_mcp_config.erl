%%% @doc Account and principal configuration.
%%%
%%% Configuration lives in the `mailio_mcp' application env.
%%% `MAILIO_MCP_CONFIG' may name a sys.config style file that is merged
%%% into it at start. Secrets are references ({env, Name}, {file, Path},
%%% {cmd, Command} or {value, Binary}) and are resolved on use.
-module(mailio_mcp_config).

-export([
    load_env_file/0,
    apply_request_state_key/0,
    accounts/0,
    account/1,
    principal/1,
    stdio_principal/0,
    data_dir/0,
    limit/2,
    resolve_secret/1
]).

-define(APP, mailio_mcp).

load_env_file() ->
    case os:getenv("MAILIO_MCP_CONFIG") of
        false ->
            ok;
        Path ->
            {ok, Terms} = file:consult(Path),
            lists:foreach(
                fun(Config) ->
                    lists:foreach(
                        fun({App, Env}) ->
                            [application:set_env(App, K, V) || {K, V} <- Env]
                        end,
                        Config
                    )
                end,
                Terms
            )
    end.

%% @doc Give barrel_mcp its request-state signing key from the secret
%% reference `request_state_key' in the mailio_mcp config (`{env, _}',
%% `{file, _}' or `{cmd, _}'), so the key is not written in the config file.
%% Without one barrel_mcp makes a key per start: fine for one stdio process,
%% wrong for HTTP behind more than one node or across restarts. A key shorter
%% than 32 bytes is refused.
-spec apply_request_state_key() -> ok | {error, term()}.
apply_request_state_key() ->
    case application:get_env(?APP, request_state_key) of
        undefined ->
            ok;
        {ok, Ref} ->
            case resolve_secret(Ref) of
                {ok, Key} when byte_size(Key) >= 32 ->
                    application:set_env(barrel_mcp, request_state_key, Key);
                {ok, _} ->
                    {error, request_state_key_too_short};
                {error, _} = E ->
                    E
            end
    end.

%% @doc All configured accounts, normalized.
-spec accounts() -> [map()].
accounts() ->
    [normalize(A) || A <- application:get_env(?APP, accounts, [])].

-spec account(binary()) -> {ok, map()} | error.
account(Id) ->
    case [A || A = #{id := I} <- accounts(), I =:= Id] of
        [A | _] -> {ok, A};
        [] -> error
    end.

normalize(A) ->
    In = maps:merge(#{tls => implicit, verify => true}, maps:get(incoming, A)),
    Out = maps:merge(#{tls => starttls, verify => true}, maps:get(outgoing, A, #{})),
    Auth = maps:get(auth, A),
    Ids = maps:get(identities, A, []),
    A#{
        incoming => In#{protocol => maps:get(protocol, In, imap)},
        outgoing => Out,
        auth_out => maps:get(auth_out, A, Auth),
        identities => Ids,
        name => maps:get(name, A, maps:get(id, A))
    }.

%% @doc Principal definition. Without a `principals' list, one implicit
%% principal may read, draft and send on every account (single-account use).
-spec principal(binary()) -> {ok, map()} | error.
principal(Id) ->
    case application:get_env(?APP, principals) of
        undefined ->
            Grants = maps:from_list(
                [{I, #{role => send, identities => all}} || #{id := I} <- accounts()]
            ),
            {ok, #{id => Id, grants => Grants}};
        {ok, List} ->
            case [P || P = #{id := I} <- List, I =:= Id] of
                [P | _] -> {ok, P};
                [] -> error
            end
    end.

stdio_principal() ->
    application:get_env(?APP, stdio_principal, <<"local">>).

data_dir() ->
    application:get_env(?APP, data_dir, "data").

limit(Name, Default) ->
    Limits = application:get_env(?APP, limits, #{}),
    maps:get(Name, Limits, Default).

-spec resolve_secret(term()) -> {ok, binary()} | {error, term()}.
resolve_secret({value, V}) when is_binary(V) ->
    {ok, V};
resolve_secret({env, Name}) ->
    case os:getenv(Name) of
        false -> {error, {missing_env, Name}};
        V -> {ok, unicode:characters_to_binary(V)}
    end;
resolve_secret({file, Path}) ->
    case file:read_file(Path) of
        {ok, B} -> {ok, string:trim(B)};
        {error, R} -> {error, {secret_file, R}}
    end;
resolve_secret({cmd, Cmd}) ->
    {ok, string:trim(unicode:characters_to_binary(os:cmd(Cmd)))};
resolve_secret(_) ->
    {error, bad_secret_reference}.
