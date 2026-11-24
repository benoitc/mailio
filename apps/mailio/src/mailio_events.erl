%%% @doc Live event registry and fan-out.
%%%
%%% A single gen_server holds subscriptions in an ETS table and dispatches
%%% normalized domain events to subscriber processes. Dispatch uses plain
%%% message sends and never blocks on a slow subscriber; delivery is
%%% best-effort. Subscribers needing at-least-once semantics resume from
%%% the `seq' carried on every envelope via {@link mailio_changes:since/3}.
%%%
%%% Subscribers are monitored and their subscriptions are removed on exit.
-module(mailio_events).
-behaviour(gen_server).

-export([start_link/0]).
-export([subscribe/1, subscribe/2, unsubscribe/1, dispatch/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE, mailio_events_subs).

-record(sub, {
    ref :: reference(),
    pid :: pid(),
    account :: binary() | '_',
    types :: [atom()] | all
}).

-record(state, {monitors = #{} :: #{reference() => pid()}}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Subscribe with a topic filter map: `#{account => Id | '_',
%% types => [email|mailbox|thread|...] | all}'. Events arrive as
%% `{mailio_event, SubRef, Envelope}'.
-spec subscribe(map()) -> {ok, reference()}.
subscribe(Topic) ->
    subscribe(Topic, self()).

-spec subscribe(map(), pid()) -> {ok, reference()}.
subscribe(Topic, Pid) ->
    gen_server:call(?SERVER, {subscribe, Topic, Pid}).

-spec unsubscribe(reference()) -> ok.
unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe, Ref}).

%% @doc Dispatch an envelope to all matching subscribers. Returns the
%% number of subscribers it was delivered to.
-spec dispatch(map()) -> non_neg_integer().
dispatch(Envelope) ->
    Account = maps:get(account_id, Envelope, undefined),
    Type = maps:get(type, Envelope, undefined),
    Subs = ets:tab2list(?TABLE),
    lists:foldl(
        fun(#sub{ref = Ref, pid = Pid} = Sub, N) ->
            case matches(Sub, Account, Type) of
                true ->
                    Pid ! {mailio_event, Ref, Envelope},
                    N + 1;
                false ->
                    N
            end
        end,
        0,
        Subs
    ).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, set, public, {keypos, #sub.ref}]),
    {ok, #state{}}.

handle_call({subscribe, Topic, Pid}, _From, State) ->
    Ref = make_ref(),
    Sub = #sub{
        ref = Ref,
        pid = Pid,
        account = maps:get(account, Topic, '_'),
        types = maps:get(types, Topic, all)
    },
    ets:insert(?TABLE, Sub),
    MRef = erlang:monitor(process, Pid),
    Monitors = maps:put(MRef, Ref, State#state.monitors),
    {reply, {ok, Ref}, State#state{monitors = Monitors}};
handle_call({unsubscribe, Ref}, _From, State) ->
    ets:delete(?TABLE, Ref),
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, _Pid, _Reason}, State) ->
    case maps:take(MRef, State#state.monitors) of
        {Ref, Monitors} ->
            ets:delete(?TABLE, Ref),
            {noreply, State#state{monitors = Monitors}};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Matching
%%====================================================================

matches(#sub{account = SubAcct, types = SubTypes}, Account, Type) ->
    account_matches(SubAcct, Account) andalso type_matches(SubTypes, Type).

account_matches('_', _) -> true;
account_matches(A, A) -> true;
account_matches(_, _) -> false.

type_matches(all, _) -> true;
type_matches(Types, Type) when is_list(Types) -> lists:member(Type, Types).
