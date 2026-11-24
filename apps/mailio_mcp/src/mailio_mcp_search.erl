%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc mail_search: scope check, parallel per-account search, exact time
%%% filtering, stable merge, copy grouping, cursor paging and the result
%%% budget.
-module(mailio_mcp_search).

-export([run/2]).

-define(DEFAULT_FIELDS, [from, subject, date, flags, attachments]).
-define(WORKER_TIMEOUT, 25000).

-spec run(binary(), map()) -> {ok, map()} | {error, term()}.
run(Principal, Args) ->
    maybe
        {ok, Accounts} ?= mailio_mcp_authz:select_accounts(Principal, Args),
        {ok, Q} ?= parse_query(Args),
        QHash = qhash(Accounts, Q),
        {ok, After} ?= decode_cursor(Principal, QHash, Args),
        Results = parallel(Principal, Accounts, Q),
        {Hits0, Cov, Ages} = merge(Results),
        Hits1 = [H || H <- Hits0, first_seen_ok(H, Q)],
        Sorted = lists:sort(fun(A, B) -> sort_key(A, Q) =< sort_key(B, Q) end, Hits1),
        Grouped =
            case maps:get(group_copies, Q) of
                true -> group_copies(Principal, Sorted);
                false -> Sorted
            end,
        Approx =
            lists:any(fun(#{status := S}) -> S =/= complete end, Cov) orelse
                lists:any(
                    fun
                        (#{capped := C}) -> C;
                        (_) -> false
                    end,
                    Cov
                ),
        Count = length(Grouped),
        Env0 = #{
            <<"count">> => Count,
            <<"count_approximate">> => Approx,
            <<"accounts_searched">> => Accounts,
            <<"time_basis">> => atom_to_binary(maps:get(basis, Q))
        },
        Env1 =
            case [coverage_out(C) || C = #{status := S} <- Cov, S =/= complete] of
                [] -> Env0;
                Partial -> Env0#{<<"coverage">> => Partial}
            end,
        Env2 = Env1#{<<"freshness">> => freshness(Ages)},
        case maps:get(count_only, Q) of
            true ->
                {ok, Env2};
            false ->
                Rest = skip_to(Grouped, After, Q),
                Limit = mailio_mcp_budget:page_size(maps:get(limit, Q)),
                {Page, Remaining} = take(Rest, Limit),
                Page2 =
                    case maps:get(excerpt, Q) of
                        true -> with_excerpts(Accounts, Page);
                        false -> Page
                    end,
                Basis = maps:get(basis, Q),
                Fields = maps:get(fields, Q),
                Out = [mailio_mcp_view:hit_out(Principal, H, Fields, Basis) || H <- Page2],
                Keys = maps:from_list([
                    {maps:get(<<"handle">>, O), tuple_to_list(sort_key(H, Q))}
                 || {O, H} <- lists:zip(Out, Page2)
                ]),
                KeyOf = fun(OutHit) -> maps:get(maps:get(<<"handle">>, OutHit), Keys) end,
                CursorFun = fun(OutHit) ->
                    mailio_mcp_handle:encode(
                        cursor,
                        Principal,
                        #{<<"q">> => QHash, <<"k">> => KeyOf(OutHit)}
                    )
                end,
                {ok, mailio_mcp_budget:fit(Env2, Out, CursorFun, Remaining =/= [])}
        end
    end.

%%====================================================================
%% Query parsing
%%====================================================================

parse_query(Args) ->
    Tz = maps:get(<<"time_zone">>, Args, undefined),
    maybe
        {ok, Basis} ?= basis(maps:get(<<"time_basis">>, Args, <<"received_at">>)),
        {ok, Since, Before} ?= window(Args, Tz),
        {ok, Fields} ?= fields(maps:get(<<"fields">>, Args, undefined)),
        {ok, #{
            mailboxes => mailboxes(maps:get(<<"mailbox">>, Args, undefined)),
            from => str(maps:get(<<"from">>, Args, undefined)),
            to => str(maps:get(<<"to">>, Args, undefined)),
            subject => str(maps:get(<<"subject">>, Args, undefined)),
            text => str(maps:get(<<"text">>, Args, undefined)),
            unread => maps:get(<<"unread">>, Args, undefined),
            has_attachment => maps:get(<<"has_attachment">>, Args, undefined),
            basis => Basis,
            since => Since,
            before => Before,
            limit => maps:get(<<"limit">>, Args, undefined),
            fields => Fields,
            count_only => maps:get(<<"count_only">>, Args, false) =:= true,
            excerpt => maps:get(<<"excerpt">>, Args, false) =:= true orelse
                lists:member(excerpt, Fields),
            group_copies => maps:get(<<"group_copies">>, Args, true) =/= false,
            refresh => maps:get(<<"refresh">>, Args, false) =:= true,
            max_candidates => mailio_mcp_config:limit(max_candidates, 200)
        }}
    end.

str(undefined) -> undefined;
str(<<>>) -> undefined;
str(B) when is_binary(B) -> B;
str(_) -> undefined.

mailboxes(undefined) -> [<<"INBOX">>];
mailboxes(B) when is_binary(B) -> [B];
mailboxes(L) when is_list(L), L =/= [] -> lists:usort(L);
mailboxes(_) -> [<<"INBOX">>].

basis(<<"received_at">>) -> {ok, received_at};
basis(<<"sent_at">>) -> {ok, sent_at};
basis(<<"first_seen_at">>) -> {ok, first_seen_at};
basis(_) -> {error, {bad_argument, <<"time_basis (received_at, sent_at or first_seen_at)">>}}.

window(Args, Tz) ->
    case maps:get(<<"on">>, Args, undefined) of
        undefined ->
            maybe
                {ok, S} ?= bound(maps:get(<<"since">>, Args, undefined), Tz),
                {ok, B} ?= bound(maps:get(<<"before">>, Args, undefined), Tz),
                {ok, S, B}
            end;
        Day when Tz =:= undefined ->
            _ = Day,
            {error, time_zone_required};
        Day ->
            case mailio_mcp_time:day_window(Day, Tz) of
                {ok, S, E} -> {ok, S, E};
                {error, _} = Er -> Er
            end
    end.

bound(undefined, _) ->
    {ok, undefined};
bound(V, Tz) ->
    case Tz of
        undefined -> ok;
        _ -> ok
    end,
    case mailio_mcp_time:parse_bound(V, Tz) of
        {ok, T, _} -> {ok, T};
        {error, _} = E -> E
    end.

fields(undefined) ->
    {ok, ?DEFAULT_FIELDS};
fields(L) when is_list(L) ->
    Known = #{
        <<"from">> => from,
        <<"to">> => to,
        <<"subject">> => subject,
        <<"date">> => date,
        <<"flags">> => flags,
        <<"attachments">> => attachments,
        <<"size">> => size,
        <<"excerpt">> => excerpt,
        <<"copies">> => copies
    },
    case [maps:find(F, Known) || F <- L] of
        Fs when Fs =/= [] ->
            case
                lists:all(
                    fun
                        ({ok, _}) -> true;
                        (_) -> false
                    end,
                    Fs
                )
            of
                true ->
                    {ok, [F || {ok, F} <- Fs]};
                false ->
                    {error,
                        {bad_argument,
                            <<"fields (from,to,subject,date,flags,attachments,size,excerpt,copies)">>}}
            end;
        _ ->
            {ok, ?DEFAULT_FIELDS}
    end;
fields(_) ->
    {error, {bad_argument, <<"fields">>}}.

qhash(Accounts, Q) ->
    Canon = maps:without([limit, fields, count_only, excerpt, refresh], Q),
    binary:encode_hex(
        crypto:hash(sha256, term_to_binary({lists:sort(Accounts), Canon})), lowercase
    ).

decode_cursor(Principal, QHash, Args) ->
    case maps:get(<<"cursor">>, Args, undefined) of
        undefined ->
            {ok, undefined};
        Token ->
            case mailio_mcp_handle:decode(cursor, Principal, Token) of
                {ok, #{<<"q">> := QHash, <<"k">> := K}} -> {ok, list_to_tuple(K)};
                {ok, _} -> {error, cursor_query_mismatch};
                {error, _} -> {error, invalid_cursor}
            end
    end.

%%====================================================================
%% Per-account search
%%====================================================================

parallel(Principal, Accounts, Q) ->
    Self = self(),
    Workers = [
        begin
            Ref = make_ref(),
            {Pid, MRef} = spawn_monitor(fun() -> Self ! {Ref, account_search(Principal, Id, Q)} end),
            {Id, Ref, Pid, MRef}
        end
     || Id <- Accounts
    ],
    [collect(W) || W <- Workers].

collect({Id, Ref, Pid, MRef}) ->
    receive
        {Ref, R} ->
            erlang:demonitor(MRef, [flush]),
            {Id, R};
        {'DOWN', MRef, process, Pid, Reason} ->
            {Id, {error, {unavailable, Reason}}}
    after ?WORKER_TIMEOUT ->
        exit(Pid, kill),
        erlang:demonitor(MRef, [flush]),
        {Id, {error, {unavailable, <<"timeout">>}}}
    end.

account_search(Principal, Id, Q) ->
    case mailio_mcp_authz:check(Principal, Id, read) of
        ok ->
            {ok, Account} = mailio_mcp_config:account(Id),
            AQ0 = maps:with(
                [
                    mailboxes,
                    from,
                    to,
                    subject,
                    text,
                    unread,
                    has_attachment,
                    basis,
                    since,
                    before,
                    max_candidates
                ],
                Q
            ),
            AQ =
                case maps:find(max_candidates, Account) of
                    {ok, N} -> AQ0#{max_candidates => N};
                    error -> AQ0
                end,
            Key = {search, erlang:phash2(AQ, 1 bsl 32)},
            case maps:get(refresh, Q) of
                false ->
                    case mailio_mcp_cache:get(Id, Key) of
                        {ok, {Hits, Info}, Age} -> {ok, decorate(Hits), Info, {cache, Age}};
                        miss -> fresh(Account, Id, Key, AQ)
                    end;
                true ->
                    fresh(Account, Id, Key, AQ)
            end;
        {error, _} = E ->
            E
    end.

fresh(Account, Id, Key, AQ) ->
    case mailio_mcp_adapter:call(Account, search, [AQ]) of
        {ok, Hits, Info} ->
            mailio_mcp_cache:put(Id, Key, {Hits, Info}),
            {ok, decorate(Hits), Info, fresh};
        {error, _} = E ->
            E
    end.

%% Record each occurrence once (restart and retry safe) and attach its
%% first_seen_at.
decorate(Hits) ->
    [
        begin
            {_, First} = mailio_mcp_store:observe(occ_key(H), #{}),
            H#{first_seen_at => First}
        end
     || H <- Hits
    ].

occ_key(#{account := A, mailbox := M, uv := V, uid := U}) -> {imap, A, M, V, U};
occ_key(#{account := A, mailbox := M, uidl := L}) -> {pop3, A, M, L}.

merge(Results) ->
    lists:foldl(
        fun
            ({Id, {ok, Hits, Info, Age}}, {HA, CA, AA}) ->
                Status =
                    case
                        maps:get(capped, Info, false) orelse maps:get(failed_mailboxes, Info, 0) > 0 orelse
                            maps:get(index_incomplete, Info, false)
                    of
                        true -> partial;
                        false -> complete
                    end,
                Cov = #{
                    account => Id,
                    status => Status,
                    capped => maps:get(capped, Info, false),
                    reason => cov_reason(Info)
                },
                {HA ++ Hits, [Cov | CA], [Age | AA]};
            ({Id, {error, R}}, {HA, CA, AA}) ->
                Status =
                    case R of
                        {basis_unavailable, _, _} -> unsupported;
                        {unsupported_filter, _, _} -> unsupported;
                        _ -> offline
                    end,
                Cov = #{
                    account => Id,
                    status => Status,
                    capped => false,
                    reason => mailio_mcp_view:error_text(norm_error(R))
                },
                {HA, [Cov | CA], AA}
        end,
        {[], [], []},
        Results
    ).

norm_error({unavailable, _} = U) -> U;
norm_error(R) -> R.

cov_reason(#{capped := true}) ->
    <<"More matches exist than were examined. Narrow the time range or filters for complete results.">>;
cov_reason(#{failed_mailboxes := N}) when N > 0 -> <<"Some mailboxes could not be searched.">>;
cov_reason(#{index_incomplete := true}) ->
    <<"The local index is still being built; results may be missing.">>;
cov_reason(_) ->
    undefined.

coverage_out(#{account := A, status := S, reason := R}) ->
    Base = #{<<"account">> => A, <<"status">> => atom_to_binary(S)},
    case R of
        undefined -> Base;
        _ -> Base#{<<"note">> => R}
    end.

freshness([]) ->
    #{<<"source">> => <<"none">>};
freshness(Sources) ->
    Cached = [A || {cache, A} <- Sources],
    case {Cached, length(Cached) =:= length(Sources)} of
        {[], _} ->
            #{<<"source">> => <<"server">>};
        {_, All} ->
            #{
                <<"source">> =>
                    case All of
                        true -> <<"cache">>;
                        false -> <<"mixed">>
                    end,
                <<"age_s">> => lists:max(Cached),
                <<"note">> => <<"Pass refresh=true to re-query the server.">>
            }
    end.

first_seen_ok(Hit, #{basis := first_seen_at, since := S, before := B}) ->
    T = maps:get(first_seen_at, Hit),
    (S =:= undefined orelse T >= S) andalso (B =:= undefined orelse T < B);
first_seen_ok(_, _) ->
    true.

%%====================================================================
%% Ordering, paging
%%====================================================================

sort_key(H, #{basis := Basis}) ->
    T =
        case mailio_mcp_view:basis_value(Basis, H) of
            undefined -> maps:get(received_at, H, maps:get(sent_at, H, 0));
            V -> V
        end,
    T2 =
        case T of
            undefined -> 0;
            _ -> T
        end,
    {-T2, maps:get(account, H), maps:get(mailbox, H), id_of(H)}.

id_of(#{uid := U}) -> U;
id_of(#{uidl := L}) -> L.

skip_to(Hits, undefined, _) -> Hits;
skip_to(Hits, After, Q) -> [H || H <- Hits, tuple_to_list(sort_key(H, Q)) > tuple_to_list(After)].

take(L, N) when length(L) =< N -> {L, []};
take(L, N) -> lists:split(N, L).

with_excerpts(_Accounts, Page) ->
    ByAcc = lists:foldl(
        fun(H, M) -> maps:update_with(maps:get(account, H), fun(L) -> [H | L] end, [H], M) end,
        #{},
        Page
    ),
    Ex = maps:fold(
        fun(Id, Hs, Acc) ->
            {ok, Account} = mailio_mcp_config:account(Id),
            maps:merge(
                Acc,
                maps:from_list([
                    {{Id, K}, V}
                 || {K, V} <- maps:to_list(
                        mailio_mcp_adapter:call(Account, excerpts, [lists:reverse(Hs)])
                    )
                ])
            )
        end,
        #{},
        ByAcc
    ),
    [
        case maps:find({maps:get(account, H), excerpt_key(H)}, Ex) of
            {ok, T} -> H#{excerpt => T};
            error -> H
        end
     || H <- Page
    ].

excerpt_key(#{mailbox := M, uv := V, uid := U}) -> {M, V, U};
excerpt_key(#{mailbox := M, uidl := L}) -> {M, L}.

%%====================================================================
%% Copy grouping
%%====================================================================

%% Copies are grouped only when a content fingerprint confirms they are the
%% same message. Message-ID is used to pick candidates and nothing else.
group_copies(Principal, Sorted) ->
    ByMsgid = lists:foldl(
        fun(H, M) ->
            case maps:get(msgid, H, undefined) of
                undefined -> M;
                Id -> maps:update_with(Id, fun(L) -> [H | L] end, [H], M)
            end
        end,
        #{},
        Sorted
    ),
    Cands = [lists:reverse(L) || L <- maps:values(ByMsgid), length(L) > 1],
    case Cands of
        [] ->
            Sorted;
        _ ->
            Fp = fingerprints(lists:append(Cands)),
            Merged = lists:foldl(
                fun(Group, Acc) -> merge_group(Principal, Group, Fp, Acc) end, #{}, Cands
            ),
            Drop = maps:from_list([
                {occ_key(H), true}
             || {_, #{dropped := Ds}} <- maps:to_list(Merged), H <- Ds
            ]),
            [
                case maps:find(occ_key(H), Merged) of
                    {ok, #{copies := C}} -> H#{copies => C};
                    error -> H
                end
             || H <- Sorted, not maps:is_key(occ_key(H), Drop)
            ]
    end.

merge_group(Principal, Group, Fp, Acc) ->
    Verified = [{H, maps:get(occ_key(H), Fp, undefined)} || H <- Group],
    ByPrint = lists:foldl(
        fun
            ({_, undefined}, M) -> M;
            ({H, Print}, M) -> maps:update_with(Print, fun(L) -> [H | L] end, [H], M)
        end,
        #{},
        Verified
    ),
    lists:foldl(
        fun(Hs0, A) ->
            case lists:reverse(Hs0) of
                [Leader | Others] when Others =/= [] ->
                    Copies = [copy_out(Principal, O) || O <- lists:sublist(Others, 5)],
                    A#{occ_key(Leader) => #{copies => Copies, dropped => Others}};
                _ ->
                    A
            end
        end,
        Acc,
        maps:values(ByPrint)
    ).

copy_out(Principal, H) ->
    #{
        <<"account">> => maps:get(account, H),
        <<"mailbox">> => maps:get(mailbox, H),
        <<"handle">> => mailio_mcp_view:handle(Principal, H),
        <<"unread">> => maps:get(unread, H, false)
    }.

fingerprints(Hits) ->
    Self = self(),
    Workers = [
        begin
            Ref = make_ref(),
            {Pid, MRef} = spawn_monitor(fun() -> Self ! {Ref, one_fingerprint(H)} end),
            {occ_key(H), Ref, Pid, MRef}
        end
     || H <- Hits
    ],
    maps:from_list(
        lists:filtermap(
            fun({Key, Ref, Pid, MRef}) ->
                receive
                    {Ref, {ok, Print}} ->
                        erlang:demonitor(MRef, [flush]),
                        {true, {Key, Print}};
                    {Ref, _} ->
                        erlang:demonitor(MRef, [flush]),
                        false;
                    {'DOWN', MRef, process, Pid, _} ->
                        false
                after ?WORKER_TIMEOUT ->
                    exit(Pid, kill),
                    false
                end
            end,
            Workers
        )
    ).

one_fingerprint(H) ->
    Id = maps:get(account, H),
    CKey = {fp, occ_key(H)},
    case mailio_mcp_cache:get(Id, CKey) of
        {ok, P, _} ->
            {ok, P};
        miss ->
            {ok, Account} = mailio_mcp_config:account(Id),
            case
                mailio_mcp_adapter:call(
                    Account,
                    fingerprint,
                    [mailio_mcp_view:loc(H), mailio_mcp_config:limit(max_fingerprint, 1048576)]
                )
            of
                {ok, P} ->
                    mailio_mcp_cache:put(Id, CKey, P),
                    {ok, P};
                E ->
                    E
            end
    end.
