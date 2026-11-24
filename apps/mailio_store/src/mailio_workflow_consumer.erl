%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Durable workflow consumer.
%%%
%%% A consumer tails the account changes feed for a set of entity types,
%%% runs a handler per event, and persists its cursor so it resumes after a
%%% restart.
%%%
%%% The handler runs in its own process with a time limit
%%% (`handler_timeout', default 30 s): a crash or a hang there never takes the
%%% consumer down. Each event has a job document keyed by the event id with a
%%% state: `claimed' (running, with a lease), `done' or `failed'. An event
%%% whose job is `done' is never run again. A `failed' job, or a `claimed' one
%%% whose lease ran out (the consumer died mid-run), is tried again on a later
%%% drain, up to `handler_max_attempts' (default 3) attempts in all; after
%%% that it stays `failed' and is logged. This is at-least-once, so a handler
%%% must be safe to run twice for the same event.
%%%
%%% The live event stream is only a wakeup hint; correctness comes from the
%%% durable feed, the job documents and the persisted cursor, never from
%%% delivery guarantees.
-module(mailio_workflow_consumer).
-behaviour(gen_server).

-include("mailio_store.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/1, run/1, run/2, name/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    account_id :: binary(),
    db :: binary(),
    name :: binary(),
    types :: [atom()],
    verbs :: [atom()] | all,
    handler :: fun((binary(), map()) -> ok),
    cursor :: barrel_hlc:timestamp() | first
}).

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
    State = #state{
        account_id = Account,
        db = Db,
        name = Name,
        types = maps:get(types, Args, [email]),
        verbs = maps:get(verbs, Args, all),
        handler = maps:get(handler, Args),
        cursor = Cursor
    },
    _ =
        case maps:get(subscribe, Args, false) of
            true -> mailio_events:subscribe(#{account => Account, types => State#state.types});
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

drain(State, N) ->
    drain_events(State, N + retry_pending(State)).

drain_events(#state{account_id = Account, types = Types, cursor = Cursor} = State, N) ->
    {ok, Envs, NewCursor, More} =
        mailio_changes:since(Account, Cursor, #{types => Types, limit => 100}),
    Wanted = [E || E <- Envs, verb_wanted(State#state.verbs, maps:get(verb, E))],
    N1 = lists:foldl(fun(Env, Acc) -> process_once(State, Env) + Acc end, N, Wanted),
    State1 = State#state{cursor = NewCursor},
    persist_cursor(State1),
    case More of
        more -> drain_events(State1, N1);
        done -> {N1, State1}
    end.

%% Claim the job for a new event and run it. Returns 1 if the handler
%% succeeded, 0 if it failed or the event was seen before.
process_once(#state{db = Db, name = Name} = State, Env) ->
    EventId = maps:get(id, Env),
    JobId = job_id(Name, EventId),
    Job = #{
        <<"id">> => JobId,
        <<"event">> => EventId,
        <<"env">> => encode_env(Env),
        <<"status">> => <<"claimed">>,
        <<"attempts">> => 1,
        <<"lease_until">> => lease_until(),
        <<"at">> => erlang:system_time(second)
    },
    case mailio_db:put(Db, Job) of
        {ok, _, _} -> attempt(State, Job, Env);
        {error, conflict} -> 0
    end.

job_id(Name, EventId) -> <<?ID_JOB, Name/binary, "/", EventId/binary>>.

%% Run the handler for a job already marked `claimed' and record the outcome.
attempt(#state{db = Db, account_id = Account, handler = Handler}, Job, Env) ->
    Result = mailio_isolate:run(fun() -> Handler(Account, Env) end, handler_timeout()),
    Id = maps:get(<<"id">>, Job),
    {ok, Current} = mailio_db:get(Db, Id),
    case Result of
        {ok, _} ->
            {ok, _, _} = mailio_db:put(Db, Current#{
                <<"status">> => <<"done">>, <<"finished_at">> => erlang:system_time(second)
            }),
            1;
        {error, Reason} ->
            Attempts = maps:get(<<"attempts">>, Current, 1),
            ?LOG_WARNING(#{
                what => workflow_handler_failed,
                job => Id,
                attempt => Attempts,
                gives_up => Attempts >= max_attempts(),
                reason => Reason
            }),
            {ok, _, _} = mailio_db:put(Db, Current#{
                <<"status">> => <<"failed">>,
                <<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))
            }),
            0
    end.

%% Try again the jobs that failed or whose consumer died while running them.
retry_pending(#state{db = Db, name = Name} = State) ->
    {ok, Docs} = mailio_db:by_id_prefix(Db, <<?ID_JOB, Name/binary, "/">>),
    Now = erlang:system_time(second),
    lists:foldl(
        fun(Job, Acc) ->
            case retryable(Job, Now) of
                true -> Acc + retry(State, Job);
                false -> Acc
            end
        end,
        0,
        Docs
    ).

retryable(#{<<"status">> := <<"failed">>, <<"attempts">> := N}, _Now) ->
    N < max_attempts();
retryable(#{<<"status">> := <<"claimed">>, <<"attempts">> := N, <<"lease_until">> := L}, Now) ->
    L < Now andalso N < max_attempts();
retryable(_, _) ->
    false.

retry(#state{db = Db} = State, Job) ->
    Env = decode_env(maps:get(<<"env">>, Job)),
    {ok, Current} = mailio_db:get(Db, maps:get(<<"id">>, Job)),
    Claimed = Current#{
        <<"status">> => <<"claimed">>,
        <<"attempts">> => maps:get(<<"attempts">>, Current) + 1,
        <<"lease_until">> => lease_until()
    },
    {ok, _, _} = mailio_db:put(Db, Claimed),
    attempt(State, Claimed, Env).

lease_until() ->
    erlang:system_time(second) + (handler_timeout() div 1000) + 30.

handler_timeout() -> mailio_config:get(handler_timeout, 30000).
max_attempts() -> mailio_config:get(handler_max_attempts, 3).

%% The event is kept in the job so it can be run again after the cursor moved on.
encode_env(Env) -> base64:encode(term_to_binary(Env)).
decode_env(Bin) -> binary_to_term(base64:decode(Bin), [safe]).

verb_wanted(all, _Verb) -> true;
verb_wanted(Verbs, Verb) -> lists:member(Verb, Verbs).

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
    Doc0 = #{
        <<"id">> => Id,
        <<"cursor">> => mailio_cursor:encode(Cursor),
        <<"at">> => erlang:system_time(second)
    },
    Doc =
        case mailio_db:get(Db, Id) of
            {ok, #{<<"_rev">> := Rev}} -> Doc0#{<<"_rev">> => Rev};
            _ -> Doc0
        end,
    {ok, _, _} = mailio_db:put(Db, Doc),
    ok.

cursor_id(Name) -> <<?ID_JOB, "cursor/", Name/binary>>.
