%%% @doc Run a function in its own process with a time limit.
%%%
%%% Used for code that is not ours (rule handlers, allowlisted calls, agent
%%% handlers): a crash or a hang there must not take the caller down or block
%%% it for longer than the limit. A function that runs too long is killed.
-module(mailio_isolate).

-export([run/2]).

-spec run(fun(() -> term()), timeout()) ->
    {ok, term()} | {error, {crashed, term()} | timeout}.
run(Fun, Timeout) when is_function(Fun, 0) ->
    Ref = make_ref(),
    Self = self(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Result =
            try
                {ok, Fun()}
            catch
                Class:Reason:Stack ->
                    {error, {crashed, {Class, Reason, Stack}}}
            end,
        Self ! {Ref, Result}
    end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            %% died without answering (killed from outside)
            {error, {crashed, Reason}}
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(MRef, [flush]),
        receive
            {Ref, Result} -> Result
        after 0 -> {error, timeout}
        end
    end.
