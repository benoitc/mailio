%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% Hostile or broken IMAP servers must not make the client buffer without bound.
-module(mailio_imap_limits_tests).
-include_lib("eunit/include/eunit.hrl").

%% A raw one-shot server: greeting, then Script(Sock, Tag) after the first command.
serve(Script) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Pid = spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        ok = gen_tcp:send(S, <<"* OK ready\r\n">>),
        loop(S, Script),
        gen_tcp:close(S)
    end),
    {Port, Pid, L}.

loop(S, Script) ->
    case gen_tcp:recv(S, 0, 1500) of
        {ok, Cmd} ->
            [Tag | _] = binary:split(Cmd, <<" ">>),
            Script(S, Tag),
            loop(S, Script);
        {error, _} ->
            ok
    end.

connect(Port, Limits) ->
    {ok, C} = mailio_imap_conn:start_link(
        maps:merge(
            #{
                host => <<"127.0.0.1">>,
                port => Port,
                tls => false,
                credentials => {password, <<"u">>, <<"p">>}
            },
            Limits
        )
    ),
    C.

noop(C) ->
    mailio_imap_conn:run(C, fun(Tag) -> {[Tag, <<" NOOP\r\n">>], undefined} end, 5000).

huge_literal_announced_test() ->
    {Port, _, L} = serve(fun(S, _Tag) ->
        gen_tcp:send(S, <<"* 1 FETCH (BODY[] {4000000000}\r\n">>)
    end),
    C = connect(Port, #{}),
    ?assertEqual({error, response_too_large}, noop(C)),
    ?assertEqual({error, response_too_large}, noop(C)),
    gen_tcp:close(L).

endless_line_test() ->
    {Port, _, L} = serve(fun(S, _Tag) ->
        Chunk = binary:copy(<<"x">>, 8192),
        [gen_tcp:send(S, Chunk) || _ <- lists:seq(1, 64)]
    end),
    C = connect(Port, #{max_line => 4096}),
    ?assertEqual({error, response_too_large}, noop(C)),
    {buffer_ok, true} = {buffer_ok, buffer_small(C)},
    gen_tcp:close(L).

buffer_small(C) ->
    {memory, M} = process_info(C, memory),
    M < 2 * 1024 * 1024.

response_over_total_limit_test() ->
    {Port, _, L} = serve(fun(S, Tag) ->
        Lit = binary:copy(<<"a">>, 400),
        gen_tcp:send(S, [
            <<"* 1 FETCH (BODY[] {400}\r\n">>,
            Lit,
            <<" BODY[1] {400}\r\n">>,
            Lit,
            <<")\r\n">>,
            Tag,
            <<" OK done\r\n">>
        ])
    end),
    C = connect(Port, #{max_literal => 500, max_response => 600}),
    ?assertEqual({error, response_too_large}, noop(C)),
    gen_tcp:close(L).

legal_large_literal_still_works_test() ->
    {Port, _, L} = serve(fun(S, Tag) ->
        Lit = binary:copy(<<"a">>, 400),
        gen_tcp:send(S, [
            <<"* 1 FETCH (BODY[] {400}\r\n">>,
            Lit,
            <<")\r\n">>,
            Tag,
            <<" OK done\r\n">>
        ])
    end),
    C = connect(Port, #{max_literal => 500, max_response => 2000}),
    ?assertMatch({ok, [_ | _], {ok, _, _}}, noop(C)),
    mailio_imap_conn:close(C),
    gen_tcp:close(L).

oversized_unsolicited_response_is_terminal_test() ->
    Parent = self(),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Server = spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        ok = gen_tcp:send(S, <<"* PREAUTH ready\r\n">>),
        receive
            send_oversized ->
                ok = gen_tcp:send(S, binary:copy(<<"x">>, 8192)),
                Parent ! oversized_sent
        end,
        timer:sleep(500),
        gen_tcp:close(S)
    end),
    C = connect(Port, #{max_line => 4096}),
    ok = wait_state(C, ready, 100),
    Server ! send_oversized,
    receive
        oversized_sent -> ok
    after 1000 -> error(server_timeout)
    end,
    ok = wait_state(C, response_too_large, 100),
    ?assertEqual({error, response_too_large}, noop(C)),
    gen_tcp:close(L).

wait_state(_Pid, _Expected, 0) ->
    error(state_timeout);
wait_state(Pid, Expected, Left) ->
    case sys:get_state(Pid) of
        {Expected, _} ->
            ok;
        _ ->
            timer:sleep(10),
            wait_state(Pid, Expected, Left - 1)
    end.

%% Many small untagged lines add up: one command may not collect without end.
many_untagged_lines_are_capped_test() ->
    {Port, _, L} = serve(fun(S, Tag) ->
        [gen_tcp:send(S, <<"* 1 EXISTS\r\n">>) || _ <- lists:seq(1, 3000)],
        gen_tcp:send(S, [Tag, <<" OK done\r\n">>])
    end),
    C = connect(Port, #{max_untagged => 1000}),
    ?assertEqual({error, response_too_large}, noop(C)),
    gen_tcp:close(L).

untagged_bytes_are_capped_test() ->
    {Port, _, L} = serve(fun(S, Tag) ->
        Line = [<<"* OK ">>, binary:copy(<<"x">>, 500), <<"\r\n">>],
        [gen_tcp:send(S, Line) || _ <- lists:seq(1, 100)],
        gen_tcp:send(S, [Tag, <<" OK done\r\n">>])
    end),
    C = connect(Port, #{max_untagged_bytes => 10000}),
    ?assertEqual({error, response_too_large}, noop(C)),
    gen_tcp:close(L).

untagged_under_the_caps_still_works_test() ->
    {Port, _, L} = serve(fun(S, Tag) ->
        [gen_tcp:send(S, <<"* 1 EXISTS\r\n">>) || _ <- lists:seq(1, 200)],
        gen_tcp:send(S, [Tag, <<" OK done\r\n">>])
    end),
    C = connect(Port, #{max_untagged => 1000, max_untagged_bytes => 100000}),
    ?assertMatch({ok, [_ | _], {ok, _, _}}, noop(C)),
    mailio_imap_conn:close(C),
    gen_tcp:close(L).

%% One response that arrives in many pieces is put together and answered.
a_response_in_small_pieces_is_framed_test() ->
    {Port, _, L} = serve(fun(S, Tag) ->
        Resp = [<<"* 5 EXISTS\r\n">>, Tag, <<" OK done\r\n">>],
        [
            begin
                gen_tcp:send(S, <<B>>),
                timer:sleep(1)
            end
         || B <- binary_to_list(iolist_to_binary(Resp))
        ]
    end),
    C = connect(Port, #{}),
    ?assertMatch({ok, [{exists, 5}], {ok, _, _}}, noop(C)),
    mailio_imap_conn:close(C),
    gen_tcp:close(L).

%% After a terminal failure the connection must not keep what the command had
%% collected.
a_failed_connection_releases_what_it_collected_test() ->
    {Port, _, L} = serve(fun(S, Tag) ->
        Line = [<<"* OK ">>, binary:copy(<<"x">>, 1000), <<"\r\n">>],
        [gen_tcp:send(S, Line) || _ <- lists:seq(1, 4000)],
        gen_tcp:send(S, [Tag, <<" OK done\r\n">>])
    end),
    C = connect(Port, #{max_untagged_bytes => 2000000}),
    ?assertEqual({error, response_too_large}, noop(C)),
    erlang:garbage_collect(C),
    %% the large binaries the process still points at, and its own heap
    {binary, Bins} = process_info(C, binary),
    Held = lists:sum([Size || {_Id, Size, _Refs} <- Bins]),
    {memory, M} = process_info(C, memory),
    ?assert(Held + M < 500000),
    gen_tcp:close(L).

%% An IDLE stop in progress is answered when the connection fails terminally.
an_idle_stop_is_answered_when_the_connection_fails_test() ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}, {packet, line}, {reuseaddr, true}]),
    {ok, Port} = inet:port(LSock),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(LSock),
        gen_tcp:send(S, <<"* OK ready\r\n">>),
        idle_script(S)
    end),
    C = connect(Port, #{max_line => 500}),
    {ok, _, _} = mailio_imap_conn:run(
        C, fun(T) -> {mailio_imap_proto:examine(T, <<"INBOX">>), undefined} end, 3000
    ),
    ok = mailio_imap_conn:idle_start(C, self()),
    ?assertEqual({error, response_too_large}, mailio_imap_conn:idle_stop(C)),
    gen_tcp:close(LSock).

idle_script(S) ->
    case gen_tcp:recv(S, 0, 5000) of
        {ok, <<"DONE\r\n">>} ->
            %% a line that never ends, longer than the limit
            gen_tcp:send(S, binary:copy(<<"y">>, 2000)),
            timer:sleep(500);
        {ok, Line} ->
            [Tag, Cmd | _] = binary:split(binary:replace(Line, <<"\r\n">>, <<>>), <<" ">>, [global]),
            case string:uppercase(Cmd) of
                <<"LOGIN">> -> gen_tcp:send(S, [Tag, <<" OK in\r\n">>]);
                <<"EXAMINE">> -> gen_tcp:send(S, [<<"* 0 EXISTS\r\n">>, Tag, <<" OK done\r\n">>]);
                <<"IDLE">> -> gen_tcp:send(S, <<"+ idling\r\n">>);
                _ -> ok
            end,
            idle_script(S);
        {error, _} ->
            ok
    end.

%% A server that does not greet is dropped, socket and all.
an_unexpected_greeting_closes_the_socket_test() ->
    Test = self(),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {packet, line}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        gen_tcp:send(S, <<"* BYE go away\r\n">>),
        %% the client must close its end soon
        Test ! {closed, gen_tcp:recv(S, 0, 3000)}
    end),
    C = connect(Port, #{}),
    receive
        {closed, R} -> ?assertEqual({error, closed}, R)
    after 5000 -> ?assert(false)
    end,
    ?assert(is_process_alive(C)),
    mailio_imap_conn:close(C),
    gen_tcp:close(L).

%% After a disconnect, while the connection waits to reconnect, it does not
%% keep what the interrupted command had collected.
a_disconnect_releases_what_was_collected_test() ->
    {Port, _, L} = serve(fun(S, _Tag) ->
        Line = [<<"* OK ">>, binary:copy(<<"x">>, 1000), <<"\r\n">>],
        [gen_tcp:send(S, Line) || _ <- lists:seq(1, 2000)],
        %% no tagged answer: the connection drops
        gen_tcp:close(S)
    end),
    C = connect(Port, #{}),
    ?assertMatch({error, _}, noop(C)),
    erlang:garbage_collect(C),
    {binary, Bins} = process_info(C, binary),
    Held = lists:sum([Size || {_Id, Size, _Refs} <- Bins]),
    {memory, M} = process_info(C, memory),
    ?assert(Held + M < 500000),
    gen_tcp:close(L).
