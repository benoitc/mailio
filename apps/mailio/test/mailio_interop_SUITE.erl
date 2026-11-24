%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Interoperability: the mailio IMAP, POP3 and SMTP clients and the MIME
%%% code against real mail servers, with no MCP server or store involved.
%%%
%%% Each server is a group. A group is skipped, with one message, when its
%%% server is not running, so this suite is safe to run anywhere. Start the
%%% servers first (see the "Interoperability" section of CONTRIBUTING.md):
%%%
%%%   apps/mailio/test/mailpit/gen-certs.sh
%%%   (cd apps/mailio_mcp/test/dovecot && docker compose up -d --build)   Dovecot: IMAP, POP3
%%%   (cd apps/mailio_mcp/test && docker compose up -d)                   GreenMail: IMAP, POP3, SMTP
%%%
%%% What it checks that the fake servers cannot: that our wire format is what
%%% a real implementation accepts and produces, that a message survives
%%% render, SMTP, delivery, IMAP or POP3 and parse unchanged, that TLS is
%%% verified, and that the size limits hold against a server that is not ours.
-module(mailio_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2]).
-export([
    imap_login_and_capabilities/1,
    imap_append_and_fetch_roundtrip/1,
    imap_attachment_and_utf8_roundtrip/1,
    imap_reading_keeps_mail_unseen/1,
    imap_wrong_password_is_terminal/1,
    imap_idle_wakes_for_new_mail/1,
    imap_literal_limit_holds/1,
    imap_implicit_tls_verified/1,
    imap_starttls_verified/1,
    imap_untrusted_certificate_refused/1,
    pop3_roundtrip/1,
    pop3_uidl_stable_across_connections/1,
    pop3_implicit_tls/1,
    pop3_listing_limit_holds/1,
    pop3_never_deletes/1,
    smtp_delivery_roundtrip/1,
    smtp_implicit_tls/1
]).

all() -> [{group, dovecot}, {group, greenmail}].

groups() ->
    Imap = [
        imap_login_and_capabilities,
        imap_append_and_fetch_roundtrip,
        imap_attachment_and_utf8_roundtrip,
        imap_reading_keeps_mail_unseen,
        imap_wrong_password_is_terminal,
        imap_idle_wakes_for_new_mail,
        imap_literal_limit_holds,
        imap_implicit_tls_verified,
        imap_starttls_verified,
        imap_untrusted_certificate_refused
    ],
    Pop3 = [
        pop3_roundtrip,
        pop3_uidl_stable_across_connections,
        pop3_implicit_tls,
        pop3_listing_limit_holds,
        pop3_never_deletes
    ],
    Smtp = [smtp_delivery_roundtrip, smtp_implicit_tls],
    [
        {dovecot, [], Imap ++ Pop3},
        {greenmail, [], Imap ++ Pop3 ++ Smtp}
    ].

%%====================================================================
%% Servers
%%====================================================================

%% What each server offers. A key that is missing means "not offered", and the
%% case that needs it is skipped for that server.
profile(dovecot) ->
    #{
        name => dovecot,
        user => <<"testuser">>,
        pass => <<"testpass">>,
        imap => 31143,
        imap_tls => 31993,
        imap_starttls => true,
        exact_sizes => true,
        %% the host name in the certificate
        tls_host => <<"localhost">>,
        pop3 => 31110,
        pop3_tls => 31995,
        %% the private CA of apps/mailio/test/mailpit/gen-certs.sh
        verify => ca
    };
profile(greenmail) ->
    #{
        name => greenmail,
        user => <<"alice">>,
        pass => <<"secret">>,
        address => <<"alice@example.test">>,
        imap => 3143,
        imap_tls => 3993,
        pop3 => 3110,
        pop3_tls => 3995,
        smtp => 3025,
        smtp_tls => 3465,
        %% GreenMail makes a self-signed certificate on every start
        verify => none
    }.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Name, Config) ->
    P = profile(Name),
    case reachable(maps:get(imap, P)) of
        false ->
            {skip,
                lists:flatten(
                    io_lib:format("~p is not running, see the header of this suite", [Name])
                )};
        true ->
            case wait_ready(P, 120) of
                ok -> [{profile, P} | Config];
                timeout -> {skip, lists:flatten(io_lib:format("~p does not accept logins", [Name]))}
            end
    end.

end_per_group(_Name, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    P = ?config(profile, Config),
    purge(P),
    Config.

reachable(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary], 500) of
        {ok, S} ->
            gen_tcp:close(S),
            true;
        _ ->
            false
    end.

wait_ready(_P, 0) ->
    timeout;
wait_ready(P, N) ->
    case imap_open(P, #{}) of
        {ok, C} ->
            mailio_imap_conn:close(C),
            ok;
        _ ->
            timer:sleep(500),
            wait_ready(P, N - 1)
    end.

%%====================================================================
%% IMAP cases
%%====================================================================

imap_login_and_capabilities(Config) ->
    P = ?config(profile, Config),
    {ok, C} = imap_open(P, #{}),
    Caps = mailio_imap_conn:capabilities(C),
    ?assert(lists:member(<<"IMAP4REV1">>, [string:uppercase(X) || X <- Caps])),
    mailio_imap_conn:close(C).

imap_append_and_fetch_roundtrip(Config) ->
    P = ?config(profile, Config),
    Raw = message(
        <<"plain roundtrip">>, <<"Hello, world.\r\n.\r\nA line with a leading dot above.\r\n">>
    ),
    {ok, C} = imap_open(P, #{}),
    ok = append(C, Raw),
    [{_Uid, Got}] = fetch_all(C),
    mailio_imap_conn:close(C),
    Parsed = mailio_mime:parse(Got),
    ?assertEqual(<<"plain roundtrip">>, mailio_mime:header(<<"subject">>, Parsed)),
    ?assertEqual(
        <<"Hello, world.\r\n.\r\nA line with a leading dot above.\r\n">>, mailio_mime:body(Parsed)
    ).

imap_attachment_and_utf8_roundtrip(Config) ->
    P = ?config(profile, Config),
    Attachment = crypto:strong_rand_bytes(300 * 1024),
    Subject = <<"Réunion à 14h: café ☕"/utf8>>,
    Raw = attachment_message(Subject, <<"Bonjour, voici le fichier. Ça va?\r\n"/utf8>>, Attachment),
    {ok, C} = imap_open(P, #{}),
    ok = append(C, Raw),
    [{_, Got}] = fetch_all(C),
    mailio_imap_conn:close(C),
    Parsed = mailio_mime:parse(Got),
    ?assertEqual(
        Subject, mailio_rfc5322:decode_unstructured(mailio_mime:header(<<"subject">>, Parsed))
    ),
    [Text, Att] = mailio_mime:leaves(Parsed),
    ?assertEqual(<<"Bonjour, voici le fichier. Ça va?\r\n"/utf8>>, mailio_mime:body(Text)),
    ?assertEqual(<<"data.bin">>, mailio_mime:filename(Att)),
    ?assertEqual(Attachment, mailio_mime:body(Att)).

imap_reading_keeps_mail_unseen(Config) ->
    P = ?config(profile, Config),
    {ok, C} = imap_open(P, #{}),
    ok = append(C, message(<<"unseen">>, <<"x\r\n">>)),
    %% what the library does for every read: EXAMINE and BODY.PEEK
    [{Uid, _}] = fetch_all(C),
    {ok, Ev, {ok, _, _}} = mailio_imap_conn:run(C, fun(T) ->
        {mailio_imap_proto:uid_fetch(T, {range, Uid, Uid}, [<<"FLAGS">>]), undefined}
    end),
    [Flags] = [F || {fetch, _, I} <- Ev, {flags, F} <- [lists:keyfind(flags, 1, I)]],
    ?assertNot(lists:member(<<"\\Seen">>, Flags)),
    mailio_imap_conn:close(C).

imap_wrong_password_is_terminal(Config) ->
    P = ?config(profile, Config),
    {ok, C} = mailio_imap_conn:start_link(
        imap_cfg(P, #{credentials => {password, maps:get(user, P), <<"not the password">>}})
    ),
    ?assertEqual({error, authentication_failed}, noop(C)),
    %% not retried: the next call gets the same answer without a new login
    ?assertEqual({error, authentication_failed}, noop(C)),
    mailio_imap_conn:close(C).

imap_idle_wakes_for_new_mail(Config) ->
    P = ?config(profile, Config),
    {ok, Watcher} = imap_open(P, #{}),
    {ok, _, {ok, _, _}} = mailio_imap_conn:run(Watcher, fun(T) ->
        {mailio_imap_proto:examine(T, <<"INBOX">>), undefined}
    end),
    ok = mailio_imap_conn:idle_start(Watcher, self()),
    {ok, Other} = imap_open(P, #{}),
    ok = append(Other, message(<<"wake up">>, <<"x\r\n">>)),
    receive
        {imap_idle_event, Watcher, {exists, N}} -> ?assert(N >= 1)
    after 15000 -> ct:fail(no_idle_event)
    end,
    ok = mailio_imap_conn:idle_stop(Watcher),
    mailio_imap_conn:close(Watcher),
    mailio_imap_conn:close(Other).

imap_literal_limit_holds(Config) ->
    P = ?config(profile, Config),
    {ok, Writer} = imap_open(P, #{}),
    Raw = attachment_message(<<"big">>, <<"x\r\n">>, crypto:strong_rand_bytes(200 * 1024)),
    ok = append(Writer, Raw),
    mailio_imap_conn:close(Writer),
    {ok, C} = imap_open(P, #{max_literal => 50 * 1024}),
    {ok, _, {ok, _, _}} = mailio_imap_conn:run(C, fun(T) ->
        {mailio_imap_proto:examine(T, <<"INBOX">>), undefined}
    end),
    R = mailio_imap_conn:run(C, fun(T) ->
        {mailio_imap_proto:uid_fetch(T, {range, 1, '*'}, [<<"BODY.PEEK[]">>]), undefined}
    end),
    ?assertEqual({error, response_too_large}, R),
    %% terminal: the connection is closed and stays closed
    ?assertEqual({error, response_too_large}, noop(C)),
    mailio_imap_conn:close(C).

imap_implicit_tls_verified(Config) ->
    P = ?config(profile, Config),
    {ok, C} = imap_open(P, #{tls => true, port => maps:get(imap_tls, P)}),
    ?assertMatch({ok, _, {ok, _, _}}, noop(C)),
    mailio_imap_conn:close(C).

imap_starttls_verified(Config) ->
    P = ?config(profile, Config),
    case maps:get(imap_starttls, P, false) of
        false ->
            {skip, "the server does not offer STARTTLS"};
        true ->
            {ok, C} = imap_open(P, #{tls => starttls}),
            ?assertMatch({ok, _, {ok, _, _}}, noop(C)),
            mailio_imap_conn:close(C)
    end.

imap_untrusted_certificate_refused(Config) ->
    P = ?config(profile, Config),
    %% the system trust store does not know the server's certificate
    {ok, C} = mailio_imap_conn:start_link(
        (imap_cfg(P, #{tls => true, port => maps:get(imap_tls, P)}))#{
            verify => verify_peer,
            cacerts => public_key:cacerts_get()
        }
    ),
    ?assertEqual({error, tls_failed}, noop(C)),
    mailio_imap_conn:close(C).

%%====================================================================
%% POP3 cases
%%====================================================================

pop3_roundtrip(Config) ->
    P = ?config(profile, Config),
    Raw = message(<<"over pop3">>, <<"pop body\r\n.\r\ndot line\r\n">>),
    seed(P, [Raw]),
    {ok, C} = pop3_open(P, #{}),
    {ok, 1, _} = mailio_pop3:stat(C),
    {ok, [{1, Size}]} = mailio_pop3:list(C),
    {ok, [{1, Uidl}]} = mailio_pop3:uidl(C),
    ?assert(byte_size(Uidl) > 0),
    {ok, Top} = mailio_pop3:top(C, 1, 0),
    ?assertEqual(
        <<"over pop3">>, mailio_rfc5322:header(<<"subject">>, mailio_rfc5322:headers(Top))
    ),
    {ok, Got} = mailio_pop3:retr(C, 1, 1024 * 1024),
    %% a server that adds no headers reports the size it sends
    case maps:get(exact_sizes, P, false) of
        true -> ?assertEqual(Size, byte_size(Got));
        false -> ?assert(byte_size(Got) >= byte_size(Raw))
    end,
    Parsed = mailio_mime:parse(Got),
    ?assertEqual(<<"pop body\r\n.\r\ndot line\r\n">>, mailio_mime:body(Parsed)),
    mailio_pop3:close(C).

pop3_uidl_stable_across_connections(Config) ->
    P = ?config(profile, Config),
    seed(P, [message(<<"a">>, <<"1\r\n">>), message(<<"b">>, <<"2\r\n">>)]),
    Ids = fun() ->
        {ok, C} = pop3_open(P, #{}),
        {ok, L} = mailio_pop3:uidl(C),
        mailio_pop3:close(C),
        L
    end,
    First = Ids(),
    ?assertEqual(2, length(First)),
    ?assertEqual(First, Ids()),
    ?assertEqual(2, length(lists:usort([U || {_, U} <- First]))).

pop3_implicit_tls(Config) ->
    P = ?config(profile, Config),
    seed(P, [message(<<"tls">>, <<"x\r\n">>)]),
    {ok, C} = pop3_open(P, #{tls => true, port => maps:get(pop3_tls, P)}),
    ?assertMatch({ok, 1, _}, mailio_pop3:stat(C)),
    mailio_pop3:close(C).

pop3_listing_limit_holds(Config) ->
    P = ?config(profile, Config),
    seed(P, [message(integer_to_binary(N), <<"x\r\n">>) || N <- lists:seq(1, 40)]),
    {ok, C} = pop3_open(P, #{max_list_bytes => 200}),
    ?assertEqual(pop3_response_too_large, mailio_error:code(mailio_pop3:uidl(C))),
    %% the connection was closed, not left half read
    ?assertEqual(pop3_disconnected, mailio_error:code(mailio_pop3:stat(C))).

pop3_never_deletes(Config) ->
    P = ?config(profile, Config),
    seed(P, [message(<<"keep">>, <<"x\r\n">>)]),
    {ok, C} = pop3_open(P, #{}),
    {ok, _} = mailio_pop3:retr(C, 1, 1024 * 1024),
    {ok, _} = mailio_pop3:top(C, 1, 0),
    mailio_pop3:close(C),
    {ok, C2} = pop3_open(P, #{}),
    ?assertMatch({ok, 1, _}, mailio_pop3:stat(C2)),
    mailio_pop3:close(C2),
    {ok, I} = imap_open(P, #{}),
    ?assertEqual(1, length(fetch_all(I))),
    mailio_imap_conn:close(I).

%%====================================================================
%% SMTP cases (the server delivers to the mailbox we then read)
%%====================================================================

smtp_delivery_roundtrip(Config) ->
    P = ?config(profile, Config),
    Addr = maps:get(address, P),
    Att = crypto:strong_rand_bytes(100 * 1024),
    Subject = <<"Livraison: été ☀"/utf8>>,
    Raw = attachment_message(Subject, <<".leading dot\r\nsecond line\r\n"/utf8>>, Att),
    {ok, R} = mailio_smtp:submit(smtp_cfg(P, #{}), Addr, [Addr], Raw),
    ?assertEqual([Addr], maps:get(accepted, R)),
    ImapGot = wait_for_mail(P, 1),
    Parsed = mailio_mime:parse(ImapGot),
    ?assertEqual(
        Subject, mailio_rfc5322:decode_unstructured(mailio_mime:header(<<"subject">>, Parsed))
    ),
    [Text, A] = mailio_mime:leaves(Parsed),
    ?assertEqual(<<".leading dot\r\nsecond line\r\n">>, mailio_mime:body(Text)),
    ?assertEqual(Att, mailio_mime:body(A)),
    %% the same message through POP3 is the same bytes
    {ok, Pop} = pop3_open(P, #{}),
    {ok, PopGot} = mailio_pop3:retr(Pop, 1, 1024 * 1024),
    mailio_pop3:close(Pop),
    ?assertEqual(
        mailio_mime:body(A),
        mailio_mime:body(lists:last(mailio_mime:leaves(mailio_mime:parse(PopGot))))
    ).

smtp_implicit_tls(Config) ->
    P = ?config(profile, Config),
    Addr = maps:get(address, P),
    {ok, R} = mailio_smtp:submit(
        smtp_cfg(P, #{tls => true, port => maps:get(smtp_tls, P)}),
        Addr,
        [Addr],
        message(<<"smtps">>, <<"x\r\n">>)
    ),
    ?assertEqual([Addr], maps:get(accepted, R)),
    ?assert(byte_size(wait_for_mail(P, 1)) > 0).

%%====================================================================
%% Helpers: connections
%%====================================================================

tls_opts(#{verify := none}) ->
    #{verify => verify_none};
tls_opts(#{verify := ca}) ->
    #{verify => verify_peer, cacertfile => ca_file()}.

ca_file() ->
    filename:join([filename:dirname(?FILE), "mailpit", "certs", "ca.pem"]).

imap_cfg(P, Extra) ->
    maps:merge(
        maps:merge(
            #{
                host => host(P, Extra),
                port => maps:get(imap, P),
                tls => false,
                credentials => {password, maps:get(user, P), maps:get(pass, P)}
            },
            tls_opts(P)
        ),
        Extra
    ).

imap_open(P, Extra) ->
    mailio_imap_conn:start_link(imap_cfg(P, Extra)).

pop3_open(P, Extra) ->
    Base = maps:merge(
        #{
            host => host(P, Extra),
            port => maps:get(pop3, P),
            tls => false,
            credentials => {password, maps:get(user, P), maps:get(pass, P)}
        },
        tls_opts(P)
    ),
    mailio_pop3:open(maps:merge(Base, Extra)).

smtp_cfg(P, Extra) ->
    maps:merge(
        maps:merge(
            #{
                host => host(P, Extra),
                port => maps:get(smtp, P),
                tls => false,
                ehlo_name => <<"interop.test">>,
                credentials => {password, maps:get(user, P), maps:get(pass, P)}
            },
            tls_opts(P)
        ),
        Extra
    ).

%% Certificates name a host: connect by that name when TLS is on.
host(P, Extra) ->
    case maps:get(tls, Extra, false) of
        false -> <<"127.0.0.1">>;
        _ -> maps:get(tls_host, P, <<"127.0.0.1">>)
    end.

noop(C) ->
    mailio_imap_conn:run(C, fun(T) -> {[T, <<" NOOP\r\n">>], undefined} end, 5000).

%%====================================================================
%% Helpers: mailbox state
%%====================================================================

%% Empty the INBOX so a case starts from nothing.
purge(P) ->
    {ok, C} = imap_open(P, #{}),
    case
        mailio_imap_conn:run(C, fun(T) -> {mailio_imap_proto:select(T, <<"INBOX">>), undefined} end)
    of
        {ok, Ev, {ok, _, _}} ->
            case lists:keyfind(exists, 1, Ev) of
                {exists, N} when N > 0 ->
                    {ok, _, _} = mailio_imap_conn:run(C, fun(T) ->
                        {
                            mailio_imap_proto:uid_store(
                                T, {range, 1, '*'}, {add, true}, [<<"\\Deleted">>]
                            ),
                            undefined
                        }
                    end),
                    {ok, _, _} = mailio_imap_conn:run(C, fun(T) ->
                        {mailio_imap_proto:expunge(T), undefined}
                    end);
                _ ->
                    ok
            end;
        Other ->
            ct:fail({purge, Other})
    end,
    mailio_imap_conn:close(C).

append(C, Raw) ->
    case mailio_imap_conn:run(C, fun(T) -> mailio_imap_proto:append(T, <<"INBOX">>, [], Raw) end) of
        {ok, _, {ok, _, _}} -> ok;
        Other -> ct:fail({append, Other})
    end.

%% Put messages in the INBOX, through IMAP, so POP3 can read them.
seed(P, Raws) ->
    {ok, C} = imap_open(P, #{}),
    [ok = append(C, R) || R <- Raws],
    mailio_imap_conn:close(C).

%% Every message of the INBOX as {Uid, Raw}, read the way the library reads:
%% EXAMINE and BODY.PEEK.
fetch_all(C) ->
    {ok, _, {ok, _, _}} = mailio_imap_conn:run(C, fun(T) ->
        {mailio_imap_proto:examine(T, <<"INBOX">>), undefined}
    end),
    {ok, Ev, {ok, _, _}} = mailio_imap_conn:run(C, fun(T) ->
        {
            mailio_imap_proto:uid_fetch(T, {range, 1, '*'}, [<<"UID">>, <<"BODY.PEEK[]">>]),
            undefined
        }
    end),
    [{proplists:get_value(uid, I), proplists:get_value(body, I)} || {fetch, _, I} <- Ev].

%% Wait until the server has delivered N messages, then give back the last.
wait_for_mail(P, N) -> wait_for_mail(P, N, 40).

wait_for_mail(_P, _N, 0) ->
    ct:fail(mail_not_delivered);
wait_for_mail(P, N, Left) ->
    {ok, C} = imap_open(P, #{}),
    Msgs = fetch_all(C),
    mailio_imap_conn:close(C),
    case length(Msgs) >= N of
        true ->
            element(2, lists:last(Msgs));
        false ->
            timer:sleep(250),
            wait_for_mail(P, N, Left - 1)
    end.

%%====================================================================
%% Helpers: messages
%%====================================================================

message(Subject, Body) ->
    mailio_mime_render:render(#{
        type => <<"text">>,
        subtype => <<"plain">>,
        charset => <<"utf-8">>,
        encoding => <<"7bit">>,
        headers => base_headers(Subject),
        body => Body
    }).

attachment_message(Subject, Text, Attachment) ->
    mailio_mime_render:render(#{
        type => <<"multipart">>,
        subtype => <<"mixed">>,
        headers => base_headers(Subject),
        parts => [
            #{
                type => <<"text">>,
                subtype => <<"plain">>,
                charset => <<"utf-8">>,
                encoding => <<"quoted-printable">>,
                body => Text
            },
            #{
                type => <<"application">>,
                subtype => <<"octet-stream">>,
                params => #{<<"name">> => <<"data.bin">>},
                encoding => <<"base64">>,
                disposition => <<"attachment">>,
                filename => <<"data.bin">>,
                body => Attachment
            }
        ]
    }).

base_headers(Subject) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    [
        {<<"From">>, <<"sender@example.test">>},
        {<<"To">>, <<"alice@example.test">>},
        {<<"Subject">>, Subject},
        {<<"Message-ID">>, <<"<", Id/binary, "@interop.test>">>},
        {<<"Date">>, <<"Mon, 23 Nov 2026 10:00:00 +0000">>},
        {<<"MIME-Version">>, <<"1.0">>}
    ].
