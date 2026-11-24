%%% A scriptable POP3 server for tests. Options:
%%%   messages: [{Uidl, Raw}] in message-number order
%%%   caps:     [binary()] advertised by CAPA, e.g. [<<"UIDL">>, <<"TOP">>, <<"STLS">>]
%%%   uidl:     true | false   (whether the UIDL command works)
%%%   top:      true | false   (whether the TOP command works)
%%%   tls:      none | implicit | starttls     tls_opts: server ssl options
%%%   auth:     #{user, pass} for USER/PASS, or xoauth2 | any
%%%   drop_on_retr: close the connection in the middle of RETR
%%% Every command received is recorded, so a test can assert that DELE was
%%% never sent.
-module(mailio_fake_pop3).

-export([start/1, stop/1, port/1, commands/1, auth_seen/1]).

start(Opts0) ->
    Opts = maps:merge(
        #{
            messages => [],
            caps => [<<"UIDL">>, <<"TOP">>],
            uidl => true,
            top => true,
            tls => none,
            auth => any,
            drop_on_retr => false
        },
        Opts0
    ),
    Tab = ets:new(fake_pop3, [public, bag]),
    LOpts = [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}],
    {ok, L} =
        case maps:get(tls, Opts) of
            implicit -> ssl:listen(0, LOpts ++ maps:get(tls_opts, Opts));
            _ -> gen_tcp:listen(0, LOpts)
        end,
    {ok, {_, Port}} =
        case maps:get(tls, Opts) of
            implicit -> ssl:sockname(L);
            _ -> inet:sockname(L)
        end,
    Pid = spawn_link(fun() -> accept_loop(L, Opts, Tab) end),
    #{listen => L, port => Port, pid => Pid, tab => Tab, opts => Opts}.

stop(#{listen := L, pid := P, opts := Opts}) ->
    unlink(P),
    exit(P, kill),
    case maps:get(tls, Opts) of
        implicit -> ssl:close(L);
        _ -> gen_tcp:close(L)
    end,
    ok.

port(#{port := P}) -> P.
commands(#{tab := T}) -> [C || {cmd, C} <- lists:sort(ets:tab2list(T))].
auth_seen(#{tab := T}) -> [A || {auth, A} <- ets:tab2list(T)].

accept_loop(L, Opts, Tab) ->
    Res =
        case maps:get(tls, Opts) of
            implicit ->
                case ssl:transport_accept(L) of
                    {ok, S} ->
                        case ssl:handshake(S, 5000) of
                            {ok, SS} ->
                                ok = ssl:setopts(SS, [{packet, line}]),
                                {ok, ssl, SS};
                            _ ->
                                error
                        end;
                    _ ->
                        stop
                end;
            _ ->
                case gen_tcp:accept(L) of
                    {ok, S} ->
                        ok = inet:setopts(S, [{packet, line}]),
                        {ok, gen_tcp, S};
                    _ ->
                        stop
                end
        end,
    case Res of
        {ok, Mod, Sock} ->
            Pid = spawn(fun() ->
                receive
                    go -> ok
                end,
                send(Mod, Sock, "+OK fake ready\r\n"),
                loop(Mod, Sock, Opts, Tab)
            end),
            _ = Mod:controlling_process(Sock, Pid),
            Pid ! go,
            accept_loop(L, Opts, Tab);
        error ->
            accept_loop(L, Opts, Tab);
        stop ->
            ok
    end.

send(Mod, Sock, D) -> Mod:send(Sock, D).

loop(Mod, Sock, Opts, Tab) ->
    case Mod:recv(Sock, 0, 10000) of
        {ok, Line} ->
            Cmd = string:trim(binary_to_list(Line)),
            ets:insert(Tab, {cmd, {erlang:unique_integer([monotonic]), Cmd}}),
            handle(Mod, Sock, Opts, Tab, Cmd, string:uppercase(Cmd));
        _ ->
            ok
    end.

handle(Mod, Sock, #{messages := Msgs} = Opts, Tab, Cmd, U) ->
    case U of
        "CAPA" ->
            send(Mod, Sock, "+OK\r\n"),
            Caps =
                maps:get(caps, Opts) ++
                    case {maps:get(tls, Opts), Mod} of
                        {starttls, gen_tcp} -> [<<"STLS">>];
                        _ -> []
                    end,
            [send(Mod, Sock, [C, "\r\n"]) || C <- Caps],
            send(Mod, Sock, ".\r\n"),
            loop(Mod, Sock, Opts, Tab);
        "STLS" ->
            send(Mod, Sock, "+OK begin TLS\r\n"),
            ok = inet:setopts(Sock, [{packet, raw}]),
            case ssl:handshake(Sock, maps:get(tls_opts, Opts), 5000) of
                {ok, SS} ->
                    ok = ssl:setopts(SS, [{packet, line}]),
                    loop(ssl, SS, Opts, Tab);
                _ ->
                    ok
            end;
        "USER " ++ _ ->
            ets:insert(Tab, {auth, {user, lists:nthtail(5, Cmd)}}),
            send(Mod, Sock, "+OK\r\n"),
            loop(Mod, Sock, Opts, Tab);
        "PASS " ++ _ ->
            Pass = lists:nthtail(5, Cmd),
            ets:insert(Tab, {auth, {pass, Pass}}),
            PassBin = list_to_binary(Pass),
            case maps:get(auth, Opts) of
                #{pass := P} when P =/= PassBin -> send(Mod, Sock, "-ERR bad password\r\n");
                _ -> send(Mod, Sock, "+OK logged in\r\n")
            end,
            loop(Mod, Sock, Opts, Tab);
        "AUTH XOAUTH2 " ++ _ ->
            ets:insert(Tab, {auth, {xoauth2, lists:nthtail(13, Cmd)}}),
            case maps:get(auth, Opts) of
                reject_xoauth2 ->
                    send(Mod, Sock, "+ eyJzdGF0dXMiOiI0MDEifQ==\r\n"),
                    {ok, _} = Mod:recv(Sock, 0, 5000),
                    send(Mod, Sock, "-ERR denied\r\n");
                _ ->
                    send(Mod, Sock, "+OK\r\n")
            end,
            loop(Mod, Sock, Opts, Tab);
        "STAT" ->
            Total = lists:sum([byte_size(R) || {_, R} <- Msgs]),
            send(Mod, Sock, io_lib:format("+OK ~p ~p\r\n", [length(Msgs), Total])),
            loop(Mod, Sock, Opts, Tab);
        "LIST" ->
            send(Mod, Sock, "+OK\r\n"),
            [
                send(Mod, Sock, io_lib:format("~p ~p\r\n", [N, byte_size(R)]))
             || {N, {_, R}} <- number(Msgs)
            ],
            send(Mod, Sock, ".\r\n"),
            loop(Mod, Sock, Opts, Tab);
        "LIST " ++ N ->
            case lookup(Msgs, N) of
                {ok, R} -> send(Mod, Sock, io_lib:format("+OK ~s ~p\r\n", [N, byte_size(R)]));
                error -> send(Mod, Sock, "-ERR no such message\r\n")
            end,
            loop(Mod, Sock, Opts, Tab);
        "UIDL" ->
            case maps:get(uidl, Opts) of
                true ->
                    send(Mod, Sock, "+OK\r\n"),
                    [
                        send(Mod, Sock, io_lib:format("~p ~s\r\n", [N, Id]))
                     || {N, {Id, _}} <- number(Msgs)
                    ],
                    send(Mod, Sock, ".\r\n");
                false ->
                    send(Mod, Sock, "-ERR not implemented\r\n")
            end,
            loop(Mod, Sock, Opts, Tab);
        "UIDL " ++ _ ->
            case maps:get(uidl, Opts) of
                true -> send(Mod, Sock, "+OK 1 x\r\n");
                false -> send(Mod, Sock, "-ERR not implemented\r\n")
            end,
            loop(Mod, Sock, Opts, Tab);
        "TOP " ++ Rest ->
            case maps:get(top, Opts) of
                false ->
                    send(Mod, Sock, "-ERR command not implemented\r\n");
                true ->
                    [N, _Lines] = string:tokens(Rest, " "),
                    case lookup(Msgs, N) of
                        {ok, R} ->
                            [H | _] = binary:split(R, <<"\r\n\r\n">>),
                            send(Mod, Sock, "+OK\r\n"),
                            send(Mod, Sock, stuff(<<H/binary, "\r\n">>)),
                            send(Mod, Sock, ".\r\n");
                        error ->
                            send(Mod, Sock, "-ERR no such message\r\n")
                    end
            end,
            loop(Mod, Sock, Opts, Tab);
        "RETR " ++ N ->
            case lookup(Msgs, N) of
                {ok, R} ->
                    send(Mod, Sock, "+OK\r\n"),
                    case maps:get(drop_on_retr, Opts) of
                        true ->
                            send(Mod, Sock, binary:part(R, 0, byte_size(R) div 2)),
                            Mod:close(Sock);
                        false ->
                            send(Mod, Sock, stuff(R)),
                            send(Mod, Sock, ".\r\n"),
                            loop(Mod, Sock, Opts, Tab)
                    end;
                error ->
                    send(Mod, Sock, "-ERR no such message\r\n"),
                    loop(Mod, Sock, Opts, Tab)
            end;
        "QUIT" ->
            send(Mod, Sock, "+OK bye\r\n"),
            Mod:close(Sock);
        _ ->
            send(Mod, Sock, "-ERR unknown\r\n"),
            loop(Mod, Sock, Opts, Tab)
    end.

number(Msgs) -> lists:zip(lists:seq(1, length(Msgs)), Msgs).

lookup(Msgs, N) ->
    try
        {_, R} = lists:nth(list_to_integer(N), Msgs),
        {ok, R}
    catch
        _:_ -> error
    end.

%% Dot-stuff and make sure the body ends with CRLF.
stuff(Bin) ->
    Crlf =
        case binary:longest_common_suffix([Bin, <<"\r\n">>]) of
            2 -> Bin;
            _ -> <<Bin/binary, "\r\n">>
        end,
    re:replace(Crlf, <<"(?m)^\\.">>, <<"..">>, [global, {return, binary}]).
