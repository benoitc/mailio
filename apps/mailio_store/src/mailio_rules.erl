%%% @doc Rule storage and evaluation.
%%%
%%% Rules are data, not code: a rule is a stored document with a `when'
%%% filter (the same condition grammar as Email/query, evaluated by
%%% {@link mailio_filter}) and a list of declarative actions (executed by
%%% {@link mailio_actions}). MFA call actions are restricted to an
%%% allowlist, so no rule can run arbitrary code.
%%%
%%% {@link apply_to_email/2} runs the enabled rules over one email in
%%% priority order, stopping early if a matched rule sets `stopProcessing'.
-module(mailio_rules).

-include("mailio_store.hrl").

-export([add/2, get/2, list/1, remove/2, set_enabled/3]).
-export([apply_to_email/2]).
-export([start_consumer/1, start_consumer/2, handler/0]).

-define(CONSUMER_NAME, <<"rules">>).

%%====================================================================
%% CRUD
%%====================================================================

%% @doc Store a rule. `Spec' keys: `name', `enabled' (default true),
%% `priority' (default 0), `when' (filter map), `actions' (list of action
%% maps), `stop_processing' (default false). Returns the rule id.
-spec add(binary(), map()) -> {ok, binary()}.
add(Account, Spec) ->
    Db = mailio_account:db_name(Account),
    RuleId = mailio_id:rule_id(),
    Doc = #{
        <<"id">> => <<?ID_RULE, RuleId/binary>>,
        <<"name">> => maps:get(name, Spec, <<>>),
        <<"enabled">> => maps:get(enabled, Spec, true),
        <<"priority">> => maps:get(priority, Spec, 0),
        <<"when">> => jsonify(maps:get('when', Spec, #{})),
        <<"actions">> => jsonify(maps:get(actions, Spec, [])),
        <<"stopProcessing">> => maps:get(stop_processing, Spec, false)
    },
    {ok, _, _} = mailio_db:put(Db, Doc),
    {ok, RuleId}.

-spec get(binary(), binary()) -> {ok, map()} | {error, not_found}.
get(Account, RuleId) ->
    mailio_db:get(mailio_account:db_name(Account), <<?ID_RULE, RuleId/binary>>).

-spec list(binary()) -> {ok, [map()]}.
list(Account) ->
    {ok, Docs} = mailio_db:by_id_prefix(mailio_account:db_name(Account), <<?ID_RULE>>),
    {ok, Docs}.

-spec remove(binary(), binary()) -> ok.
remove(Account, RuleId) ->
    _ = mailio_db:delete(mailio_account:db_name(Account), <<?ID_RULE, RuleId/binary>>),
    ok.

-spec set_enabled(binary(), binary(), boolean()) -> ok | {error, not_found}.
set_enabled(Account, RuleId, Enabled) ->
    Db = mailio_account:db_name(Account),
    case mailio_db:get(Db, <<?ID_RULE, RuleId/binary>>) of
        {ok, Doc} ->
            {ok, _, _} = mailio_db:put(Db, Doc#{<<"enabled">> => Enabled}),
            ok;
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Durable consumer
%%====================================================================

%% @doc Start the durable rules consumer for an account: it runs enabled
%% rules on each newly created email, effectively-once, resuming from a
%% persisted cursor.
-spec start_consumer(binary()) -> {ok, pid()} | {error, term()}.
start_consumer(Account) ->
    start_consumer(Account, #{}).

-spec start_consumer(binary(), map()) -> {ok, pid()} | {error, term()}.
start_consumer(Account, Opts) ->
    mailio_workflow_consumer:start_link(#{
        account_id => Account,
        name => ?CONSUMER_NAME,
        types => [email],
        verbs => [created],
        handler => handler(),
        subscribe => maps:get(subscribe, Opts, false)
    }).

%% @doc The consumer handler: apply rules to newly created emails.
-spec handler() -> fun((binary(), map()) -> ok).
handler() ->
    fun
        (Account, #{verb := created, object_id := EmailId}) ->
            _ = apply_to_email(Account, EmailId),
            ok;
        (_Account, _Env) ->
            ok
    end.

%%====================================================================
%% Evaluation
%%====================================================================

%% @doc Run enabled rules over one email. Returns the ids of rules that
%% matched (and whose actions were applied).
-spec apply_to_email(binary(), binary()) -> {ok, [binary()]}.
apply_to_email(Account, EmailId) ->
    Db = mailio_account:db_name(Account),
    case mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>) of
        {ok, Email} ->
            Rules = enabled_sorted(Db),
            BodyGetter = body_getter(Db, EmailId),
            Applied = run_rules(Account, EmailId, Email, BodyGetter, Rules, []),
            {ok, lists:reverse(Applied)};
        {error, not_found} ->
            {ok, []}
    end.

enabled_sorted(Db) ->
    {ok, Docs} = mailio_db:by_id_prefix(Db, <<?ID_RULE>>),
    Enabled = [D || D <- Docs, maps:get(<<"enabled">>, D, true) =:= true],
    %% Higher priority first; stable within equal priority.
    lists:sort(
        fun(A, B) ->
            maps:get(<<"priority">>, A, 0) >= maps:get(<<"priority">>, B, 0)
        end,
        Enabled
    ).

run_rules(_Account, _EmailId, _Email, _Body, [], Applied) ->
    Applied;
run_rules(Account, EmailId, Email, Body, [Rule | Rest], Applied) ->
    Filter = mailio_filter:normalize(maps:get(<<"when">>, Rule, #{})),
    case mailio_filter:matches(Email, Body, Filter) of
        true ->
            Actions = to_actions(maps:get(<<"actions">>, Rule, [])),
            ok = mailio_actions:apply(Account, EmailId, Actions),
            RuleId = rule_id_of(Rule),
            case maps:get(<<"stopProcessing">>, Rule, false) of
                true -> [RuleId | Applied];
                false -> run_rules(Account, EmailId, Email, Body, Rest, [RuleId | Applied])
            end;
        false ->
            run_rules(Account, EmailId, Email, Body, Rest, Applied)
    end.

rule_id_of(#{<<"id">> := <<?ID_RULE, Id/binary>>}) -> Id.

body_getter(Db, EmailId) ->
    fun() ->
        case mailio_db:get(Db, <<?ID_TEXT, EmailId/binary>>) of
            {ok, #{<<"body_text">> := T}} -> T;
            _ -> <<>>
        end
    end.

%%====================================================================
%% Action document -> action term conversion
%%====================================================================

to_actions(Actions) ->
    lists:filtermap(fun to_action/1, Actions).

to_action(#{<<"type">> := <<"add_keywords">>, <<"keywords">> := Kws}) ->
    {true, {add_keywords, Kws}};
to_action(#{<<"type">> := <<"remove_keywords">>, <<"keywords">> := Kws}) ->
    {true, {remove_keywords, Kws}};
to_action(#{<<"type">> := <<"mark">>, <<"value">> := V}) ->
    {true, {mark, binary_to_existing_atom_safe(V)}};
to_action(#{<<"type">> := <<"move">>, <<"mailbox">> := M}) ->
    {true, {move, M}};
to_action(#{<<"type">> := <<"notify">>, <<"topic">> := T}) ->
    {true, {notify, {topic, T}}};
to_action(#{<<"type">> := <<"call">>, <<"mfa">> := [M, F]}) ->
    {true, {call, {binary_to_existing_atom_safe(M), binary_to_existing_atom_safe(F)}}};
to_action(#{<<"type">> := <<"agent_task">>} = A) ->
    {true, {agent_task, maps:get(<<"kind">>, A, <<>>), maps:get(<<"opts">>, A, #{})}};
to_action(_) ->
    false.

binary_to_existing_atom_safe(B) when is_binary(B) ->
    try
        binary_to_existing_atom(B, utf8)
    catch
        _:_ -> '$undefined'
    end;
binary_to_existing_atom_safe(A) when is_atom(A) ->
    A.

%% Convert a term to a JSON-safe shape for storage: atom map keys and
%% non-boolean atom values become binaries (barrel docs must use binary
%% keys; the filter is normalized back to atoms on read).
jsonify(M) when is_map(M) ->
    maps:fold(fun(K, V, Acc) -> Acc#{atom_key(K) => jsonify(V)} end, #{}, M);
jsonify(L) when is_list(L) ->
    [jsonify(E) || E <- L];
jsonify(A) when is_atom(A), A =/= true, A =/= false, A =/= null ->
    atom_to_binary(A, utf8);
jsonify(X) ->
    X.

atom_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
atom_key(K) -> K.
