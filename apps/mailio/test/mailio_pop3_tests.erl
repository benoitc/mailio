%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mailio_pop3_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

msg(Subject, Body) ->
    <<"From: a@x\r\nTo: b@y\r\nSubject: ", Subject/binary, "\r\n\r\n", Body/binary>>.

msgs() ->
    [
        {<<"u1">>, msg(<<"one">>, <<"first body\r\n.starts with a dot\r\nlast\r\n">>)},
        {<<"u2">>, msg(<<"two">>, <<"second\r\n">>)},
        {<<"u2">>, msg(<<"two">>, <<"second\r\n">>)}
    ].

cfg(Srv) -> cfg(Srv, #{}).
cfg(Srv, Extra) ->
    maps:merge(
        #{
            host => <<"127.0.0.1">>,
            port => mailio_fake_pop3:port(Srv),
            tls => false,
            credentials => {password, <<"u">>, <<"p">>}
        },
        Extra
    ).

with(Opts, Fun) ->
    Srv = mailio_fake_pop3:start(Opts),
    try
        Fun(Srv)
    after
        mailio_fake_pop3:stop(Srv)
    end.

code({error, #{code := C}}) -> C.
detail({error, #{detail := D}}) -> D.

listing_and_identity_test() ->
    with(#{messages => msgs()}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        ?assertEqual([<<"UIDL">>, <<"TOP">>], mailio_pop3:capabilities(C)),
        ?assertMatch({ok, 3, _}, mailio_pop3:stat(C)),
        {ok, Sizes} = mailio_pop3:list(C),
        ?assertEqual([1, 2, 3], [N || {N, _} <- Sizes]),
        {ok, Ids} = mailio_pop3:uidl(C),
        ?assertEqual([{1, <<"u1">>}, {2, <<"u2">>}, {3, <<"u2">>}], Ids),
        %% a server that reuses a UIDL for identical copies: each copy keeps an identity
        ?assertEqual([{1, <<"u1">>}, {2, <<"u2">>}, {3, <<"u2#1">>}], mailio_pop3:unique_ids(Ids)),
        mailio_pop3:close(C)
    end).

top_and_retr_test() ->
    with(#{messages => msgs()}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        {ok, H} = mailio_pop3:top(C, 1, 0),
        ?assertMatch({_, _}, binary:match(H, <<"Subject: one">>)),
        ?assertEqual(nomatch, binary:match(H, <<"first body">>)),
        {ok, Raw} = mailio_pop3:retr(C, 1, 1000000),
        %% dot-unstuffed: the line that starts with a dot arrives as it was written
        ?assertMatch({_, _}, binary:match(Raw, <<"\r\n.starts with a dot\r\n">>)),
        ?assertEqual(nomatch, binary:match(Raw, <<"..starts">>)),
        mailio_pop3:close(C)
    end).

retr_limits_and_missing_test() ->
    with(#{messages => msgs()}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        ?assertEqual(pop3_too_large, code(mailio_pop3:retr(C, 1, 10))),
        ?assertEqual(pop3_no_such_message, code(mailio_pop3:retr(C, 99, 1000000))),
        mailio_pop3:close(C)
    end).

no_uidl_is_reported_test() ->
    with(#{messages => msgs(), uidl => false, caps => []}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        ?assertEqual(pop3_unsupported, code(mailio_pop3:uidl(C))),
        mailio_pop3:close(C)
    end).

no_top_falls_back_to_retr_for_small_messages_test() ->
    with(#{messages => msgs(), top => false, caps => [<<"UIDL">>]}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        ?assertEqual(pop3_unsupported, code(mailio_pop3:top(C, 1, 0))),
        {ok, H} = mailio_pop3:headers(C, 1, 80, #{}),
        ?assertMatch({_, _}, binary:match(H, <<"Subject: one">>)),
        ?assertEqual(nomatch, binary:match(H, <<"first body">>)),
        %% a message larger than the limit is refused rather than downloaded
        ?assertEqual(pop3_too_large, code(mailio_pop3:headers(C, 1, 5000000, #{max_retr => 1000}))),
        mailio_pop3:close(C)
    end).

never_deletes_test() ->
    with(#{messages => msgs()}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        _ = mailio_pop3:list(C),
        _ = mailio_pop3:uidl(C),
        _ = mailio_pop3:top(C, 1, 0),
        _ = mailio_pop3:retr(C, 1, 1000000),
        mailio_pop3:close(C),
        timer:sleep(100),
        Cmds = [string:uppercase(Cmd) || {_, Cmd} <- mailio_fake_pop3:commands(Srv)],
        ?assert(length(Cmds) > 5),
        ?assertEqual([], [X || X = "DELE" ++ _ <- Cmds]),
        ?assertEqual([], [X || X = "RSET" ++ _ <- Cmds])
    end).

lost_connection_is_retryable_test() ->
    with(#{messages => msgs(), drop_on_retr => true}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        E = mailio_pop3:retr(C, 1, 1000000),
        ?assertEqual(pop3_disconnected, code(E)),
        ?assert(mailio_error:is_retryable(E))
    end).

connect_refused_test() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    E = mailio_pop3:open(#{host => <<"127.0.0.1">>, port => Port, tls => false}),
    ?assertEqual(pop3_connect_failed, code(E)),
    ?assert(mailio_error:is_retryable(E)).

credential_provider_error_does_not_leak_test() ->
    with(#{messages => msgs()}, fun(Srv) ->
        F = fun() -> {error, {provider_failed, <<"secret material">>}} end,
        E = mailio_pop3:open(cfg(Srv, #{credentials => {token_fun, F}})),
        ?assertEqual(pop3_auth_failed, code(E)),
        ?assertEqual(#{}, detail(E))
    end).

authentication_test() ->
    with(#{messages => msgs(), auth => #{pass => <<"p">>}}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        mailio_pop3:close(C),
        ?assertEqual([{pass, "p"}, {user, "u"}], lists:sort(mailio_fake_pop3:auth_seen(Srv)))
    end),
    with(#{messages => msgs(), auth => #{pass => <<"right">>}}, fun(Srv) ->
        E = mailio_pop3:open(cfg(Srv, #{credentials => {password, <<"u">>, <<"wrong">>}})),
        ?assertEqual(pop3_auth_failed, code(E))
    end),
    with(#{messages => msgs()}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv, #{credentials => {oauth2, <<"u@x">>, <<"tok">>}})),
        [{xoauth2, B64}] = mailio_fake_pop3:auth_seen(Srv),
        ?assertEqual(
            <<"user=u@x", 1, "auth=Bearer tok", 1, 1>>, base64:decode(list_to_binary(B64))
        ),
        mailio_pop3:close(C)
    end),
    with(#{messages => msgs(), auth => reject_xoauth2}, fun(Srv) ->
        E = mailio_pop3:open(cfg(Srv, #{credentials => {oauth2, <<"u@x">>, <<"expired">>}})),
        ?assertEqual(pop3_auth_failed, code(E))
    end).

%%--------------------------------------------------------------------
%% TLS

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

tls_cfg(Srv, Extra) ->
    maps:merge(
        #{
            host => <<"localhost">>,
            port => mailio_fake_pop3:port(Srv),
            credentials => {password, <<"u">>, <<"p">>}
        },
        Extra
    ).

implicit_tls_test() ->
    {Server, Client} = certs(),
    CACerts = proplists:get_value(cacerts, Client),
    with(#{messages => msgs(), tls => implicit, tls_opts => Server}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(tls_cfg(Srv, #{tls => true, cacerts => CACerts})),
        ?assertMatch({ok, 3, _}, mailio_pop3:stat(C)),
        mailio_pop3:close(C),
        ?assertEqual(pop3_tls_failed, code(mailio_pop3:open(tls_cfg(Srv, #{tls => true})))),
        ?assertEqual(
            pop3_tls_failed,
            code(
                mailio_pop3:open(
                    tls_cfg(Srv, #{tls => true, cacerts => CACerts, host => <<"127.0.0.1">>})
                )
            )
        )
    end).

stls_test() ->
    {Server, Client} = certs(),
    CACerts = proplists:get_value(cacerts, Client),
    with(#{messages => msgs(), tls => starttls, tls_opts => Server}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(tls_cfg(Srv, #{tls => starttls, cacerts => CACerts})),
        ?assertMatch({ok, 3, _}, mailio_pop3:stat(C)),
        mailio_pop3:close(C),
        ?assertEqual(pop3_tls_failed, code(mailio_pop3:open(tls_cfg(Srv, #{tls => starttls}))))
    end),
    %% no STLS on offer: refuse, and never send the password in clear text
    with(#{messages => msgs()}, fun(Srv) ->
        E = mailio_pop3:open(cfg(Srv, #{tls => starttls})),
        ?assertEqual(pop3_tls_failed, code(E)),
        ?assertEqual([], mailio_fake_pop3:auth_seen(Srv))
    end).

%%====================================================================
%% Bounded replies
%%====================================================================

many_msgs(N) -> [{integer_to_binary(I), msg(<<"s">>, <<"b\r\n">>)} || I <- lists:seq(1, N)].

oversized_listing_is_refused_test() ->
    with(#{messages => many_msgs(400)}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv, #{max_list_bytes => 1000})),
        ?assertEqual(pop3_response_too_large, code(mailio_pop3:uidl(C))),
        %% the connection was closed, not left half read
        ?assertEqual(pop3_disconnected, code(mailio_pop3:stat(C)))
    end).

oversized_line_is_refused_while_read_test() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        gen_tcp:send(S, [<<"+OK ">>, binary:copy(<<"x">>, 1000), <<"\r\n">>]),
        gen_tcp:close(S)
    end),
    E = mailio_pop3:open(#{
        host => <<"127.0.0.1">>,
        port => Port,
        tls => false,
        max_line_bytes => 128
    }),
    ?assertEqual(pop3_response_too_large, code(E)),
    gen_tcp:close(L).

listing_under_the_limit_works_test() ->
    with(#{messages => many_msgs(400)}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv, #{max_list_bytes => 100000})),
        ?assertMatch({ok, [_ | _]}, mailio_pop3:uidl(C)),
        mailio_pop3:close(C)
    end).

oversized_top_is_refused_test() ->
    Big = msg(binary:copy(<<"long subject word ">>, 1), <<"b">>),
    Hdrs = iolist_to_binary([
        <<"X-H", (integer_to_binary(I))/binary, ": value\r\n">>
     || I <- lists:seq(1, 300)
    ]),
    BigMsg = <<Hdrs/binary, Big/binary>>,
    with(#{messages => [{<<"u">>, BigMsg}]}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv, #{max_top_bytes => 500})),
        ?assertEqual(pop3_response_too_large, code(mailio_pop3:top(C, 1, 1000))),
        ok
    end).

server_that_lies_about_size_cannot_overflow_retr_test() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {packet, line}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        gen_tcp:send(S, <<"+OK hi\r\n">>),
        serve_liar(S)
    end),
    {ok, C} = mailio_pop3:open(#{
        host => <<"127.0.0.1">>,
        port => Port,
        tls => false,
        credentials => {password, <<"u">>, <<"p">>}
    }),
    ?assertEqual(pop3_response_too_large, code(mailio_pop3:retr(C, 1, 100))),
    gen_tcp:close(L).

serve_liar(S) ->
    case gen_tcp:recv(S, 0, 3000) of
        {ok, <<"CAPA", _/binary>>} ->
            gen_tcp:send(S, <<"+OK\r\nUIDL\r\n.\r\n">>),
            serve_liar(S);
        {ok, <<"LIST 1", _/binary>>} ->
            gen_tcp:send(S, <<"+OK 1 10\r\n">>),
            serve_liar(S);
        {ok, <<"RETR", _/binary>>} ->
            gen_tcp:send(S, <<"+OK\r\n">>),
            Line = binary:copy(<<"x">>, 1000),
            [gen_tcp:send(S, [Line, <<"\r\n">>]) || _ <- lists:seq(1, 400)],
            ok;
        {ok, _} ->
            gen_tcp:send(S, <<"+OK\r\n">>),
            serve_liar(S);
        {error, _} ->
            ok
    end.

retr_returns_the_message_bytes_test() ->
    Msg = msg(<<"exact">>, <<"last line\r\n">>),
    with(#{messages => [{<<"u">>, Msg}]}, fun(Srv) ->
        {ok, C} = mailio_pop3:open(cfg(Srv)),
        {ok, Got} = mailio_pop3:retr(C, 1, 100000),
        %% including the line ending of the last line
        ?assertEqual(Msg, Got),
        {ok, Top} = mailio_pop3:top(C, 1, 0),
        ?assertMatch({_, _}, binary:match(Top, <<"Subject: exact\r\n">>)),
        mailio_pop3:close(C)
    end).

%% A tls setting that is not understood is an error before any socket is opened,
%% never plain text with a password.
an_unknown_tls_setting_is_refused_test() ->
    with(#{messages => msgs()}, fun(Srv) ->
        [
            ?assertEqual(pop3_tls_failed, code(mailio_pop3:open(cfg(Srv, #{tls => Bad}))))
         || Bad <- [none, implicit, maybe_, <<"starttls">>]
        ]
    end).
