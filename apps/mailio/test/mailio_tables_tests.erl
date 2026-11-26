%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% The registry and the event subscriptions are written by their owners only.
-module(mailio_tables_tests).
-include_lib("eunit/include/eunit.hrl").

with_owners(Fun) ->
    Started = [
        case Mod:start_link() of
            {ok, Pid} -> {Mod, Pid};
            {error, {already_started, _}} -> {Mod, already}
        end
     || Mod <- [mailio_registry, mailio_events]
    ],
    try
        Fun()
    after
        [unlink(P) || {_, P} <- Started, is_pid(P)],
        [exit(P, shutdown) || {_, P} <- Started, is_pid(P)]
    end.

writes(Table, Row) ->
    Self = self(),
    spawn(fun() ->
        R =
            try
                ets:insert(Table, Row)
            catch
                error:Reason -> {'EXIT', {Reason, []}}
            end,
        Self ! {result, R}
    end),
    receive
        {result, R} -> R
    after 2000 -> timeout
    end.

another_process_cannot_write_the_registry_test() ->
    with_owners(fun() ->
        ?assertMatch({'EXIT', {badarg, _}}, writes(mailio_registry, {fake_name, self()})),
        %% reading and the via callbacks still work
        yes = mailio_registry:register_name({tables_test, 1}, self()),
        ?assertEqual(self(), mailio_registry:whereis_name({tables_test, 1})),
        mailio_registry:unregister_name({tables_test, 1})
    end).

another_process_cannot_write_the_subscriptions_test() ->
    with_owners(fun() ->
        ?assertMatch(
            {'EXIT', {badarg, _}}, writes(mailio_events, {sub, make_ref(), self(), '_', all})
        ),
        {ok, Ref} = mailio_events:subscribe(#{}),
        ?assertEqual(1, mailio_events:dispatch(#{type => x})),
        mailio_events:unsubscribe(Ref)
    end).

child_spec_starts_the_connection_under_a_supervisor_test() ->
    Spec = mailio_imap_conn:child_spec(#{host => <<"127.0.0.1">>, port => 143, tls => false}),
    ?assertMatch(#{start := {mailio_imap_conn, start_link, [_]}, restart := transient}, Spec),
    ?assertEqual(ok, supervisor:check_childspecs([Spec])).
