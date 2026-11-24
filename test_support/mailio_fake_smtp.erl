%%% A scriptable SMTP server for tests. Options:
%%%   mode: ok | drop_after_data | reject_data | defer_data | reject_mail_from
%%%         | defer_mail_from | auth_fail
%%%   tls:  none | implicit | starttls | starttls_not_offered
%%%   tls_opts: ssl server options (certificate and key) for the TLS modes
%%%   auth: plain | login | none (what AUTH mechanism the EHLO advertises)
%%% Recipients whose local part starts with "bad" get 550.
-module(mailio_fake_smtp).

-export([start/1, stop/1, port/1, messages/1, data_count/1, auth_seen/1]).

start(Opts0) ->
    Opts = maps:merge(#{mode => ok, tls => none, auth => plain}, Opts0),
    Tab = ets:new(fake_smtp, [public, bag]),
    LOpts = [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}],
    {ok, L} = case maps:get(tls, Opts) of
                  implicit -> ssl:listen(0, LOpts ++ maps:get(tls_opts, Opts));
                  _ -> gen_tcp:listen(0, LOpts)
              end,
    {ok, {_, Port}} = case maps:get(tls, Opts) of
                          implicit -> ssl:sockname(L);
                          _ -> inet:sockname(L)
                      end,
    Pid = spawn_link(fun() -> accept_loop(L, Opts, Tab) end),
    #{listen => L, port => Port, pid => Pid, tab => Tab, opts => Opts}.

stop(#{listen := L, pid := P, opts := Opts}) ->
    unlink(P), exit(P, kill),
    case maps:get(tls, Opts) of implicit -> ssl:close(L); _ -> gen_tcp:close(L) end,
    ok.

port(#{port := P}) -> P.
messages(#{tab := T}) -> [M || {message, M} <- ets:tab2list(T)].
data_count(S) -> length(messages(S)).
auth_seen(#{tab := T}) -> [A || {auth, A} <- ets:tab2list(T)].

accept_loop(L, Opts, Tab) ->
    Tls = maps:get(tls, Opts),
    Res = case Tls of
              implicit ->
                  case ssl:transport_accept(L) of
                      {ok, S} ->
                          case ssl:handshake(S, 5000) of
                              {ok, SS} -> ok = ssl:setopts(SS, [{packet, line}]), {ok, ssl, SS};
                              _ -> error
                          end;
                      _ -> stop
                  end;
              _ ->
                  case gen_tcp:accept(L) of
                      {ok, S} -> ok = inet:setopts(S, [{packet, line}]), {ok, gen_tcp, S};
                      _ -> stop
                  end
          end,
    case Res of
        {ok, Mod, Sock} ->
            Pid = spawn(fun() -> receive go -> ok end, session(Mod, Sock, Opts, Tab) end),
            _ = Mod:controlling_process(Sock, Pid),
            Pid ! go,
            accept_loop(L, Opts, Tab);
        error -> accept_loop(L, Opts, Tab);
        stop -> ok
    end.

session(Mod, Sock, Opts, Tab) ->
    send(Mod, Sock, "220 fake ESMTP\r\n"),
    loop(Mod, Sock, Opts, Tab, #{}).

send(Mod, Sock, D) -> Mod:send(Sock, D).

ehlo_reply(#{tls := Tls, auth := Auth}, Mod) ->
    Lines = ["250-fake\r\n"]
        ++ [case {Tls, Mod} of
                {starttls, gen_tcp} -> "250-STARTTLS\r\n";
                _ -> ""
            end]
        ++ [case Auth of
                plain -> "250 AUTH PLAIN\r\n";
                login -> "250 AUTH LOGIN\r\n";
                none -> "250 OK\r\n"
            end],
    Lines.

loop(Mod, Sock, Opts, Tab, St) ->
    case Mod:recv(Sock, 0, 10000) of
        {ok, Line} ->
            U = string:uppercase(binary_to_list(Line)),
            Mode = maps:get(mode, Opts),
            case U of
                "EHLO" ++ _ ->
                    send(Mod, Sock, ehlo_reply(Opts, Mod)),
                    loop(Mod, Sock, Opts, Tab, St);
                "STARTTLS" ++ _ ->
                    send(Mod, Sock, "220 go ahead\r\n"),
                    ok = inet:setopts(Sock, [{packet, raw}]),
                    case ssl:handshake(Sock, maps:get(tls_opts, Opts), 5000) of
                        {ok, SS} ->
                            ok = ssl:setopts(SS, [{packet, line}]),
                            loop(ssl, SS, Opts, Tab, St);
                        _ -> ok
                    end;
                "AUTH PLAIN " ++ _ ->
                    ets:insert(Tab, {auth, {plain, string:trim(lists:nthtail(11, binary_to_list(Line)))}}),
                    auth_reply(Mod, Sock, Opts, Tab, St);
                "AUTH XOAUTH2 " ++ _ ->
                    ets:insert(Tab, {auth, {xoauth2, string:trim(lists:nthtail(13, binary_to_list(Line)))}}),
                    auth_reply(Mod, Sock, Opts, Tab, St);
                "AUTH LOGIN" ++ _ ->
                    send(Mod, Sock, "334 VXNlcm5hbWU6\r\n"),
                    {ok, UserL} = Mod:recv(Sock, 0, 5000),
                    send(Mod, Sock, "334 UGFzc3dvcmQ6\r\n"),
                    {ok, PassL} = Mod:recv(Sock, 0, 5000),
                    ets:insert(Tab, {auth, {login, string:trim(UserL), string:trim(PassL)}}),
                    auth_reply(Mod, Sock, Opts, Tab, St);
                "MAIL" ++ _ ->
                    case Mode of
                        reject_mail_from -> send(Mod, Sock, "550 sender refused\r\n");
                        defer_mail_from -> send(Mod, Sock, "451 try later\r\n");
                        _ -> send(Mod, Sock, "250 ok\r\n")
                    end,
                    loop(Mod, Sock, Opts, Tab, St);
                "RCPT TO:<BAD" ++ _ ->
                    send(Mod, Sock, "550 no such user\r\n"),
                    loop(Mod, Sock, Opts, Tab, St);
                "RCPT" ++ _ ->
                    send(Mod, Sock, "250 ok\r\n"),
                    loop(Mod, Sock, Opts, Tab, St);
                "DATA" ++ _ ->
                    send(Mod, Sock, "354 go\r\n"),
                    Data = read_data(Mod, Sock, []),
                    ets:insert(Tab, {message, Data}),
                    case Mode of
                        drop_after_data -> Mod:close(Sock);
                        reject_data -> send(Mod, Sock, "554 message refused\r\n"), loop(Mod, Sock, Opts, Tab, St);
                        defer_data -> send(Mod, Sock, "451 try again\r\n"), loop(Mod, Sock, Opts, Tab, St);
                        _ -> send(Mod, Sock, "250 2.0.0 queued as FAKE1\r\n"), loop(Mod, Sock, Opts, Tab, St)
                    end;
                "QUIT" ++ _ ->
                    send(Mod, Sock, "221 bye\r\n"), Mod:close(Sock);
                _ ->
                    send(Mod, Sock, "250 ok\r\n"), loop(Mod, Sock, Opts, Tab, St)
            end;
        _ -> ok
    end.

auth_reply(Mod, Sock, #{mode := auth_fail} = Opts, Tab, St) ->
    send(Mod, Sock, "535 5.7.8 bad credentials\r\n"), loop(Mod, Sock, Opts, Tab, St);
auth_reply(Mod, Sock, Opts, Tab, St) ->
    send(Mod, Sock, "235 ok\r\n"), loop(Mod, Sock, Opts, Tab, St).

read_data(Mod, Sock, Acc) ->
    case Mod:recv(Sock, 0, 10000) of
        {ok, <<".\r\n">>} -> iolist_to_binary(lists:reverse(Acc));
        {ok, L} -> read_data(Mod, Sock, [L | Acc]);
        _ -> iolist_to_binary(lists:reverse(Acc))
    end.
