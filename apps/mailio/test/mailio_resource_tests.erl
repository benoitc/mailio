%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% Sockets must not outlive a failed or finished call, and a credential
%%% provider must not be able to hang or spin the caller or a connection.
-module(mailio_resource_tests).
-include_lib("eunit/include/eunit.hrl").
-behaviour(mailio_credentials).
-export([fetch/3, invalidate/3]).
-include_lib("public_key/include/public_key.hrl").

%%====================================================================
%% Helpers
%%====================================================================

%% Ports connected to this process: what a call leaves behind when it leaks.
my_ports() ->
    Self = self(),
    [P || P <- erlang:ports(), erlang:port_info(P, connected) =:= {connected, Self}].

%% A one-connection raw server. Script(Socket) runs after the greeting.
serve(Greeting, Script) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {packet, line}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        gen_tcp:send(S, Greeting),
        Script(S),
        timer:sleep(300),
        gen_tcp:close(S),
        gen_tcp:close(L)
    end),
    Port.

%% Read lines and answer them until the script says stop.
loop(S, Reply) ->
    case gen_tcp:recv(S, 0, 2000) of
        {ok, Line} ->
            case Reply(Line) of
                stop ->
                    ok;
                Out ->
                    gen_tcp:send(S, Out),
                    loop(S, Reply)
            end;
        {error, _} ->
            ok
    end.

%%====================================================================
%% Sockets
%%====================================================================

%% The server upgrades to TLS with a certificate the client does not trust, so
%% the handshake fails after the plain connection was made.
server_tls() ->
    SAN = #'Extension'{extnID = ?'id-ce-subjectAltName', extnValue = [{dNSName, "localhost"}]},
    Key = {key, {namedCurve, secp256r1}},
    Dig = {digest, sha256},
    #{server_config := Server} =
        public_key:pkix_test_data(#{
            server_chain => #{root => [Key, Dig], peer => [Key, Dig, {extensions, [SAN]}]},
            client_chain => #{root => [Key, Dig], peer => [Key, Dig]}
        }),
    Server.

pop3_starttls_failure_leaves_no_socket_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    Srv = mailio_fake_pop3:start(#{tls => starttls, tls_opts => server_tls(), caps => [<<"STLS">>]}),
    try
        Before = my_ports(),
        R = mailio_pop3:open(#{
            host => <<"localhost">>, port => mailio_fake_pop3:port(Srv), tls => starttls
        }),
        ?assertMatch({error, _}, R),
        ?assertEqual([], my_ports() -- Before)
    after
        mailio_fake_pop3:stop(Srv)
    end.

pop3_without_stls_leaves_no_socket_test() ->
    Srv = mailio_fake_pop3:start(#{caps => [<<"UIDL">>]}),
    try
        Before = my_ports(),
        R = mailio_pop3:open(#{
            host => <<"127.0.0.1">>, port => mailio_fake_pop3:port(Srv), tls => starttls
        }),
        ?assertMatch({error, _}, R),
        ?assertEqual([], my_ports() -- Before)
    after
        mailio_fake_pop3:stop(Srv)
    end.

pop3_refused_login_leaves_no_socket_test() ->
    Port = serve(<<"+OK hi\r\n">>, fun(S) ->
        loop(S, fun
            (<<"CAPA", _/binary>>) -> <<"+OK\r\nUIDL\r\n.\r\n">>;
            (<<"USER", _/binary>>) -> <<"-ERR no\r\n">>;
            (_) -> <<"+OK\r\n">>
        end)
    end),
    Before = my_ports(),
    R = mailio_pop3:open(#{
        host => <<"127.0.0.1">>,
        port => Port,
        tls => false,
        credentials => {password, <<"u">>, <<"p">>}
    }),
    ?assertMatch({error, _}, R),
    ?assertEqual([], my_ports() -- Before).

pop3_bad_greeting_leaves_no_socket_test() ->
    Port = serve(<<"-ERR go away\r\n">>, fun(S) -> loop(S, fun(_) -> stop end) end),
    Before = my_ports(),
    ?assertMatch(
        {error, _}, mailio_pop3:open(#{host => <<"127.0.0.1">>, port => Port, tls => false})
    ),
    ?assertEqual([], my_ports() -- Before).

pop3_close_releases_the_socket_test() ->
    Port = serve(<<"+OK hi\r\n">>, fun(S) -> loop(S, fun(_) -> <<"+OK\r\n.\r\n">> end) end),
    Before = my_ports(),
    {ok, C} = mailio_pop3:open(#{host => <<"127.0.0.1">>, port => Port, tls => false}),
    ?assertNotEqual([], my_ports() -- Before),
    ok = mailio_pop3:close(C),
    ?assertEqual([], my_ports() -- Before).

smtp_starttls_failure_leaves_no_socket_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    Srv = mailio_fake_smtp:start(#{tls => starttls, tls_opts => server_tls()}),
    try
        Before = my_ports(),
        R = mailio_smtp:submit(
            #{host => <<"localhost">>, port => mailio_fake_smtp:port(Srv), tls => starttls},
            <<"a@x">>,
            [<<"b@y">>],
            <<"Subject: s\r\n\r\nx\r\n">>
        ),
        ?assertMatch({error, _}, R),
        ?assertEqual([], my_ports() -- Before)
    after
        mailio_fake_smtp:stop(Srv)
    end.

smtp_without_starttls_leaves_no_socket_test() ->
    Srv = mailio_fake_smtp:start(#{tls => starttls_not_offered}),
    try
        Before = my_ports(),
        R = mailio_smtp:submit(
            #{host => <<"127.0.0.1">>, port => mailio_fake_smtp:port(Srv), tls => starttls},
            <<"a@x">>,
            [<<"b@y">>],
            <<"Subject: s\r\n\r\nx\r\n">>
        ),
        ?assertMatch({error, _}, R),
        ?assertEqual([], my_ports() -- Before)
    after
        mailio_fake_smtp:stop(Srv)
    end.

smtp_refused_recipient_leaves_no_socket_test() ->
    Port = serve(<<"220 hi\r\n">>, fun(S) ->
        loop(S, fun
            (<<"RCPT", _/binary>>) -> <<"550 no\r\n">>;
            (<<"QUIT", _/binary>>) -> <<"221 bye\r\n">>;
            (_) -> <<"250 ok\r\n">>
        end)
    end),
    Before = my_ports(),
    R = mailio_smtp:submit(
        #{host => <<"127.0.0.1">>, port => Port, tls => false},
        <<"a@x">>,
        [<<"b@y">>],
        <<"Subject: s\r\n\r\nx\r\n">>
    ),
    ?assertMatch({error, _}, R),
    ?assertEqual([], my_ports() -- Before).

smtp_success_leaves_no_socket_test() ->
    Port = serve(<<"220 hi\r\n">>, fun(S) ->
        loop(S, fun
            (<<"DATA", _/binary>>) -> data_phase(S);
            (<<"QUIT", _/binary>>) -> <<"221 bye\r\n">>;
            (_) -> <<"250 ok\r\n">>
        end)
    end),
    Before = my_ports(),
    R = mailio_smtp:submit(
        #{host => <<"127.0.0.1">>, port => Port, tls => false},
        <<"a@x">>,
        [<<"b@y">>],
        <<"Subject: s\r\n\r\nx\r\n">>
    ),
    ?assertMatch({ok, _}, R),
    ?assertEqual([], my_ports() -- Before).

data_phase(S) ->
    gen_tcp:send(S, <<"354 go\r\n">>),
    skip_body(S),
    <<"250 queued\r\n">>.

skip_body(S) ->
    case gen_tcp:recv(S, 0, 2000) of
        {ok, <<".\r\n">>} -> ok;
        {ok, _} -> skip_body(S);
        {error, _} -> ok
    end.

%%====================================================================
%% Credentials
%%====================================================================

plain_credentials_pass_through_test() ->
    ?assertEqual(
        {ok, {password, <<"u">>, <<"p">>}}, mailio_credentials:resolve({password, <<"u">>, <<"p">>})
    ),
    ?assertEqual(
        {ok, {oauth2, <<"u">>, <<"t">>}}, mailio_credentials:resolve({oauth2, <<"u">>, <<"t">>})
    ).

token_fun_chain_is_followed_test() ->
    Inner = fun() -> {ok, {password, <<"u">>, <<"p">>}} end,
    Outer = fun() -> {ok, {token_fun, Inner}} end,
    ?assertEqual(
        {ok, {password, <<"u">>, <<"p">>}}, mailio_credentials:resolve({token_fun, Outer})
    ).

cyclic_token_fun_is_refused_test() ->
    Loop = fun L() -> {ok, {token_fun, L}} end,
    ?assertEqual({error, credentials_loop}, mailio_credentials:resolve({token_fun, Loop})).

hanging_token_fun_times_out_test() ->
    Hang = fun() -> timer:sleep(infinity) end,
    {T, R} = timer:tc(fun() -> mailio_credentials:resolve({token_fun, Hang}, #{timeout => 200}) end),
    ?assertEqual({error, credentials_timeout}, R),
    ?assert(T < 2000000).

crashing_token_fun_is_an_error_test() ->
    Boom = fun() -> error(boom) end,
    ?assertMatch({error, {credentials_failed, _}}, mailio_credentials:resolve({token_fun, Boom})),
    Err = fun() -> {error, expired} end,
    ?assertEqual(
        {error, {credentials_failed, expired}}, mailio_credentials:resolve({token_fun, Err})
    ).

%% A provider that loops or fails must not stop a connection from answering,
%% and must not take its linked owner down.
imap_survives_a_bad_provider_test_() ->
    [
        {Name, fun() -> imap_with_provider(Fun) end}
     || {Name, Fun} <- [
            {"cyclic", fun L() -> {ok, {token_fun, L}} end},
            {"raising", fun() -> error(boom) end},
            {"failing", fun() -> {error, expired} end}
        ]
    ].

imap_with_provider(Fun) ->
    {ok, _} = application:ensure_all_started(ssl),
    Srv = mailio_fake_imap:start(),
    try
        {ok, C} = mailio_imap_conn:start_link(#{
            host => <<"127.0.0.1">>,
            port => mailio_fake_imap:port(Srv),
            tls => false,
            credentials => {token_fun, Fun},
            credentials_timeout => 2000
        }),
        ?assertEqual(
            {error, authentication_failed},
            mailio_imap_conn:run(C, fun(T) -> {[T, <<" NOOP\r\n">>], undefined} end, 5000)
        ),
        ?assert(is_process_alive(C)),
        mailio_imap_conn:close(C)
    after
        mailio_fake_imap:stop(Srv)
    end.

%%====================================================================
%% One worker, one deadline, for the whole chain
%%====================================================================

%% a provider module for the tests that keeps what it is asked in its arguments
fetch(<<"acct">>, imap, Cred) ->
    {ok, Cred};
fetch(<<"slow">>, imap, Parent) ->
    %% the provider starts a helper of its own, linked, and waits for it
    Helper = spawn_link(fun() ->
        Parent ! {helper, self()},
        timer:sleep(infinity)
    end),
    _ = Helper,
    timer:sleep(infinity).
invalidate(_, _, _) -> ok.

a_token_fun_may_return_a_provider_reference_test() ->
    Cred = {password, <<"u">>, <<"p">>},
    Fun = fun() -> {ok, {provider, {?MODULE, Cred}, <<"acct">>, imap}} end,
    ?assertEqual({ok, Cred}, mailio_credentials:resolve({token_fun, Fun})),
    ?assertEqual(
        {ok, Cred},
        mailio_credentials:fetch({?MODULE, {token_fun, fun() -> {ok, Cred} end}}, <<"acct">>, imap)
    ).

a_named_credential_is_looked_up_test() ->
    Cred = {oauth2, <<"u">>, <<"tok">>},
    ok = mailio_credentials:register_ref(my_account, Cred),
    try
        ?assertEqual({ok, Cred}, mailio_credentials:resolve({ref, my_account})),
        ?assertMatch(
            {error, {credentials_failed, unknown_reference}},
            mailio_credentials:resolve({ref, nobody})
        )
    after
        mailio_credentials:forget_ref(my_account)
    end.

%% the time limit is for the chain, not for each link of it
the_deadline_covers_the_whole_chain_test() ->
    Slow = fun(Next) ->
        fun() ->
            timer:sleep(120),
            {ok, Next}
        end
    end,
    Chain = {token_fun, Slow({token_fun, Slow({token_fun, Slow({password, <<"u">>, <<"p">>})})})},
    ?assertEqual(
        {error, credentials_timeout}, mailio_credentials:resolve(Chain, #{timeout => 250})
    ),
    ?assertMatch({ok, _}, mailio_credentials:resolve(Chain, #{timeout => 2000})).

%% a provider that is slow, and the helper it started, are gone when the time is up
a_timed_out_provider_leaves_nothing_running_test() ->
    Self = self(),
    ?assertEqual(
        {error, credentials_timeout},
        mailio_credentials:resolve({provider, {?MODULE, Self}, <<"slow">>, imap}, #{timeout => 150})
    ),
    Helper =
        receive
            {helper, H} -> H
        after 1000 -> error(no_helper)
        end,
    timer:sleep(50),
    ?assertNot(is_process_alive(Helper)).
