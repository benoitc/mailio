%%% @doc Action executor for rules and agents.
%%%
%%% A single audited vocabulary that both the rules engine and AI handlers
%%% emit, so every automated mutation goes through the same path. Keyword
%%% and mailbox changes are batched into one writer patch; side effects
%%% (notify, MFA call, agent task) run after. MFA calls are restricted to a
%%% configured module allowlist — rules and AI output never invoke
%%% arbitrary code.
%%%
%%% Action forms:
%%% <ul>
%%%   <li>`{add_keywords, [binary()]}' / `{remove_keywords, [binary()]}'</li>
%%%   <li>`{mark, read | unread | flagged | unflagged}'</li>
%%%   <li>`{move, MailboxId}' (set membership to just that mailbox)</li>
%%%   <li>`{add_mailbox, Id}' / `{remove_mailbox, Id}'</li>
%%%   <li>`{notify, Pid | {topic, Term}}'</li>
%%%   <li>`{call, {Module, Fun}}' (allowlisted; `Module:Fun(Account, EmailId)')</li>
%%%   <li>`{agent_task, Kind, Opts}' (dispatched to the configured handler)</li>
%%% </ul>
-module(mailio_actions).

-include("mailio_store.hrl").
-include_lib("kernel/include/logger.hrl").

-export([apply/3, apply/4]).

-type action() :: term().
-type ctx() :: map().

-spec apply(binary(), binary(), [action()]) -> ok.
apply(Account, EmailId, Actions) ->
    apply(Account, EmailId, Actions, #{}).

-spec apply(binary(), binary(), [action()], ctx()) -> ok.
apply(Account, EmailId, Actions, Ctx) ->
    {Patch, Effects} = lists:foldl(fun classify/2, {#{}, []}, Actions),
    case map_size(Patch) of
        0 -> ok;
        _ -> _ = mailio_account_writer:patch(Account, EmailId, Patch), ok
    end,
    lists:foreach(fun(E) -> run_effect(Account, EmailId, E, Ctx) end,
                  lists:reverse(Effects)),
    ok.

%%====================================================================
%% Classify actions into a batched patch + ordered side effects
%%====================================================================

classify({add_keywords, Kws}, {P, E}) ->
    {merge_list(P, add_keywords, Kws), E};
classify({remove_keywords, Kws}, {P, E}) ->
    {merge_list(P, remove_keywords, Kws), E};
classify({mark, read}, {P, E}) ->
    {merge_list(P, add_keywords, [?KW_SEEN]), E};
classify({mark, unread}, {P, E}) ->
    {merge_list(P, remove_keywords, [?KW_SEEN]), E};
classify({mark, flagged}, {P, E}) ->
    {merge_list(P, add_keywords, [?KW_FLAGGED]), E};
classify({mark, unflagged}, {P, E}) ->
    {merge_list(P, remove_keywords, [?KW_FLAGGED]), E};
classify({move, MailboxId}, {P, E}) ->
    {P#{set_mailboxes => [MailboxId]}, E};
classify({add_mailbox, Id}, {P, E}) ->
    {merge_list(P, add_mailboxes, [Id]), E};
classify({remove_mailbox, Id}, {P, E}) ->
    {merge_list(P, remove_mailboxes, [Id]), E};
classify({notify, _} = Eff, {P, E}) ->
    {P, [Eff | E]};
classify({call, _} = Eff, {P, E}) ->
    {P, [Eff | E]};
classify({agent_task, _, _} = Eff, {P, E}) ->
    {P, [Eff | E]};
classify(_Unknown, Acc) ->
    Acc.

merge_list(Patch, Key, Vals) ->
    Patch#{Key => maps:get(Key, Patch, []) ++ Vals}.

%%====================================================================
%% Side effects
%%====================================================================

run_effect(Account, EmailId, {notify, Pid}, _Ctx) when is_pid(Pid) ->
    Pid ! {mailio_action, notify, #{account => Account, email_id => EmailId}},
    ok;
run_effect(Account, EmailId, {notify, {topic, Topic}}, _Ctx) ->
    mailio_events:dispatch(#{v => 1, account_id => Account, type => notify,
                            verb => updated, object_id => EmailId,
                            data => #{topic => Topic}}),
    ok;
run_effect(Account, EmailId, {call, {Module, Fun}}, _Ctx) ->
    case is_allowed(Module) of
        true ->
            try Module:Fun(Account, EmailId)
            catch Class:Reason ->
                ?LOG_WARNING(#{what => action_call_failed, module => Module,
                               fun_ => Fun, class => Class, reason => Reason}),
                ok
            end;
        false ->
            ?LOG_WARNING(#{what => action_call_blocked, module => Module}),
            ok
    end;
run_effect(Account, EmailId, {agent_task, Kind, Opts}, Ctx) ->
    case agent_handler() of
        undefined ->
            ok;
        Handler ->
            run_agent_task(Handler, Account, EmailId, Kind, Opts, Ctx)
    end;
run_effect(_Account, _EmailId, _Other, _Ctx) ->
    ok.

%% The handler returns more actions, which are applied (one level, no
%% recursion into further agent tasks to bound work).
run_agent_task(Handler, Account, EmailId, Kind, Opts, Ctx) ->
    try Handler:handle_task(Kind, Account, EmailId, Opts) of
        {ok, Actions} when is_list(Actions) ->
            Safe = [A || A <- Actions, not is_agent_task(A)],
            apply(Account, EmailId, Safe, Ctx);
        _ ->
            ok
    catch Class:Reason ->
        ?LOG_WARNING(#{what => agent_task_failed, kind => Kind,
                       class => Class, reason => Reason}),
        ok
    end.

is_agent_task({agent_task, _, _}) -> true;
is_agent_task(_) -> false.

is_allowed(Module) ->
    lists:member(Module, mailio_config:get(actions_call_allowlist, [])).

agent_handler() ->
    mailio_config:get(agent_handler, undefined).
