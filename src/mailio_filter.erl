%%% @doc JMAP Email/query filter evaluation (pure).
%%%
%%% Evaluates a JMAP FilterCondition / FilterOperator tree against an email
%%% document. Body/text conditions need the extracted body text, which is
%%% stored in a separate `text/<id>' document, so it is supplied lazily via
%%% a getter the caller fetches only when a body/text condition is present.
%%%
%%% Substring conditions (text/from/to/subject/...) are case-insensitive
%%% containment; structural conditions (mailbox, keywords, dates, sizes)
%%% mirror RFC 8621 semantics. This module also extracts the subset of a
%%% filter that can be pushed down to an indexed `barrel' query so the
%%% planner can narrow candidates before evaluating the full predicate here.
-module(mailio_filter).

-include("mailio.hrl").

-export([matches/2, matches/3, needs_body/1, index_query/1]).

-export_type([filter/0]).

-type filter() :: map().
-type body_getter() :: fun(() -> binary()).

%%====================================================================
%% Evaluation
%%====================================================================

-spec matches(map(), filter()) -> boolean().
matches(Email, Filter) ->
    matches(Email, fun() -> <<>> end, Filter).

%% @doc Evaluate `Filter' against `Email'. `BodyGetter/0' yields the email's
%% extracted body text (called at most once, only if needed).
-spec matches(map(), body_getter(), filter()) -> boolean().
matches(_Email, _BodyGetter, Filter) when map_size(Filter) =:= 0 ->
    true;
matches(Email, BodyGetter, #{operator := Op} = Filter) ->
    Conditions = maps:get(conditions, Filter, []),
    eval_operator(op_atom(Op), Email, BodyGetter, Conditions);
matches(Email, BodyGetter, Filter) ->
    %% A FilterCondition is the AND of all its keys.
    Ctx = #{email => Email, body => BodyGetter},
    lists:all(fun({K, V}) -> cond_matches(Ctx, K, V) end, maps:to_list(Filter)).

eval_operator('AND', Email, BodyGetter, Conds) ->
    lists:all(fun(C) -> matches(Email, BodyGetter, C) end, Conds);
eval_operator('OR', Email, BodyGetter, Conds) ->
    lists:any(fun(C) -> matches(Email, BodyGetter, C) end, Conds);
eval_operator('NOT', Email, BodyGetter, Conds) ->
    not lists:any(fun(C) -> matches(Email, BodyGetter, C) end, Conds).

op_atom(Op) when is_atom(Op) -> Op;
op_atom(<<"AND">>) -> 'AND';
op_atom(<<"OR">>) -> 'OR';
op_atom(<<"NOT">>) -> 'NOT'.

%%====================================================================
%% Individual conditions
%%====================================================================

cond_matches(#{email := E}, inMailbox, MbxId) ->
    mailio_email:in_mailbox(E, MbxId);
cond_matches(#{email := E}, inMailboxOtherThan, MbxIds) ->
    Set = sets:from_list(MbxIds),
    lists:any(fun(M) -> not sets:is_element(M, Set) end, mailio_email:mailbox_ids(E));
cond_matches(#{email := E}, before, Date) ->
    received_ts(E) < to_epoch(Date);
cond_matches(#{email := E}, after_, Date) ->
    received_ts(E) >= to_epoch(Date);
cond_matches(#{email := E}, 'after', Date) ->
    received_ts(E) >= to_epoch(Date);
cond_matches(#{email := E}, minSize, N) ->
    mailio_email:size(E) >= N;
cond_matches(#{email := E}, maxSize, N) ->
    mailio_email:size(E) =< N;
cond_matches(#{email := E}, hasKeyword, Kw) ->
    mailio_email:has_keyword(E, Kw);
cond_matches(#{email := E}, notKeyword, Kw) ->
    not mailio_email:has_keyword(E, Kw);
cond_matches(#{email := E}, hasAttachment, Bool) ->
    maps:get(<<"hasAttachment">>, E, false) =:= Bool;
cond_matches(#{email := E}, inThread, ThreadId) ->
    mailio_email:thread_id(E) =:= ThreadId;
cond_matches(#{email := E}, from, Sub) ->
    addr_contains(E, [<<"from">>, <<"sender">>], Sub);
cond_matches(#{email := E}, to, Sub) ->
    addr_contains(E, [<<"to">>], Sub);
cond_matches(#{email := E}, cc, Sub) ->
    addr_contains(E, [<<"cc">>], Sub);
cond_matches(#{email := E}, bcc, Sub) ->
    addr_contains(E, [<<"bcc">>], Sub);
cond_matches(#{email := E}, subject, Sub) ->
    contains(subject_text(E), Sub);
cond_matches(Ctx, body, Sub) ->
    contains(body_text(Ctx), Sub);
cond_matches(Ctx, text, Sub) ->
    %% `text' matches any of subject, addresses, or body.
    #{email := E} = Ctx,
    contains(subject_text(E), Sub)
        orelse addr_contains(E, [<<"from">>, <<"to">>, <<"cc">>, <<"bcc">>], Sub)
        orelse contains(body_text(Ctx), Sub);
cond_matches(_Ctx, _Unknown, _Value) ->
    %% Unknown conditions do not constrain (lenient).
    true.

%%====================================================================
%% Indexable subset extraction
%%====================================================================

%% @doc Whether a filter references body/text content (so the planner must
%% load body text before evaluation).
-spec needs_body(filter()) -> boolean().
needs_body(#{operator := _} = F) ->
    lists:any(fun needs_body/1, maps:get(conditions, F, []));
needs_body(F) when is_map(F) ->
    maps:is_key(body, F) orelse maps:is_key(text, F);
needs_body(_) ->
    false.

%% @doc Extract the structural conditions of a top-level AND (or a bare
%% condition map) as a `barrel' query `where' list, to narrow candidates
%% before the full predicate runs. Returns `all' when nothing indexable can
%% be pushed down (the caller then scans all emails).
-spec index_query(filter()) -> {where, [term()]} | all.
index_query(#{operator := Op} = F) ->
    case op_atom(Op) of
        'AND' ->
            Wheres = lists:flatmap(fun sub_index/1, maps:get(conditions, F, [])),
            wrap(Wheres);
        _ ->
            all
    end;
index_query(F) when is_map(F), map_size(F) > 0 ->
    wrap(condition_wheres(F));
index_query(_) ->
    all.

sub_index(Cond) when is_map(Cond) ->
    case maps:is_key(operator, Cond) of
        true -> [];                       %% nested operators: not pushed down
        false -> condition_wheres(Cond)
    end;
sub_index(_) -> [].

wrap([]) -> all;
wrap(Wheres) -> {where, Wheres}.

%% Map the indexable keys of a single condition map to barrel `where' clauses.
condition_wheres(Cond) ->
    lists:flatmap(fun({K, V}) -> where_for(K, V) end, maps:to_list(Cond)).

%% Map the indexable keys of a condition to barrel `where' clauses. Ranges
%% (before+after, min+maxSize) push both bounds; barrel_docdb >= 0.8.0
%% intersects multiple compare conditions correctly.
where_for(inMailbox, MbxId) -> [{path, [<<"mailboxIds">>, MbxId], true}];
where_for(hasKeyword, Kw) -> [{path, [<<"keywords">>, Kw], true}];
where_for(hasAttachment, true) -> [{path, [<<"hasAttachment">>], true}];
where_for(inThread, Tid) -> [{path, [<<"threadId">>], Tid}];
where_for(minSize, N) -> [{compare, [<<"size">>], '>=', N}];
where_for(maxSize, N) -> [{compare, [<<"size">>], '=<', N}];
where_for(after_, Date) -> [{compare, [?MAILIO_NS, <<"received_ts">>], '>=', to_epoch(Date)}];
where_for('after', Date) -> [{compare, [?MAILIO_NS, <<"received_ts">>], '>=', to_epoch(Date)}];
where_for(before, Date) -> [{compare, [?MAILIO_NS, <<"received_ts">>], '<', to_epoch(Date)}];
where_for(_K, _V) -> [].   %% substring/negation conditions: post-filter only

%%====================================================================
%% Field helpers
%%====================================================================

received_ts(E) ->
    Ns = maps:get(?MAILIO_NS, E, #{}),
    maps:get(<<"received_ts">>, Ns, 0).

subject_text(E) ->
    case maps:get(<<"subject">>, E, null) of
        null -> <<>>;
        S -> S
    end.

body_text(#{body := Getter}) -> Getter().

addr_contains(E, Fields, Sub) ->
    Addrs = lists:flatmap(fun(F) -> addr_list(maps:get(F, E, null)) end, Fields),
    Hay = iolist_to_binary(lists:join(<<" ">>, Addrs)),
    contains(Hay, Sub).

addr_list(null) -> [];
addr_list(List) when is_list(List) ->
    lists:flatmap(fun(#{<<"email">> := Em} = A) ->
                      Name = case maps:get(<<"name">>, A, null) of
                                 null -> <<>>;
                                 N -> N
                             end,
                      [Em, Name]
                  end, List).

contains(_Hay, <<>>) -> true;
contains(Hay, Needle) when is_binary(Hay), is_binary(Needle) ->
    binary:match(mailio_ascii:lower(Hay), mailio_ascii:lower(Needle)) =/= nomatch;
contains(_Hay, _Needle) ->
    false.

%% Parse a JMAP UTCDate (RFC 3339) to epoch seconds.
to_epoch(Date) when is_integer(Date) -> Date;
to_epoch(Date) when is_binary(Date) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Date), [{unit, second}])
    catch _:_ ->
        case mailio_rfc5322:parse_date(Date) of
            {ok, E} -> E;
            error -> 0
        end
    end.
