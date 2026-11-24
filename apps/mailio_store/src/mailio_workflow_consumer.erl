%%% @doc Durable workflow consumer.
%%%
%%% A consumer tails the account changes feed for a set of entity types,
%%% runs a handler per event, and persists its cursor so it resumes after a
%%% restart. Processing is effectively-once: before running the handler for
%%% an event it create-claims a job document keyed by the event id; barrel
%%% rejects the second create, so a consumer that crashed after handling but
%%% before advancing its cursor skips the already-done event on replay.
%%%
%%% The live event stream is only a wakeup hint; correctness comes from the
%%% durable feed and the persisted cursor, never from delivery guarantees.
-module(mailio_workflow_consumer).
-behaviour(gen_server).

-include("mailio_store.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/1, run/1, run/2, name/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {account_id :: binary(),
                db :: binary(),
                name :: binary(),
                types :: [atom()],
                verbs :: [atom()] | all,
                handler :: fun((binary(), map()) -> ok),
                cursor :: barrel_hlc:timestamp() | first}).

%%====================================================================
%% API
%%====================================================================

%% Args: #{account_id, name, types => [atom()], handler => fun/2,
%%         subscribe => boolean()}.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(#{account_id := Account, name := Name} = Args) ->
    gen_server:start_link(via(Account, Name), ?MODULE, Args, []).

%% @doc Drain all pending events now (synchronous). Returns the count handled.
-spec run(pid()) -> {ok, non_neg_integer()}.
run(Pid) ->
    gen_server:call(Pid, run, 120000).

-spec run(binary(), binary()) -> {ok, non_neg_integer()}.
run(Account, Name) ->
    gen_server:call(via(Account, Name), run, 120000).

-spec name(map()) -> binary().
name(#{name := N}) -> N.

via(Account, Name) ->
    {via, mailio_registry, {consumer, Account, Name}}.

%%====================================================================
%% gen_server
%%====================================================================

init(#{account_id := Account, name := Name} = Args) ->
    Db = mailio_account:db_name(Account),
    Cursor = load_cursor(Db, Name),
    State = #state{account_id = Account, db = Db, name = Name,
                   types = maps:get(types, Args, [email]),
                   verbs = maps:get(verbs, Args, all),
                   handler = maps:get(handler, Args),
                   cursor = Cursor},
    case maps:get(subscribe, Args, false) of
        true -> _ = mailio_events:subscribe(#{account => Account, types => State#state.types});
        false -> ok
    end,
    {ok, State}.

handle_call(run, _From, State) ->
    {N, State1} = drain(State, 0),
    {reply, {ok, N}, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Live event = wakeup hint: drain the durable feed.
handle_info({mailio_event, _Ref, _Env}, State) ->
    {_N, State1} = drain(State, 0),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Draining
%%====================================================================

drain(#state{account_id = Account, types = Types, cursor = Cursor} = State, N) ->
    {ok, Envs, NewCursor, More} =
        mailio_changes:since(Account, Cursor, #{types => Types, limit => 100}),
    Wanted = [E || E <- Envs, verb_wanted(State#state.verbs, maps:get(verb, E))],
    N1 = lists:foldl(fun(Env, Acc) -> process_once(State, Env) + Acc end, N, Wanted),
    State1 = State#state{cursor = NewCursor},
    persist_cursor(State1),
    case More of
        more -> drain(State1, N1);
        done -> {N1, State1}
    end.

%% Returns 1 if the handler ran, 0 if the event was already processed.
process_once(#state{db = Db, name = Name, account_id = Account, handler = Handler}, Env) ->
    EventId = maps:get(id, Env),
    JobId = <<?ID_JOB, Name/binary, "/", EventId/binary>>,
    Job = #{<<"id">> => JobId, <<"event">> => EventId,
            <<"at">> => erlang:system_time(second)},
    case mailio_db:put(Db, Job) of
        {ok, _, _} ->
            run_handler(Handler, Account, Env),
            1;
        {error, conflict} ->
            0
    end.

verb_wanted(all, _Verb) -> true;
verb_wanted(Verbs, Verb) -> lists:member(Verb, Verbs).

run_handler(Handler, Account, Env) ->
    try Handler(Account, Env)
    catch Class:Reason:St ->
        ?LOG_WARNING(#{what => workflow_handler_failed,
                       class => Class, reason => Reason, stack => St}),
        ok
    end.

%%====================================================================
%% Cursor persistence
%%====================================================================

load_cursor(Db, Name) ->
    case mailio_db:get(Db, cursor_id(Name)) of
        {ok, #{<<"cursor">> := Token}} ->
            case mailio_cursor:decode(Token) of
                {ok, C} -> C;
                {error, _} -> first
            end;
        {error, not_found} ->
            first
    end.

persist_cursor(#state{db = Db, name = Name, cursor = Cursor}) ->
    Id = cursor_id(Name),
    Doc0 = #{<<"id">> => Id, <<"cursor">> => mailio_cursor:encode(Cursor),
             <<"at">> => erlang:system_time(second)},
    Doc = case mailio_db:get(Db, Id) of
              {ok, #{<<"_rev">> := Rev}} -> Doc0#{<<"_rev">> => Rev};
              _ -> Doc0
          end,
    {ok, _, _} = mailio_db:put(Db, Doc),
    ok.

cursor_id(Name) -> <<?ID_JOB, "cursor/", Name/binary>>.
