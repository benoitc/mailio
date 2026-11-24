%%% @doc mail_changes: additions, updates and removals since an opaque
%%% checkpoint. The checkpoint names stored per-mailbox snapshots, so a
%%% replay after a restart compares against the same state and an unchanged
%%% mailbox returns a small empty result with the same checkpoint.
-module(mailio_mcp_changes).

-export([run/2]).

-define(MAX_ADDED, 20).

-spec run(binary(), map()) -> {ok, map()} | {error, term()}.
run(Principal, Args) ->
    maybe
        {ok, Accounts} ?= mailio_mcp_authz:select_accounts(Principal, Args),
        Box = maps:get(<<"mailbox">>, Args, <<"INBOX">>),
        {ok, CkptId, Snaps} ?= load(Principal, Args),
        Pairs = [{A, Box} || A <- Accounts],
        Results = [{P, one(Principal, P, maps:get(P, Snaps, undefined))} || P <- Pairs],
        build(Principal, CkptId, Snaps, Results)
    end.

load(Principal, Args) ->
    case maps:get(<<"checkpoint">>, Args, undefined) of
        undefined ->
            {ok, undefined, #{}};
        Token ->
            case mailio_mcp_handle:decode(ckpt, Principal, Token) of
                {ok, #{<<"i">> := Id}} ->
                    case mailio_mcp_store:get(ckpt, {Principal, Id}) of
                        {ok, #{at := At, snaps := S}} ->
                            Ttl = mailio_mcp_config:limit(checkpoint_ttl, 30 * 86400),
                            case erlang:system_time(second) - At =< Ttl of
                                true -> {ok, Id, S};
                                false -> {error, checkpoint_expired}
                            end;
                        error ->
                            {error, checkpoint_expired}
                    end;
                {error, _} ->
                    {error, checkpoint_invalid}
            end
    end.

one(Principal, {AccId, Box}, Prev) ->
    case mailio_mcp_authz:check(Principal, AccId, read) of
        ok ->
            {ok, Account} = mailio_mcp_config:account(AccId),
            mailio_mcp_adapter:call(Account, changes, [Box, Prev]);
        {error, _} = E ->
            E
    end.

build(Principal, CkptId, OldSnaps, Results) ->
    Expired = [P || {P, {error, checkpoint_expired}} <- Results],
    case Expired of
        [_ | _] ->
            {error, checkpoint_expired};
        [] ->
            NewSnaps = lists:foldl(
                fun
                    ({P, {ok, #{snapshot := S}}}, A) -> A#{P => S};
                    (_, A) -> A
                end,
                OldSnaps,
                Results
            ),
            AllUnchanged =
                CkptId =/= undefined andalso
                    lists:all(
                        fun
                            ({_, {ok, #{unchanged := true}}}) -> true;
                            (_) -> false
                        end,
                        Results
                    ),
            {Id, Token} =
                case AllUnchanged of
                    true ->
                        {CkptId, mailio_mcp_handle:encode(ckpt, Principal, #{<<"i">> => CkptId})};
                    false ->
                        NewId = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
                        mailio_mcp_store:put(
                            ckpt,
                            {Principal, NewId},
                            #{at => erlang:system_time(second), snaps => NewSnaps}
                        ),
                        {NewId, mailio_mcp_handle:encode(ckpt, Principal, #{<<"i">> => NewId})}
                end,
            _ = Id,
            Out = [{P, R} || {P, R} <- Results],
            Failed = [{P, E} || {P, {error, E}} <- Out],
            Ok = [{P, R} || {P, {ok, R}} <- Out],
            Changed = [{P, R} || {P, R} <- Ok, maps:get(unchanged, R) =:= false],
            lists:foreach(
                fun({{A, B}, _}) -> mailio_mcp_cache:invalidate_mailbox(A, B) end, Changed
            ),
            Base = #{
                <<"checkpoint">> => Token,
                <<"unchanged">> => Changed =:= [] andalso Failed =:= []
            },
            Base2 =
                case [P || {P, #{baseline := true}} <- Ok] of
                    [] ->
                        Base;
                    Bs ->
                        Base#{
                            <<"baseline">> => [A || {A, _} <- Bs],
                            <<"note">> =>
                                <<"Baseline taken; later calls report changes since this checkpoint.">>
                        }
                end,
            Base3 =
                case Failed of
                    [] ->
                        Base2;
                    _ ->
                        Base2#{
                            <<"coverage">> => [
                                #{
                                    <<"account">> => A,
                                    <<"status">> => <<"offline">>,
                                    <<"note">> => mailio_mcp_view:error_text(E)
                                }
                             || {{A, _}, E} <- Failed
                            ]
                        }
                end,
            {ok, with_changes(Principal, Changed, Base3)}
    end.

with_changes(_, [], Base) ->
    Base;
with_changes(Principal, Changed, Base) ->
    Added = lists:append([
        [
            mailio_mcp_view:hit_out(
                Principal, H, [from, subject, date, flags, attachments], received_at
            )
         || H <- maps:get(added, R)
        ]
     || {_, R} <- Changed
    ]),
    AddedTotal = lists:sum([maps:get(added_total, R, 0) || {_, R} <- Changed]),
    Updated = lists:append([
        [
            #{
                <<"handle">> => handle_for(Principal, A, B, maps:get(uv, R), U),
                <<"unread">> => maps:get(unread, Up),
                <<"flags">> => maps:get(flags, Up)
            }
         || Up = #{uid := U} <- maps:get(updated, R)
        ]
     || {{A, B}, R} <- Changed
    ]),
    Removed = lists:append([
        [
            handle_for(Principal, A, B, maps:get(uv, R), U)
         || U <- maps:get(removed, R)
        ]
     || {{A, B}, R} <- Changed
    ]),
    Shown = lists:sublist(lists:reverse(Added), ?MAX_ADDED),
    R0 = Base#{
        <<"added">> => Shown,
        <<"updated">> => lists:sublist(Updated, 50),
        <<"removed">> => lists:sublist(Removed, 50)
    },
    R1 =
        case {AddedTotal > length(Shown), length(Updated) > 50 orelse length(Removed) > 50} of
            {false, false} ->
                R0;
            _ ->
                R0#{
                    <<"omitted">> => #{
                        <<"added">> => max(0, AddedTotal - length(Shown)),
                        <<"updated">> => max(0, length(Updated) - 50),
                        <<"removed">> => max(0, length(Removed) - 50),
                        <<"note">> =>
                            <<"Some changes are not listed. Use mail_search with a time range to see them.">>
                    }
                }
        end,
    fit(R1).

handle_for(Principal, Acc, Box, UV, Uid) ->
    mailio_mcp_view:handle(Principal, #{account => Acc, mailbox => Box, uv => UV, uid => Uid}).

%% Trim the lists until the result fits the budget.
fit(R) ->
    Max = mailio_mcp_budget:max_bytes(),
    case mailio_mcp_budget:size(R) =< Max of
        true ->
            R;
        false ->
            Added = maps:get(<<"added">>, R, []),
            case length(Added) > 1 of
                true ->
                    N = length(Added) div 2,
                    fit(R#{
                        <<"added">> := lists:sublist(Added, N),
                        <<"omitted">> => #{
                            <<"added">> => 1,
                            <<"note">> =>
                                <<"Result trimmed to the byte budget. Use mail_search for the rest.">>
                        }
                    });
                false ->
                    R#{<<"updated">> := [], <<"removed">> := []}
            end
    end.
