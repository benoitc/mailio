%%% @doc Content-addressed blob files.
%%%
%%% The bytes of a raw message live in `<Root>/<Scope>/<aa>/<sha256hex>', where
%%% `aa' is the first two hex digits. The name is the SHA-256 of the content,
%%% so identical content is one file, a replica can name exactly what it is
%%% missing, and any file can be checked against its own name.
%%%
%%% A write goes to `<Root>/<Scope>/tmp/', is synced, and is renamed into
%%% place, as Maildir delivery does: a reader never sees a half-written file,
%%% and a crash leaves at most a stale temporary file that {@link clean_tmp/3}
%%% removes. Content that does not hash to the name it is stored under is
%%% refused, so a peer cannot hand over the wrong bytes.
%%%
%%% This module only moves bytes. References, the grace period and garbage
%%% collection stay in {@link mailio_blob}, which keeps the `blob/<hex>'
%%% documents in the database.
-module(mailio_blob_files).

-export([put/4, get/3, exists/3, size/3, delete/3, verify/3, list/2, clean_tmp/3, path/3]).
-export([quarantine/3, mtime/3]).

-type root() :: file:filename_all().
-type scope() :: binary().
-type hex() :: binary().

-export_type([root/0, scope/0, hex/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Store `Content' under `Hex'. Idempotent: an existing file is left alone.
-spec put(root(), scope(), hex(), binary()) -> ok | {error, term()}.
put(Root, Scope, Hex, Content) when is_binary(Content) ->
    case valid(Scope, Hex) of
        ok ->
            case mailio_id:blob_hex(Content) of
                Hex -> write(Root, Scope, Hex, Content);
                _Other -> {error, hash_mismatch}
            end;
        {error, _} = E ->
            E
    end.

-spec get(root(), scope(), hex()) -> {ok, binary()} | {error, not_found | term()}.
get(Root, Scope, Hex) ->
    case valid(Scope, Hex) of
        ok ->
            case file:read_file(path_of(Root, Scope, Hex)) of
                {ok, Bin} -> {ok, Bin};
                {error, enoent} -> {error, not_found};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

-spec exists(root(), scope(), hex()) -> boolean().
exists(Root, Scope, Hex) ->
    case valid(Scope, Hex) of
        ok -> filelib:is_regular(path_of(Root, Scope, Hex));
        {error, _} -> false
    end.

-spec size(root(), scope(), hex()) -> {ok, non_neg_integer()} | {error, not_found}.
size(Root, Scope, Hex) ->
    case valid(Scope, Hex) of
        ok ->
            case file:read_file_info(path_of(Root, Scope, Hex)) of
                {ok, Info} -> {ok, element(2, Info)};
                {error, _} -> {error, not_found}
            end;
        {error, _} ->
            {error, not_found}
    end.

%% @doc Remove the file. A file that is already gone is fine.
-spec delete(root(), scope(), hex()) -> ok | {error, term()}.
delete(Root, Scope, Hex) ->
    case valid(Scope, Hex) of
        ok ->
            case file:delete(path_of(Root, Scope, Hex)) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% @doc Re-hash the file and compare it with its name.
-spec verify(root(), scope(), hex()) -> ok | {error, not_found | corrupt | term()}.
verify(Root, Scope, Hex) ->
    case get(Root, Scope, Hex) of
        {ok, Bin} ->
            case mailio_id:blob_hex(Bin) of
                Hex -> ok;
                _ -> {error, corrupt}
            end;
        {error, _} = E ->
            E
    end.

%% @doc Every hash stored for a scope.
-spec list(root(), scope()) -> [hex()].
list(Root, Scope) ->
    case valid_scope(Scope) of
        ok ->
            Base = scope_dir(Root, Scope),
            case file:list_dir(Base) of
                {ok, Subs} ->
                    lists:sort(lists:append([
                        shard_files(filename:join(Base, Sub), Sub)
                     || Sub <- Subs, byte_size(unicode:characters_to_binary(Sub)) =:= 2
                    ]));
                {error, _} ->
                    []
            end;
        {error, _} ->
            []
    end.

%% @doc Move a file out of the store (to `<Root>/<Scope>/corrupt/'), so a bad
%% file is kept for inspection but no longer served.
-spec quarantine(root(), scope(), hex()) -> ok | {error, term()}.
quarantine(Root, Scope, Hex) ->
    case valid(Scope, Hex) of
        ok ->
            Dest = filename:join([scope_dir(Root, Scope), "corrupt", binary_to_list(Hex)]),
            ok = filelib:ensure_dir(Dest),
            case file:rename(path_of(Root, Scope, Hex), Dest) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% @doc Last modification time of a file, in seconds since the epoch.
-spec mtime(root(), scope(), hex()) -> {ok, integer()} | {error, not_found}.
mtime(Root, Scope, Hex) ->
    case valid(Scope, Hex) of
        ok ->
            case file:read_file_info(path_of(Root, Scope, Hex), [{time, posix}]) of
                {ok, Info} -> {ok, element(6, Info)};
                {error, _} -> {error, not_found}
            end;
        {error, _} ->
            {error, not_found}
    end.

%% @doc Remove temporary files older than `MaxAgeSecs'. Returns how many.
-spec clean_tmp(root(), scope(), non_neg_integer()) -> non_neg_integer().
clean_tmp(Root, Scope, MaxAgeSecs) ->
    case valid_scope(Scope) of
        ok ->
            Dir = filename:join(scope_dir(Root, Scope), "tmp"),
            Cutoff = erlang:system_time(second) - MaxAgeSecs,
            case file:list_dir(Dir) of
                {ok, Names} ->
                    length([
                        N
                     || N <- Names,
                        old_enough(filename:join(Dir, N), Cutoff),
                        file:delete(filename:join(Dir, N)) =:= ok
                    ]);
                {error, _} ->
                    0
            end;
        {error, _} ->
            0
    end.

-spec path(root(), scope(), hex()) -> {ok, file:filename_all()} | {error, bad_name}.
path(Root, Scope, Hex) ->
    case valid(Scope, Hex) of
        ok -> {ok, path_of(Root, Scope, Hex)};
        {error, _} = E -> E
    end.

%%====================================================================
%% Internal
%%====================================================================

write(Root, Scope, Hex, Content) ->
    Final = path_of(Root, Scope, Hex),
    case filelib:is_regular(Final) of
        true ->
            ok;
        false ->
            Tmp = tmp_path(Root, Scope),
            case write_tmp(Tmp, Content) of
                ok -> install(Tmp, Final);
                {error, _} = E -> _ = file:delete(Tmp), E
            end
    end.

write_tmp(Tmp, Content) ->
    case filelib:ensure_dir(Tmp) of
        ok ->
            case file:open(Tmp, [write, raw, binary, exclusive]) of
                {ok, Fd} ->
                    Result =
                        case file:write(Fd, Content) of
                            ok -> file:sync(Fd);
                            {error, _} = E -> E
                        end,
                    _ = file:close(Fd),
                    Result;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

install(Tmp, Final) ->
    case filelib:ensure_dir(Final) of
        ok ->
            case file:rename(Tmp, Final) of
                ok -> ok;
                {error, _} = E -> _ = file:delete(Tmp), E
            end;
        {error, _} = E ->
            _ = file:delete(Tmp),
            E
    end.

tmp_path(Root, Scope) ->
    Name = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    filename:join([scope_dir(Root, Scope), "tmp", binary_to_list(Name)]).

old_enough(Path, Cutoff) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, Info} -> element(6, Info) =< Cutoff;
        {error, _} -> false
    end.

shard_files(Dir, Shard) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            [
                H
             || N <- Names,
                H <- [unicode:characters_to_binary(N)],
                valid_hex(H),
                binary:part(H, 0, 2) =:= unicode:characters_to_binary(Shard)
            ];
        {error, _} ->
            []
    end.

scope_dir(Root, Scope) -> filename:join(Root, binary_to_list(Scope)).

path_of(Root, Scope, Hex) ->
    filename:join([scope_dir(Root, Scope), binary_to_list(binary:part(Hex, 0, 2)), binary_to_list(Hex)]).

%% Names reach the file system, so they are checked, not trusted.
valid(Scope, Hex) ->
    case valid_scope(Scope) of
        ok ->
            case valid_hex(Hex) of
                true -> ok;
                false -> {error, bad_name}
            end;
        {error, _} = E ->
            E
    end.

valid_scope(Scope) when is_binary(Scope) ->
    case re:run(Scope, <<"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$">>) of
        {match, _} ->
            case lists:member(Scope, [<<"tmp">>, <<"corrupt">>]) of
                true -> {error, bad_name};
                false -> ok
            end;
        nomatch ->
            {error, bad_name}
    end;
valid_scope(_) ->
    {error, bad_name}.

valid_hex(Hex) when is_binary(Hex), byte_size(Hex) =:= 64 ->
    re:run(Hex, <<"^[0-9a-f]{64}$">>) =/= nomatch;
valid_hex(_) ->
    false.
