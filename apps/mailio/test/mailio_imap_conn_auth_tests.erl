%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_imap_conn_auth_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

cfg(Srv, Extra) ->
    maps:merge(#{host => <<"127.0.0.1">>, port => mailio_fake_imap:port(Srv), tls => false}, Extra).

with(Opts, Fun) ->
    Srv = mailio_fake_imap:start(Opts#{auth_log => self()}),
    try
        Fun(Srv)
    after
        mailio_fake_imap:stop(Srv)
    end.

auth_event() ->
    receive
        {fake_imap_auth, E} -> E
    after 2000 -> timeout
    end.

run_noop(Pid) ->
    mailio_imap_conn:run(Pid, fun(Tag) -> {[Tag, <<" NOOP\r\n">>], undefined} end, 3000).

password_login_test() ->
    with(#{}, fun(Srv) ->
        {ok, Pid} = mailio_imap_conn:start_link(
            cfg(Srv, #{credentials => {password, <<"u">>, <<"p">>}})
        ),
        ?assertMatch({login, _}, auth_event()),
        ?assertMatch({ok, _, {ok, _, _}}, run_noop(Pid)),
        mailio_imap_conn:close(Pid)
    end).

legacy_username_password_test() ->
    with(#{}, fun(Srv) ->
        {ok, Pid} = mailio_imap_conn:start_link(
            cfg(Srv, #{username => <<"u">>, password => <<"p">>})
        ),
        ?assertMatch({login, _}, auth_event()),
        ?assertMatch({ok, _, {ok, _, _}}, run_noop(Pid)),
        mailio_imap_conn:close(Pid)
    end).

xoauth2_test() ->
    with(#{}, fun(Srv) ->
        {ok, Pid} = mailio_imap_conn:start_link(
            cfg(Srv, #{credentials => {oauth2, <<"u@x">>, <<"tok">>}})
        ),
        {authenticate, <<"XOAUTH2">>, Token} = auth_event(),
        ?assertEqual(<<"user=u@x", 1, "auth=Bearer tok", 1, 1>>, base64:decode(Token)),
        ?assertMatch({ok, _, {ok, _, _}}, run_noop(Pid)),
        mailio_imap_conn:close(Pid)
    end).

token_fun_is_resolved_test() ->
    with(#{}, fun(Srv) ->
        F = fun() -> {ok, {oauth2, <<"u">>, <<"fresh">>}} end,
        {ok, Pid} = mailio_imap_conn:start_link(cfg(Srv, #{credentials => {token_fun, F}})),
        ?assertMatch({authenticate, _, _}, auth_event()),
        mailio_imap_conn:close(Pid)
    end).

refused_password_is_not_retried_test() ->
    with(#{auth => reject}, fun(Srv) ->
        {ok, Pid} = mailio_imap_conn:start_link(
            cfg(Srv, #{credentials => {password, <<"u">>, <<"bad">>}})
        ),
        ?assertMatch({login, _}, auth_event()),
        ?assertEqual({error, authentication_failed}, run_noop(Pid)),
        %% no second attempt: a reconnect loop would lock the account out
        ?assertEqual(
            timeout,
            (fun() ->
                receive
                    {fake_imap_auth, _} = E -> E
                after 500 -> timeout
                end
            end)()
        ),
        ?assertEqual({error, authentication_failed}, run_noop(Pid)),
        mailio_imap_conn:close(Pid)
    end).

refused_token_is_not_retried_test() ->
    with(#{auth => reject_xoauth2}, fun(Srv) ->
        {ok, Pid} = mailio_imap_conn:start_link(
            cfg(Srv, #{credentials => {oauth2, <<"u">>, <<"expired">>}})
        ),
        ?assertMatch({authenticate, _, _}, auth_event()),
        ?assertEqual({error, authentication_failed}, run_noop(Pid)),
        ?assertEqual(
            timeout,
            (fun() ->
                receive
                    {fake_imap_auth, _} = E -> E
                after 500 -> timeout
                end
            end)()
        ),
        mailio_imap_conn:close(Pid)
    end).

%%--------------------------------------------------------------------
%% TLS: the default verifies the certificate chain and the host name

certs() ->
    SAN = #'Extension'{extnID = ?'id-ce-subjectAltName', extnValue = [{dNSName, "localhost"}]},
    Key = {key, {namedCurve, secp256r1}},
    Dig = {digest, sha256},
    #{server_config := Server, client_config := Client} =
        public_key:pkix_test_data(#{
            server_chain => #{root => [Key, Dig], peer => [Key, Dig, {extensions, [SAN]}]},
            client_chain => #{root => [Key, Dig], peer => [Key, Dig]}
        }),
    {Server, Client}.

%% A server that completes the TLS handshake, then says hello and accepts a LOGIN.
tls_server(ServerOpts, Parent) ->
    {ok, L} = ssl:listen(0, [
        binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}} | ServerOpts
    ]),
    {ok, {_, Port}} = ssl:sockname(L),
    Pid = spawn_link(fun() ->
        case ssl:transport_accept(L, 5000) of
            {ok, S} ->
                case ssl:handshake(S, 5000) of
                    {ok, SS} ->
                        Parent ! {tls_server, handshake_ok},
                        ssl:send(SS, <<"* OK [CAPABILITY IMAP4rev1] ready\r\n">>),
                        ssl:setopts(SS, [{packet, line}]),
                        case ssl:recv(SS, 0, 3000) of
                            {ok, Line} ->
                                [Tag | _] = binary:split(Line, <<" ">>),
                                Parent ! {tls_server, {got, Line}},
                                ssl:send(SS, [Tag, <<" OK done\r\n">>]);
                            _ ->
                                ok
                        end,
                        timer:sleep(500);
                    _ ->
                        Parent ! {tls_server, handshake_failed}
                end;
            _ ->
                ok
        end
    end),
    {Port, Pid, L}.

expect(Msg) ->
    receive
        {tls_server, Msg} = M -> M;
        {tls_server, Other} -> {unexpected, Other}
    after 3000 -> timeout
    end.

tls_verification_test() ->
    {Server, Client} = certs(),
    CACerts = proplists:get_value(cacerts, Client),
    Base = #{host => <<"localhost">>, tls => true, credentials => {password, <<"u">>, <<"p">>}},
    %% trusted chain, matching host name: connects and logs in
    {P1, _, L1} = tls_server(Server, self()),
    {ok, C1} = mailio_imap_conn:start_link(Base#{port => P1, cacerts => CACerts}),
    ?assertEqual({tls_server, handshake_ok}, expect(handshake_ok)),
    ?assertMatch(
        {tls_server, {got, _}},
        (fun() ->
            receive
                {tls_server, {got, _}} = M -> M
            after 3000 -> timeout
            end
        end)()
    ),
    mailio_imap_conn:close(C1),
    ssl:close(L1),
    %% the default trust store does not know the test CA: no connection is made
    {P2, _, L2} = tls_server(Server, self()),
    {ok, C2} = mailio_imap_conn:start_link(Base#{port => P2}),
    ?assertEqual({tls_server, handshake_failed}, expect(handshake_failed)),
    mailio_imap_conn:close(C2),
    ssl:close(L2),
    %% the host name must match the certificate
    {P3, _, L3} = tls_server(Server, self()),
    {ok, C3} = mailio_imap_conn:start_link(Base#{
        port => P3, cacerts => CACerts, host => <<"127.0.0.1">>
    }),
    ?assertEqual({tls_server, handshake_failed}, expect(handshake_failed)),
    mailio_imap_conn:close(C3),
    ssl:close(L3).

%%--------------------------------------------------------------------
%% STARTTLS: upgrade before any credential is sent

%% Greets in clear text, then answers STARTTLS (or refuses it), and reports
%% every command it sees together with whether the connection was encrypted.
starttls_server(ServerOpts, Offer, Parent) ->
    {ok, L} = gen_tcp:listen(0, [
        binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}, {packet, line}
    ]),
    {ok, Port} = inet:port(L),
    Pid = spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L, 5000),
        gen_tcp:send(S, <<"* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n">>),
        {ok, Line} = gen_tcp:recv(S, 0, 3000),
        [Tag, Cmd] = binary:split(string:trim(Line), <<" ">>),
        Parent ! {imap_cmd, plain, Cmd},
        case {Cmd, Offer} of
            {<<"STARTTLS">>, true} ->
                gen_tcp:send(S, [Tag, <<" OK begin TLS\r\n">>]),
                ok = inet:setopts(S, [{packet, raw}]),
                case ssl:handshake(S, ServerOpts, 5000) of
                    {ok, SS} ->
                        ok = ssl:setopts(SS, [{packet, line}]),
                        {ok, L2} = ssl:recv(SS, 0, 3000),
                        [Tag2, Cmd2] = binary:split(string:trim(L2), <<" ">>),
                        Parent ! {imap_cmd, tls, hd(binary:split(Cmd2, <<" ">>))},
                        ssl:send(SS, [Tag2, <<" OK done\r\n">>]),
                        timer:sleep(500);
                    _ ->
                        Parent ! handshake_failed
                end;
            _ ->
                gen_tcp:send(S, [Tag, <<" NO STARTTLS unavailable\r\n">>]),
                %% a client that carried on would now send LOGIN in clear text
                case gen_tcp:recv(S, 0, 1500) of
                    {ok, More} ->
                        Parent !
                            {imap_cmd, plain,
                                hd(binary:split(string:trim(More), <<" ">>, [global]))};
                    _ ->
                        ok
                end
        end
    end),
    {Port, Pid, L}.

starttls_verified_test() ->
    {Server, Client} = certs(),
    CACerts = proplists:get_value(cacerts, Client),
    {Port, _, L} = starttls_server(Server, true, self()),
    {ok, C} = mailio_imap_conn:start_link(#{
        host => <<"localhost">>,
        port => Port,
        tls => starttls,
        cacerts => CACerts,
        credentials => {password, <<"u">>, <<"p">>}
    }),
    ?assertEqual(
        {imap_cmd, plain, <<"STARTTLS">>},
        (fun() ->
            receive
                {imap_cmd, plain, _} = M -> M
            after 3000 -> timeout
            end
        end)()
    ),
    %% the credential only ever travels over the encrypted connection
    ?assertMatch(
        {imap_cmd, tls, _},
        (fun() ->
            receive
                {imap_cmd, tls, _} = M -> M
            after 3000 -> timeout
            end
        end)()
    ),
    mailio_imap_conn:close(C),
    gen_tcp:close(L).

starttls_untrusted_certificate_test() ->
    {Server, _} = certs(),
    {Port, _, L} = starttls_server(Server, true, self()),
    {ok, C} = mailio_imap_conn:start_link(#{
        host => <<"localhost">>,
        port => Port,
        tls => starttls,
        credentials => {password, <<"u">>, <<"p">>}
    }),
    ?assertEqual(
        {imap_cmd, plain, <<"STARTTLS">>},
        (fun() ->
            receive
                {imap_cmd, plain, _} = M -> M
            after 3000 -> timeout
            end
        end)()
    ),
    ?assertEqual(
        handshake_failed,
        (fun() ->
            receive
                handshake_failed -> handshake_failed
            after 3000 -> timeout
            end
        end)()
    ),
    ?assertEqual({error, tls_failed}, run_noop(C)),
    mailio_imap_conn:close(C),
    gen_tcp:close(L).

starttls_refused_is_never_downgraded_test() ->
    {Port, _, L} = starttls_server([], false, self()),
    {ok, C} = mailio_imap_conn:start_link(#{
        host => <<"localhost">>,
        port => Port,
        tls => starttls,
        credentials => {password, <<"u">>, <<"p">>}
    }),
    ?assertEqual(
        {imap_cmd, plain, <<"STARTTLS">>},
        (fun() ->
            receive
                {imap_cmd, plain, _} = M -> M
            after 3000 -> timeout
            end
        end)()
    ),
    ?assertEqual({error, tls_failed}, run_noop(C)),
    %% no LOGIN was sent in clear text after the refusal
    ?assertEqual(
        timeout,
        (fun() ->
            receive
                {imap_cmd, plain, _} = M -> M
            after 2000 -> timeout
            end
        end)()
    ),
    mailio_imap_conn:close(C),
    gen_tcp:close(L).

io_hook_counts_bytes_test() ->
    with(#{}, fun(Srv) ->
        Self = self(),
        Hook = fun(Dir, N) -> Self ! {io, Dir, N} end,
        {ok, Pid} = mailio_imap_conn:start_link(
            cfg(Srv, #{credentials => {password, <<"u">>, <<"p">>}, io_hook => Hook})
        ),
        {ok, _, _} = run_noop(Pid),
        mailio_imap_conn:close(Pid),
        Events = (fun Collect(Acc) ->
            receive
                {io, D, N} -> Collect([{D, N} | Acc])
            after 200 -> Acc
            end
        end)(
            []
        ),
        ?assert(
            lists:any(
                fun
                    ({sent, N}) -> N > 0;
                    (_) -> false
                end,
                Events
            )
        ),
        ?assert(
            lists:any(
                fun
                    ({received, N}) -> N > 0;
                    (_) -> false
                end,
                Events
            )
        )
    end).
