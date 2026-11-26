%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Process registry (via-compatible).
%%%
%%% A tiny name registry backed by a public ETS table, usable as a `{via,
%%% mailio_registry, Name}' target for gen_server/gen_statem. Names are
%%% arbitrary terms (e.g. `{writer, AccountId}', `{imap_conn, AccountId}'),
%%% which avoids minting atoms from binaries. The owning gen_server only
%%% holds the table; lookups are direct ETS reads for speed.
-module(mailio_registry).
-behaviour(gen_server).

-export([
    start_link/0,
    whereis_name/1,
    register_name/2,
    unregister_name/1,
    send/2,
    lookup/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE, mailio_registry).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec lookup(term()) -> {ok, pid()} | {error, not_found}.
lookup(Name) ->
    case whereis_name(Name) of
        undefined -> {error, not_found};
        Pid -> {ok, Pid}
    end.

%%====================================================================
%% via callbacks
%%====================================================================

-spec whereis_name(term()) -> pid() | undefined.
whereis_name(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, Pid}] ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> undefined
            end;
        [] ->
            undefined
    end.

-spec register_name(term(), pid()) -> yes | no.
register_name(Name, Pid) ->
    gen_server:call(?SERVER, {register, Name, Pid}).

-spec unregister_name(term()) -> ok.
unregister_name(Name) ->
    gen_server:call(?SERVER, {unregister, Name}).

-spec send(term(), term()) -> pid().
send(Name, Msg) ->
    case whereis_name(Name) of
        undefined ->
            exit({badarg, {Name, Msg}});
        Pid ->
            Pid ! Msg,
            Pid
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    ?TABLE = ets:new(?TABLE, [
        named_table,
        set,
        protected,
        {read_concurrency, true}
    ]),
    {ok, #{monitors => #{}, names => #{}}}.

handle_call({register, Name, Pid}, _From, State) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, Existing}] ->
            case is_process_alive(Existing) of
                true -> {reply, no, State};
                false -> do_register(Name, Pid, State)
            end;
        [] ->
            do_register(Name, Pid, State)
    end;
handle_call({unregister, Name}, _From, State) ->
    ets:delete(?TABLE, Name),
    {reply, ok, drop_monitor(Name, State)};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, Pid, _Reason}, #{monitors := Mons, names := Names} = State) ->
    case maps:take(MRef, Mons) of
        {Name, Mons1} ->
            %% Only remove the entry if it still belongs to the process that died.
            ets:match_delete(?TABLE, {Name, Pid}),
            {noreply, State#{monitors => Mons1, names => maps:remove(Name, Names)}};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

do_register(Name, Pid, State0) ->
    #{monitors := Mons, names := Names} = drop_monitor(Name, State0),
    ets:insert(?TABLE, {Name, Pid}),
    MRef = erlang:monitor(process, Pid),
    {reply, yes, State0#{
        monitors => maps:put(MRef, Name, Mons),
        names => maps:put(Name, MRef, Names)
    }}.

drop_monitor(Name, #{monitors := Mons, names := Names} = State) ->
    case maps:take(Name, Names) of
        {MRef, Names1} ->
            erlang:demonitor(MRef, [flush]),
            State#{monitors => maps:remove(MRef, Mons), names => Names1};
        error ->
            State
    end.
