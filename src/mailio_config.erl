%%% @doc Application configuration access.
-module(mailio_config).

-export([data_dir/0, system_db/0, get/1, get/2]).

-spec data_dir() -> string().
data_dir() ->
    get(data_dir, "data/mailio").

-spec system_db() -> binary().
system_db() ->
    get(system_db, <<"mailio_system">>).

-spec get(atom()) -> term() | undefined.
get(Key) ->
    get(Key, undefined).

-spec get(atom(), term()) -> term().
get(Key, Default) ->
    application:get_env(mailio, Key, Default).
