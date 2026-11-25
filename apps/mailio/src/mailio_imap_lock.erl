%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc One session at a time on an IMAP connection. An IMAP connection has one
%%% selected mailbox, and a command such as `UID STORE' acts on whatever is
%%% selected when it arrives. A caller that selects a mailbox and then sends its
%%% command is safe only if nobody else selects another mailbox between the two.
%%% This lock is how callers that share one connection take turns: whoever holds
%%% it may select and send as many commands as it needs, the others wait in the
%%% order they asked. It is given up when the holder says so, when the holder
%%% dies, or when the connection does.
-module(mailio_imap_lock).
-behaviour(gen_server).

-export([start_link/1, stop/1, with_session/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    conn :: reference(),
    holder :: {reference(), reference()} | undefined,
    queue = queue:new() :: queue:queue({gen_server:from(), reference(), reference()})
}).

%% @doc A lock for the connection `ConnPid'. It goes away with the connection.
-spec start_link(pid()) -> {ok, pid()}.
start_link(ConnPid) ->
    gen_server:start_link(?MODULE, ConnPid, []).

-spec stop(pid()) -> ok.
stop(Lock) ->
    try
        gen_server:stop(Lock)
    catch
        exit:_ -> ok
    end.

%% @doc Run `Fun' as the one session on the connection. Waits at most `Timeout'
%% milliseconds for its turn: `{error, imap_timeout}' if it does not come.
-spec with_session(pid(), timeout(), fun(() -> Result)) -> Result | {error, term()}.
with_session(Lock, Timeout, Fun) ->
    Ref = make_ref(),
    case acquire(Lock, Ref, Timeout) of
        ok ->
            try
                Fun()
            after
                gen_server:cast(Lock, {release, Ref})
            end;
        {error, _} = Error ->
            Error
    end.

acquire(Lock, Ref, Timeout) ->
    try
        gen_server:call(Lock, {acquire, Ref}, Timeout)
    catch
        exit:{timeout, _} ->
            %% a turn that comes after the caller gave up must not be kept
            gen_server:cast(Lock, {release, Ref}),
            {error, imap_timeout};
        exit:{Reason, _} when Reason =:= noproc; Reason =:= normal; Reason =:= shutdown ->
            {error, imap_disconnected}
    end.

init(ConnPid) ->
    {ok, #state{conn = erlang:monitor(process, ConnPid)}}.

handle_call({acquire, Ref}, {Pid, _}, #state{holder = undefined} = State) ->
    {reply, ok, State#state{holder = {Ref, erlang:monitor(process, Pid)}}};
handle_call({acquire, Ref}, {Pid, _} = From, #state{queue = Q} = State) ->
    %% a caller that dies while it waits is dropped at once, not when its turn comes
    {noreply, State#state{queue = queue:in({From, Ref, erlang:monitor(process, Pid)}, Q)}}.

handle_cast({release, Ref}, #state{holder = {Ref, Mon}} = State) ->
    erlang:demonitor(Mon, [flush]),
    {noreply, next(State#state{holder = undefined})};
handle_cast({release, Ref}, #state{queue = Q} = State) ->
    %% a caller that gave up while it was still waiting
    {Gone, Left} = lists:partition(fun({_, R, _}) -> R =:= Ref end, queue:to_list(Q)),
    [erlang:demonitor(M, [flush]) || {_, _, M} <- Gone],
    {noreply, State#state{queue = queue:from_list(Left)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Mon, process, _, _}, #state{conn = Mon, queue = Q} = State) ->
    [gen_server:reply(From, {error, imap_disconnected}) || {From, _, _} <- queue:to_list(Q)],
    {stop, normal, State};
handle_info({'DOWN', Mon, process, _, _}, #state{holder = {_, Mon}} = State) ->
    {noreply, next(State#state{holder = undefined})};
handle_info({'DOWN', Mon, process, _, _}, #state{queue = Q} = State) ->
    {noreply, State#state{queue = queue:filter(fun({_, _, M}) -> M =/= Mon end, Q)}};
handle_info(_Info, State) ->
    {noreply, State}.

%% The next caller in line gets its turn.
next(#state{queue = Q} = State) ->
    case queue:out(Q) of
        {empty, _} ->
            State;
        {{value, {From, Ref, Mon}}, Q1} ->
            gen_server:reply(From, ok),
            State#state{queue = Q1, holder = {Ref, Mon}}
    end.
