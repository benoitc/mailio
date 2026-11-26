%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% The registry and the event subscriptions are written by their owners only.
-module(mailio_tables_tests).
-include_lib("eunit/include/eunit.hrl").
-behaviour(mailio_credentials).
-export([fetch/3, invalidate/3]).

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
            {'EXIT', {badarg, _}}, writes(mailio_events_subs, {sub, make_ref(), self(), '_', all})
        ),
        {ok, Ref} = mailio_events:subscribe(#{}),
        ?assertEqual(1, mailio_events:dispatch(#{type => x})),
        mailio_events:unsubscribe(Ref)
    end).

child_spec_starts_the_connection_under_a_supervisor_test() ->
    Spec = mailio_imap_conn:child_spec(#{
        host => <<"127.0.0.1">>,
        port => 143,
        tls => false,
        credentials => {provider, {?MODULE, []}, <<"acct">>, imap}
    }),
    ?assertMatch(#{start := {mailio_imap_conn, start_link, [_]}, restart := transient}, Spec),
    ?assertEqual(ok, supervisor:check_childspecs([Spec])).

%% A supervisor puts the start arguments in its reports: a secret is not allowed
%% in them, and a reference is.
child_spec_refuses_a_secret_test() ->
    Base = #{host => <<"h">>, port => 143},
    [
        ?assertError(secret_in_child_spec, mailio_imap_conn:child_spec(maps:merge(Base, Extra)))
     || Extra <- [
            #{credentials => {password, <<"u">>, <<"s3cret">>}},
            #{credentials => {oauth2, <<"u">>, <<"tok">>}},
            #{username => <<"u">>, password => <<"s3cret">>}
        ]
    ],
    Spec = mailio_imap_conn:child_spec(Base#{
        credentials => {provider, {?MODULE, []}, <<"a">>, imap}
    }),
    ?assertEqual(nomatch, string:find(lists:flatten(io_lib:format("~p", [Spec])), "s3cret")).

%% The reference is resolved when the connection logs in.
a_provider_reference_is_resolved_test() ->
    ?assertEqual(
        {ok, {password, <<"u">>, <<"from provider">>}},
        mailio_credentials:resolve({provider, {?MODULE, []}, <<"acct">>, imap})
    ).

%% the provider callback
fetch(<<"acct">>, imap, []) -> {ok, {password, <<"u">>, <<"from provider">>}}.
invalidate(_, _, _) -> ok.
