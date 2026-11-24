%%% @doc JMAP Thread facade.
%%%
%%% A Thread (RFC 8621 s3) is just `{id, emailIds}'; Mailio keeps a few
%%% denormalized fields under the `mailio' sub-map for agents, stripped on
%%% read here.
-module(mailio_thread).

-include("mailio_store.hrl").

-export([get/2, changes/3, id_of/1]).

-spec id_of(map()) -> binary().
id_of(#{<<"id">> := <<?ID_THREAD, Id/binary>>}) -> Id.

%% @doc RFC 8621 Thread/get.
-spec get(binary(), [binary()]) -> {ok, map()}.
get(Account, Ids) ->
    Db = mailio_account:db_name(Account),
    {Found, NotFound} = lists:foldr(
        fun(Id, {Acc, NF}) ->
            case mailio_db:get(Db, <<?ID_THREAD, Id/binary>>) of
                {ok, Doc} -> {[project(Doc) | Acc], NF};
                {error, not_found} -> {Acc, [Id | NF]}
            end
        end, {[], []}, Ids),
    {ok, #{<<"accountId">> => Account,
           <<"state">> => mailio_account:state_token(Account),
           <<"list">> => Found,
           <<"notFound">> => NotFound}}.

project(Doc) ->
    #{<<"id">> => id_of(Doc),
      <<"emailIds">> => maps:get(<<"emailIds">>, Doc, [])}.

%% @doc RFC 8621 Thread/changes.
-spec changes(binary(), binary(), map()) -> {ok, map()} | {error, cannot_calculate_changes}.
changes(Account, SinceState, Opts) ->
    case mailio_cursor:decode(SinceState) of
        {ok, Cursor} ->
            Max = maps:get(maxChanges, Opts, 1000),
            {ok, Envs, NewCursor, More} =
                mailio_changes:since(Account, Cursor, #{types => [thread], limit => Max}),
            {C, U, D} = lists:foldr(
                fun(#{verb := created, object_id := Id}, {Cs, Us, Ds}) -> {[Id | Cs], Us, Ds};
                   (#{verb := updated, object_id := Id}, {Cs, Us, Ds}) -> {Cs, [Id | Us], Ds};
                   (#{verb := destroyed, object_id := Id}, {Cs, Us, Ds}) -> {Cs, Us, [Id | Ds]}
                end, {[], [], []}, Envs),
            {ok, #{<<"accountId">> => Account,
                   <<"oldState">> => SinceState,
                   <<"newState">> => mailio_cursor:encode(NewCursor),
                   <<"hasMoreChanges">> => More =:= more,
                   <<"created">> => C, <<"updated">> => U, <<"destroyed">> => D}};
        {error, invalid_state} ->
            {error, cannot_calculate_changes}
    end.
