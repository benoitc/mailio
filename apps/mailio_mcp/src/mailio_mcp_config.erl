%%% @doc Account and principal configuration.
%%%
%%% Configuration lives in the `mailio_mcp' application env.
%%% `MAILIO_MCP_CONFIG' may name a sys.config style file that is merged
%%% into it at start. Secrets are references ({env, Name}, {file, Path},
%%% {cmd, Command} or {value, Binary}) and are resolved on use.
-module(mailio_mcp_config).

-export([
    load_env_file/0,
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
