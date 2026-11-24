-module(mailio_smtp_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(MSG, <<"From: a@x\r\nTo: b@y\r\nSubject: s\r\n\r\nhello\r\n.dot line\r\nbye\r\n">>).

cfg(Srv) -> cfg(Srv, #{}).
cfg(Srv, Extra) ->
    maps:merge(
        #{
            host => <<"127.0.0.1">>,
            port => mailio_fake_smtp:port(Srv),
            tls => false,
            ehlo_name => <<"test.local">>
        },
        Extra
    ).

with(Opts, Fun) ->
    Srv = mailio_fake_smtp:start(Opts),
    try
        Fun(Srv)
    after
        mailio_fake_smtp:stop(Srv)
    end.

code({error, #{code := C}}) -> C.
detail({error, #{detail := D}}) -> D.
retryable({error, #{retryable := R}}) -> R.

submission_test() ->
    with(#{}, fun(Srv) ->
        {ok, R} = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"b@y">>, <<"c@y">>], ?MSG),
        ?assertEqual([<<"b@y">>, <<"c@y">>], maps:get(accepted, R)),
        ?assertEqual([], maps:get(rejected, R)),
        ?assertEqual(250, maps:get(code, R)),
        %% the line starting with a dot is stuffed on the wire
        [Wire] = mailio_fake_smtp:messages(Srv),
        ?assertMatch({_, _}, binary:match(Wire, <<"\r\n..dot line\r\n">>))
    end).

partial_recipients_test() ->
    with(#{}, fun(Srv) ->
        {ok, R} = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"ok@y">>, <<"bad@y">>], ?MSG),
        ?assertEqual([<<"ok@y">>], maps:get(accepted, R)),
        ?assertMatch([#{recipient := <<"bad@y">>, code := 550}], maps:get(rejected, R)),
        ?assertEqual(1, mailio_fake_smtp:data_count(Srv))
    end).

all_recipients_refused_test() ->
    with(#{}, fun(Srv) ->
        E = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"bad1@y">>, <<"bad2@y">>], ?MSG),
        ?assertEqual(smtp_rejected, code(E)),
        ?assertEqual(rcpt_to, maps:get(stage, detail(E))),
        ?assertEqual(0, mailio_fake_smtp:data_count(Srv))
    end).

sender_refused_and_deferred_test() ->
    with(#{mode => reject_mail_from}, fun(Srv) ->
        E = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_rejected, code(E)),
        ?assertNot(retryable(E))
    end),
    with(#{mode => defer_mail_from}, fun(Srv) ->
        E = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_transient, code(E)),
        ?assert(retryable(E))
    end).

message_refused_and_deferred_test() ->
    with(#{mode => reject_data}, fun(Srv) ->
        E = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_rejected, code(E)),
        ?assertEqual(data_end, maps:get(stage, detail(E)))
    end),
    with(#{mode => defer_data}, fun(Srv) ->
        E = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_transient, code(E)),
        ?assert(retryable(E))
    end).

lost_final_reply_is_unknown_test() ->
    with(#{mode => drop_after_data}, fun(Srv) ->
        E = mailio_smtp:submit(cfg(Srv), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_outcome_unknown, code(E)),
        ?assertNot(retryable(E)),
        %% the body did reach the server: a blind retry would duplicate it
        ?assertEqual(1, mailio_fake_smtp:data_count(Srv))
    end).

connect_refused_is_retryable_test() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    E = mailio_smtp:submit(
        #{host => <<"127.0.0.1">>, port => Port, tls => false}, <<"a@x">>, [<<"b@y">>], ?MSG
    ),
    ?assertEqual(smtp_connect_failed, code(E)),
    ?assert(retryable(E)).

auth_plain_login_xoauth2_test() ->
    with(#{auth => plain}, fun(Srv) ->
        {ok, _} = mailio_smtp:submit(
            cfg(Srv, #{credentials => {password, <<"u">>, <<"p">>}}),
            <<"a@x">>,
            [<<"b@y">>],
            ?MSG
        ),
        ?assertEqual(
            [{plain, binary_to_list(base64:encode(<<0, "u", 0, "p">>))}],
            mailio_fake_smtp:auth_seen(Srv)
        )
    end),
    with(#{auth => login}, fun(Srv) ->
        {ok, _} = mailio_smtp:submit(
            cfg(Srv, #{credentials => {password, <<"u">>, <<"p">>}}),
            <<"a@x">>,
            [<<"b@y">>],
            ?MSG
        ),
        ?assertMatch([{login, _, _}], mailio_fake_smtp:auth_seen(Srv))
    end),
    with(#{auth => plain}, fun(Srv) ->
        {ok, _} = mailio_smtp:submit(
            cfg(Srv, #{credentials => {oauth2, <<"u@x">>, <<"tok">>}}),
            <<"a@x">>,
            [<<"b@y">>],
            ?MSG
        ),
        [{xoauth2, B64}] = mailio_fake_smtp:auth_seen(Srv),
        ?assertEqual(<<"user=u@x", 1, "auth=Bearer tok", 1, 1>>, base64:decode(list_to_binary(B64)))
    end).

auth_failure_test() ->
    with(#{mode => auth_fail}, fun(Srv) ->
        E = mailio_smtp:submit(
            cfg(Srv, #{credentials => {password, <<"u">>, <<"bad">>}}),
            <<"a@x">>,
            [<<"b@y">>],
            ?MSG
        ),
        ?assertEqual(smtp_auth_failed, code(E)),
        ?assertEqual(0, mailio_fake_smtp:data_count(Srv))
    end).

token_fun_is_resolved_test() ->
    with(#{auth => plain}, fun(Srv) ->
        F = fun() -> {ok, {oauth2, <<"u">>, <<"fresh">>}} end,
        {ok, _} = mailio_smtp:submit(
            cfg(Srv, #{credentials => {token_fun, F}}), <<"a@x">>, [<<"b@y">>], ?MSG
        ),
        ?assertMatch([{xoauth2, _}], mailio_fake_smtp:auth_seen(Srv))
    end).

%%--------------------------------------------------------------------
%% TLS: certificates are generated for the test; the host name is checked

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
            port => mailio_fake_smtp:port(Srv),
            ehlo_name => <<"test.local">>
        },
        Extra
    ).

implicit_tls_verified_test() ->
    {Server, Client} = certs(),
    CACerts = proplists:get_value(cacerts, Client),
    with(#{tls => implicit, tls_opts => Server}, fun(Srv) ->
        %% trusted chain and matching host name: accepted
        {ok, _} = mailio_smtp:submit(
            tls_cfg(Srv, #{tls => true, cacerts => CACerts}),
            <<"a@x">>,
            [<<"b@y">>],
            ?MSG
        ),
        %% default trust store does not contain the test CA: refused
        E = mailio_smtp:submit(tls_cfg(Srv, #{tls => true}), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_tls_failed, code(E)),
        %% the host name must match the certificate
        E2 = mailio_smtp:submit(
            tls_cfg(Srv, #{tls => true, cacerts => CACerts, host => <<"127.0.0.1">>}),
            <<"a@x">>,
            [<<"b@y">>],
            ?MSG
        ),
        ?assertEqual(smtp_tls_failed, code(E2)),
        ?assertEqual(1, mailio_fake_smtp:data_count(Srv))
    end).

starttls_test() ->
    {Server, Client} = certs(),
    CACerts = proplists:get_value(cacerts, Client),
    with(#{tls => starttls, tls_opts => Server}, fun(Srv) ->
        {ok, _} = mailio_smtp:submit(
            tls_cfg(Srv, #{tls => starttls, cacerts => CACerts}),
            <<"a@x">>,
            [<<"b@y">>],
            ?MSG
        ),
        ?assertEqual(1, mailio_fake_smtp:data_count(Srv)),
        E = mailio_smtp:submit(tls_cfg(Srv, #{tls => starttls}), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_tls_failed, code(E))
    end),
    %% a server that does not offer STARTTLS is refused, never used in clear text
    with(#{tls => none}, fun(Srv) ->
        E = mailio_smtp:submit(cfg(Srv, #{tls => starttls}), <<"a@x">>, [<<"b@y">>], ?MSG),
        ?assertEqual(smtp_tls_failed, code(E)),
        ?assertEqual(0, mailio_fake_smtp:data_count(Srv))
    end).

%%====================================================================
%% Bounded replies
%%====================================================================

%% A raw server where Reply(Command) gives the reply to each command and
%% Reply(data_end) the reply after the message body.
raw(Reply) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {packet, line}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L),
        gen_tcp:send(S, <<"220 hi\r\n">>),
        raw_loop(S, Reply)
    end),
    {L, #{host => <<"127.0.0.1">>, port => Port, tls => false, ehlo_name => <<"t">>}}.

raw_loop(S, Reply) ->
    case gen_tcp:recv(S, 0, 3000) of
        {ok, <<"DATA", _/binary>>} ->
            gen_tcp:send(S, <<"354 go\r\n">>),
            raw_body(S),
            gen_tcp:send(S, Reply(data_end)),
            raw_loop(S, Reply);
        {ok, Line} ->
            [Cmd | _] = binary:split(Line, [<<" ">>, <<"\r">>]),
            gen_tcp:send(S, Reply(Cmd)),
            raw_loop(S, Reply);
        {error, _} ->
            ok
    end.

raw_body(S) ->
    case gen_tcp:recv(S, 0, 3000) of
        {ok, <<".\r\n">>} -> ok;
        {ok, _} -> raw_body(S);
        {error, _} -> ok
    end.

normal(<<"EHLO">>) -> <<"250 ok\r\n">>;
normal(<<"MAIL">>) -> <<"250 ok\r\n">>;
normal(<<"RCPT">>) -> <<"250 ok\r\n">>;
normal(<<"QUIT">>) -> <<"221 bye\r\n">>;
normal(data_end) -> <<"250 queued\r\n">>;
normal(_) -> <<"250 ok\r\n">>.

reply_with_too_many_lines_before_body_is_transient_test() ->
    {L, Cfg} = raw(fun
        (<<"EHLO">>) -> [<<"250-line\r\n">> || _ <- lists:seq(1, 500)] ++ [<<"250 end\r\n">>];
        (C) -> normal(C)
    end),
    R = mailio_smtp:submit(Cfg, <<"a@x">>, [<<"b@y">>], ?MSG),
    ?assertEqual(smtp_transient, code(R)),
    ?assert(retryable(R)),
    gen_tcp:close(L).

very_long_reply_line_is_refused_test() ->
    {L, Cfg} = raw(fun
        (<<"EHLO">>) -> [<<"250 ">>, binary:copy(<<"x">>, 8000), <<"\r\n">>];
        (C) -> normal(C)
    end),
    ?assertEqual(smtp_transient, code(mailio_smtp:submit(Cfg, <<"a@x">>, [<<"b@y">>], ?MSG))),
    gen_tcp:close(L).

oversized_final_reply_leaves_the_outcome_unknown_test() ->
    {L, Cfg} = raw(fun
        (data_end) -> [<<"250-more\r\n">> || _ <- lists:seq(1, 500)] ++ [<<"250 end\r\n">>];
        (C) -> normal(C)
    end),
    R = mailio_smtp:submit(Cfg, <<"a@x">>, [<<"b@y">>], ?MSG),
    ?assertEqual(smtp_outcome_unknown, code(R)),
    gen_tcp:close(L).

multi_line_reply_under_the_limit_works_test() ->
    {L, Cfg} = raw(fun
        (<<"EHLO">>) -> [<<"250-line\r\n">> || _ <- lists:seq(1, 30)] ++ [<<"250 end\r\n">>];
        (C) -> normal(C)
    end),
    ?assertMatch({ok, _}, mailio_smtp:submit(Cfg, <<"a@x">>, [<<"b@y">>], ?MSG)),
    gen_tcp:close(L).
