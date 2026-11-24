%%% mail_changes on IMAP against mailio_fake_imap, which implements
%%% CONDSTORE and QRESYNC. The server's command log shows which path ran.
-module(mailio_mcp_imap_changes_tests).
-include_lib("eunit/include/eunit.hrl").

account(Srv) ->
    #{
        id => <<"fake">>,
        incoming => #{
            protocol => imap, host => "127.0.0.1", port => mailio_fake_imap:port(Srv), tls => none
        },
        auth => #{user => <<"u">>, secret => {value, <<"p">>}, mechanism => login}
    }.

with(Fun) ->
    ok = mailio_mcp_stats:init(),
    Srv = mailio_fake_imap:start(),
    try
        Fun(Srv, account(Srv))
    after
        mailio_fake_imap:stop(Srv)
    end.

changes(Acc, Prev) -> mailio_mcp_imap:changes(Acc, <<"INBOX">>, Prev).

baseline(Acc) ->
    {ok, #{baseline := true, snapshot := Snap}} = changes(Acc, undefined),
    Snap.

has(Srv, Pattern) ->
    lists:any(
        fun(C) -> re:run(C, Pattern, [caseless]) =/= nomatch end, mailio_fake_imap:commands(Srv)
    ).

baseline_test() ->
    with(fun(Srv, Acc) ->
        Snap = baseline(Acc),
        ?assertEqual([100, 101], lists:sort(maps:keys(maps:get(flags, Snap)))),
        ?assert(is_integer(maps:get(modseq, Snap))),
        ?assertEqual(2, maps:get(exists, Snap)),
        %% the baseline lists the flags once, read-only
        ?assert(has(Srv, <<"^EXAMINE ">>)),
        ?assertNot(has(Srv, <<"^SELECT ">>))
    end).

unchanged_uses_qresync_and_lists_nothing_test() ->
    with(fun(Srv, Acc) ->
        Snap = baseline(Acc),
        Before = length(mailio_fake_imap:commands(Srv)),
        {ok, R} = changes(Acc, Snap),
        ?assert(maps:get(unchanged, R)),
        ?assertEqual([], maps:get(added, R)),
        New = lists:nthtail(Before, mailio_fake_imap:commands(Srv)),
        ?assert(lists:any(fun(C) -> re:run(C, <<"EXAMINE .*QRESYNC \\(">>) =/= nomatch end, New)),
        %% no flag listing of the whole mailbox
        ?assertNot(lists:any(fun(C) -> re:run(C, <<"^FETCH 1:\\*">>) =/= nomatch end, New))
    end).

flag_change_test() ->
    with(fun(Srv, Acc) ->
        Snap = baseline(Acc),
        ok = mailio_fake_imap:set_flags(Srv, 101, [<<"\\Seen">>]),
        Before = length(mailio_fake_imap:commands(Srv)),
        {ok, R} = changes(Acc, Snap),
        ?assertNot(maps:get(unchanged, R)),
        ?assertMatch([#{uid := 101, unread := false}], maps:get(updated, R)),
        ?assertEqual([], maps:get(removed, R)),
        ?assertEqual([], maps:get(added, R)),
        New = lists:nthtail(Before, mailio_fake_imap:commands(Srv)),
        ?assertNot(lists:any(fun(C) -> re:run(C, <<"^FETCH 1:\\*">>) =/= nomatch end, New))
    end).

new_message_test() ->
    with(fun(Srv, Acc) ->
        Snap = baseline(Acc),
        ok = mailio_fake_imap:deliver(Srv, <<"Third message">>),
        {ok, R} = changes(Acc, Snap),
        ?assertEqual(1, maps:get(added_total, R)),
        ?assertMatch([#{uid := 102}], maps:get(added, R)),
        #{snapshot := New} = R,
        ?assertEqual(3, maps:get(exists, New)),
        ?assert(maps:is_key(102, maps:get(flags, New)))
    end).

expunge_test() ->
    with(fun(Srv, Acc) ->
        Snap = baseline(Acc),
        ok = mailio_fake_imap:expunge(Srv, 100),
        {ok, R} = changes(Acc, Snap),
        ?assertEqual([100], maps:get(removed, R)),
        #{snapshot := New} = R,
        ?assertEqual(1, maps:get(exists, New)),
        ?assertNot(maps:is_key(100, maps:get(flags, New)))
    end).

%% The next call from the new snapshot sees nothing: nothing is reported twice.
chain_test() ->
    with(fun(Srv, Acc) ->
        S0 = baseline(Acc),
        ok = mailio_fake_imap:set_flags(Srv, 100, [<<"\\Flagged">>]),
        {ok, #{snapshot := S1}} = changes(Acc, S0),
        {ok, R} = changes(Acc, S1),
        ?assert(maps:get(unchanged, R)),
        ok = mailio_fake_imap:expunge(Srv, 101),
        {ok, R2} = changes(Acc, S1),
        ?assertEqual([101], maps:get(removed, R2))
    end).

%% A checkpoint without a mod-sequence (a server that had no CONDSTORE when it
%% was taken) falls back to comparing every message's flags.
no_modseq_falls_back_test() ->
    with(fun(Srv, Acc) ->
        Snap = (baseline(Acc))#{modseq => undefined},
        ok = mailio_fake_imap:set_flags(Srv, 101, [<<"\\Seen">>]),
        Before = length(mailio_fake_imap:commands(Srv)),
        {ok, R} = changes(Acc, Snap),
        ?assertMatch([#{uid := 101}], maps:get(updated, R)),
        New = lists:nthtail(Before, mailio_fake_imap:commands(Srv)),
        ?assert(lists:any(fun(C) -> re:run(C, <<"^FETCH 1:\\*">>) =/= nomatch end, New))
    end).

%% A changed UIDVALIDITY means the checkpoint is useless.
uidvalidity_change_test() ->
    with(fun(_Srv, Acc) ->
        Snap = (baseline(Acc))#{uv => 999},
        ?assertEqual({error, checkpoint_expired}, changes(Acc, Snap))
    end).
