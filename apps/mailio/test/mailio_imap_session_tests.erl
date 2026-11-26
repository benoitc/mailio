%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc What the IMAP adapter does on a connection several callers share, and
%%% what it removes. The server is a small scripted one that keeps a selected
%%% mailbox, as a real one does, so a command that lands on the wrong mailbox
%%% shows in what the mailboxes hold.
-module(mailio_imap_session_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% The scripted server
%%====================================================================

%% Mailboxes `<<"A">>' and `<<"B">>', UIDs 1 to 4 in each. `Caps' is what it
%% announces. The state is in an ets table the test reads afterwards.
start(Caps) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Tab = ets:new(srv, [public, set]),
    ets:insert(Tab, [
        {{msgs, <<"A">>}, [1, 2, 3, 4]},
        {{msgs, <<"B">>}, [1, 2, 3, 4]},
        {{deleted, <<"A">>}, []},
        {{deleted, <<"B">>}, []},
        {{flagged, <<"A">>}, []},
        {{flagged, <<"B">>}, []},
        {log, []},
        {selected, none}
    ]),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        ok = gen_tcp:send(S, <<"* OK ready\r\n">>),
        loop(S, Tab, Caps, <<>>)
    end),
    {Port, Tab, L}.

loop(S, Tab, Caps, Buf) ->
    case gen_tcp:recv(S, 0, 4000) of
        {ok, Data} ->
            Rest = lines(S, Tab, Caps, <<Buf/binary, Data/binary>>),
            loop(S, Tab, Caps, Rest);
        {error, _} ->
            ok
    end.

lines(S, Tab, Caps, Buf) ->
    case binary:split(Buf, <<"\r\n">>) of
        [Line, Rest] ->
            command(S, Tab, Caps, Line),
            lines(S, Tab, Caps, Rest);
        [_] ->
            Buf
    end.

command(S, Tab, Caps, Line) ->
    [Tag, Cmd | _] = binary:split(Line, <<" ">>, [global]),
    Verb = string:uppercase(Cmd),
    Args =
        case binary:split(Line, <<" ">>, [global]) of
            [_, _ | A] -> A;
            _ -> []
        end,
    ets:update_element(Tab, log, {2, ets:lookup_element(Tab, log, 2) ++ [Line]}),
    case Verb of
        <<"CAPABILITY">> ->
            send(S, [<<"* CAPABILITY IMAP4rev1 ">>, Caps, <<"\r\n">>]),
            ok_(S, Tag);
        <<"LOGIN">> ->
            ok_(S, Tag);
        <<"LOGOUT">> ->
            ok_(S, Tag);
        Sel when Sel =:= <<"SELECT">>; Sel =:= <<"EXAMINE">> ->
            [Box0 | _] = Args,
            Box = string:trim(Box0, both, "\""),
            %% a slow server gives the other callers time to select theirs
            timer:sleep(3),
            ets:insert(Tab, {selected, Box}),
            Msgs = ets:lookup_element(Tab, {msgs, Box}, 2),
            send(S, [<<"* ">>, integer_to_binary(length(Msgs)), <<" EXISTS\r\n">>]),
            send(S, <<"* OK [UIDVALIDITY 1] v\r\n">>),
            send(S, <<"* OK [UIDNEXT 5] n\r\n">>),
            ok_(S, Tag);
        <<"EXPUNGE">> ->
            Box = ets:lookup_element(Tab, selected, 2),
            Del = ets:lookup_element(Tab, {deleted, Box}, 2),
            remove(Tab, Box, Del),
            ok_(S, Tag);
        <<"UID">> ->
            uid(S, Tab, Tag, Args);
        _ ->
            send(S, [Tag, <<" BAD unknown\r\n">>])
    end.

uid(S, Tab, Tag, [Sub, SetBin | Rest]) ->
    Box = ets:lookup_element(Tab, selected, 2),
    Set =
        case string:uppercase(Sub) of
            <<"SEARCH">> -> [];
            _ -> parse_set(SetBin)
        end,
    case string:uppercase(Sub) of
        <<"FETCH">> ->
            case ets:lookup_element(Tab, {fetch, mode}, 2, normal) of
                normal ->
                    [fetch_body(S, Box, U) || U <- Set];
                other_uid ->
                    fetch_body(S, <<"X">>, 9);
                no_uid ->
                    Body = <<"nouid">>,
                    send(S, [
                        <<"* 1 FETCH (BODY[] {">>,
                        integer_to_binary(byte_size(Body)),
                        <<"}\r\n">>,
                        Body,
                        <<")\r\n">>
                    ])
            end,
            ok_(S, Tag);
        <<"STORE">> ->
            Flags = iolist_to_binary(lists:join(<<" ">>, Rest)),
            case binary:match(Flags, <<"Deleted">>) of
                nomatch ->
                    Fl = ets:lookup_element(Tab, {flagged, Box}, 2),
                    ets:insert(Tab, {{flagged, Box}, lists:usort(Fl ++ Set)});
                _ ->
                    Del = ets:lookup_element(Tab, {deleted, Box}, 2),
                    ets:insert(Tab, {{deleted, Box}, lists:usort(Del ++ Set)})
            end,
            ok_(S, Tag);
        <<"SEARCH">> ->
            Del = ets:lookup_element(Tab, {deleted, Box}, 2),
            send(S, [
                <<"* SEARCH">>,
                [[<<" ">>, integer_to_binary(U)] || U <- Del],
                <<"\r\n">>
            ]),
            ok_(S, Tag);
        <<"EXPUNGE">> ->
            Del = ets:lookup_element(Tab, {deleted, Box}, 2),
            remove(Tab, Box, [U || U <- Del, lists:member(U, Set)]),
            ok_(S, Tag);
        <<"COPY">> ->
            ok_(S, Tag);
        _ ->
            send(S, [Tag, <<" BAD unknown\r\n">>])
    end.

fetch_body(S, Box, Uid) ->
    Body = <<"box:", Box/binary>>,
    send(S, [
        <<"* ">>,
        integer_to_binary(Uid),
        <<" FETCH (UID ">>,
        integer_to_binary(Uid),
        <<" BODY[] {">>,
        integer_to_binary(byte_size(Body)),
        <<"}\r\n">>,
        Body,
        <<")\r\n">>
    ]).

remove(Tab, Box, Gone) ->
    ets:insert(Tab, {{msgs, Box}, ets:lookup_element(Tab, {msgs, Box}, 2) -- Gone}),
    ets:insert(Tab, {{deleted, Box}, ets:lookup_element(Tab, {deleted, Box}, 2) -- Gone}).

parse_set(Bin) ->
    lists:append([
        case binary:split(P, <<":">>) of
            [A, B] -> lists:seq(binary_to_integer(A), binary_to_integer(B));
            [A] -> [binary_to_integer(A)]
        end
     || P <- binary:split(Bin, <<",">>, [global])
    ]).

send(S, Data) -> gen_tcp:send(S, Data).
ok_(S, Tag) -> send(S, [Tag, <<" OK done\r\n">>]).

connect(Port) ->
    {ok, Conn} = mailio_imap:connect(#{
        host => <<"127.0.0.1">>,
        port => Port,
        tls => false,
        username => <<"u">>,
        password => <<"p">>
    }),
    Conn.

msgs(Tab, Box) -> ets:lookup_element(Tab, {msgs, Box}, 2).
deleted(Tab, Box) -> ets:lookup_element(Tab, {deleted, Box}, 2).
flagged(Tab, Box) -> ets:lookup_element(Tab, {flagged, Box}, 2).
log(Tab) -> ets:lookup_element(Tab, log, 2).

logged(Tab, Pattern) ->
    lists:any(fun(L) -> re:run(L, Pattern, [caseless]) =/= nomatch end, log(Tab)).

%%====================================================================
%% Callers that share a connection
%%====================================================================

%% Each caller reads the message of its own mailbox, however many others are
%% selecting theirs at the same time.
concurrent_fetches_each_see_their_own_mailbox_test_() ->
    {timeout, 60, fun() ->
        {Port, _Tab, L} = start(<<"UIDPLUS">>),
        Conn = connect(Port),
        Self = self(),
        Boxes = [<<"A">>, <<"B">>],
        Pids = [
            spawn_link(fun() ->
                Box = lists:nth(1 + (N rem 2), Boxes),
                Sink = fun(Bytes) ->
                    Self ! {body, N, iolist_to_binary(Bytes)},
                    ok
                end,
                Res = mailio_imap:fetch_message(Conn, Box, 1, Sink),
                Self ! {done, N, Box, Res}
            end)
         || N <- lists:seq(1, 24)
        ],
        Results = [
            receive
                {done, N, Box, R} -> {N, Box, R}
            after 20000 -> error(timeout)
            end
         || _ <- Pids
        ],
        Bodies = collect_bodies(24, #{}),
        [
            begin
                ?assertMatch({ok, _}, R),
                ?assertEqual(<<"box:", Box/binary>>, maps:get(N, Bodies))
            end
         || {N, Box, R} <- Results
        ],
        gen_tcp:close(L)
    end}.

collect_bodies(0, Acc) ->
    Acc;
collect_bodies(N, Acc) ->
    receive
        {body, I, B} -> collect_bodies(N - 1, Acc#{I => B})
    after 5000 -> Acc
    end.

%% A change goes to the mailbox it was asked for.
concurrent_changes_go_to_their_own_mailbox_test_() ->
    {timeout, 60, fun() ->
        {Port, Tab, L} = start(<<"UIDPLUS">>),
        Conn = connect(Port),
        Self = self(),
        [
            spawn_link(fun() ->
                {Box, Uid} =
                    case N rem 2 of
                        0 -> {<<"A">>, 1};
                        1 -> {<<"B">>, 2}
                    end,
                Self ! {done, mailio_imap:set_keywords(Conn, Box, Uid, [<<"$flagged">>], [])}
            end)
         || N <- lists:seq(1, 20)
        ],
        [
            receive
                {done, R} -> ?assertEqual(ok, R)
            after 20000 -> error(timeout)
            end
         || _ <- lists:seq(1, 20)
        ],
        ?assertEqual([1], flagged(Tab, <<"A">>)),
        ?assertEqual([2], flagged(Tab, <<"B">>)),
        gen_tcp:close(L)
    end}.

%% A caller that dies in the middle of its turn gives it up.
a_caller_that_dies_gives_up_its_turn_test() ->
    {Port, _Tab, L} = start(<<"UIDPLUS">>),
    Conn = connect(Port),
    Lock = maps:get(lock, Conn),
    Holder = spawn(fun() ->
        mailio_imap_lock:with_session(Lock, 5000, fun() -> timer:sleep(infinity) end)
    end),
    timer:sleep(50),
    exit(Holder, kill),
    ?assertMatch({ok, _}, mailio_imap:fetch_message(Conn, <<"A">>, 1, fun(_) -> ok end)),
    gen_tcp:close(L).

%%====================================================================
%% Expunge
%%====================================================================

%% With UIDPLUS only the named message goes; another one flagged \Deleted stays.
expunge_removes_only_the_named_messages_test() ->
    {Port, Tab, L} = start(<<"UIDPLUS">>),
    Conn = connect(Port),
    ets:insert(Tab, {{deleted, <<"A">>}, [3]}),
    ?assertEqual(ok, mailio_imap:expunge(Conn, <<"A">>, [1])),
    ?assertEqual([2, 3, 4], msgs(Tab, <<"A">>)),
    ?assertEqual([3], deleted(Tab, <<"A">>)),
    ?assert(logged(Tab, <<"UID EXPUNGE 1">>)),
    ?assertNot(logged(Tab, <<"^[^ ]+ EXPUNGE">>)),
    gen_tcp:close(L).

%% Without UIDPLUS the only expunge is a mailbox-wide one, which can take messages
%% nobody named, so it is refused.
expunge_without_uidplus_leaves_flagged_messages_alone_test() ->
    {Port, Tab, L} = start(<<>>),
    Conn = connect(Port),
    ets:insert(Tab, {{deleted, <<"A">>}, [3]}),
    ?assertMatch({error, _}, mailio_imap:expunge(Conn, <<"A">>, [1])),
    ?assertEqual([1, 2, 3, 4], msgs(Tab, <<"A">>)),
    ?assertEqual([3], deleted(Tab, <<"A">>)),
    gen_tcp:close(L).

expunge_without_uidplus_is_refused_before_anything_is_changed_test() ->
    {Port, Tab, L} = start(<<>>),
    Conn = connect(Port),
    ?assertMatch({error, _}, mailio_imap:expunge(Conn, <<"A">>, [1, 2])),
    ?assertEqual([1, 2, 3, 4], msgs(Tab, <<"A">>)),
    ?assertEqual([], deleted(Tab, <<"A">>)),
    ?assertNot(logged(Tab, <<" STORE ">>)),
    gen_tcp:close(L).

%% The UIDs go on the wire once, as given: [1, 3] is `1,3', and no other message
%% is marked or removed.
expunge_sends_the_uids_it_was_given_test() ->
    {Port, Tab, L} = start(<<"UIDPLUS">>),
    Conn = connect(Port),
    ets:insert(Tab, {{msgs, <<"A">>}, [1, 2, 3, 4, 44]}),
    ?assertEqual(ok, mailio_imap:expunge(Conn, <<"A">>, [1, 3])),
    ?assert(logged(Tab, <<" UID STORE 1,3 \\+FLAGS">>)),
    ?assert(logged(Tab, <<" UID EXPUNGE 1,3$">>)),
    ?assertEqual([2, 4, 44], msgs(Tab, <<"A">>)),
    ?assertEqual([], deleted(Tab, <<"A">>)),
    gen_tcp:close(L).

%% A move by copy ends with the same expunge, and the same rule.
move_by_copy_does_not_expunge_other_messages_test() ->
    {Port, Tab, L} = start(<<"UIDPLUS">>),
    Conn = connect(Port),
    ets:insert(Tab, {{deleted, <<"A">>}, [3]}),
    ?assertMatch({ok, _}, mailio_imap:move(Conn, <<"A">>, 1, <<"B">>)),
    ?assertEqual([2, 3, 4], msgs(Tab, <<"A">>)),
    gen_tcp:close(L).

move_without_move_or_uidplus_is_refused_before_copying_test() ->
    {Port, Tab, L} = start(<<>>),
    Conn = connect(Port),
    ?assertMatch({error, _}, mailio_imap:move(Conn, <<"A">>, 1, <<"B">>)),
    ?assertEqual([1, 2, 3, 4], msgs(Tab, <<"A">>)),
    ?assertNot(logged(Tab, <<" UID COPY ">>)),
    ?assertNot(logged(Tab, <<" STORE ">>)),
    gen_tcp:close(L).

%%====================================================================
%% The message that comes back
%%====================================================================

%% The body of another UID, or one with no UID, is not the message asked for.
a_body_for_another_uid_is_not_the_message_test() ->
    {Port, Tab, L} = start(<<"UIDPLUS">>),
    Conn = connect(Port),
    ets:insert(Tab, {{fetch, mode}, other_uid}),
    ?assertMatch({error, _}, mailio_imap:fetch_message(Conn, <<"A">>, 1, fun(_) -> ok end)),
    ets:insert(Tab, {{fetch, mode}, no_uid}),
    ?assertMatch({error, _}, mailio_imap:fetch_message(Conn, <<"A">>, 1, fun(_) -> ok end)),
    gen_tcp:close(L).
