%%% The IMAP adapter against a real server (Dovecot), for what GreenMail and the
%%% fake server cannot show: QRESYNC, STARTTLS, implicit TLS, UTF-8 search and
%%% UTF-7 mailbox names. Start it first:
%%%   apps/mailio/test/mailpit/gen-certs.sh
%%%   (cd apps/mailio_mcp/test/dovecot && docker compose up -d --build)
-module(mailio_mcp_imap_dovecot_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    advertises_qresync/1,
    search_and_read/1,
    reading_keeps_mail_unread/1,
    utf8_search_uses_a_literal/1,
    utf7_mailbox_name/1,
    changes_with_qresync/1,
    changes_fall_back_without_a_modseq/1,
    idle_times_out/1,
    idle_wakes_for_new_mail_flags_and_expunges/1,
    idle_sees_a_change_made_before_it_started/1,
    implicit_tls_verified/1,
    starttls_verified/1,
    untrusted_certificate_refused/1,
    wrong_password_is_not_retried/1
]).

-define(PLAIN, 31143).
-define(TLS, 31993).

all() ->
    [
        advertises_qresync,
        search_and_read,
        reading_keeps_mail_unread,
        utf8_search_uses_a_literal,
        utf7_mailbox_name,
        changes_with_qresync,
        changes_fall_back_without_a_modseq,
        idle_times_out,
        idle_wakes_for_new_mail_flags_and_expunges,
        idle_sees_a_change_made_before_it_started,
        implicit_tls_verified,
        starttls_verified,
        untrusted_certificate_refused,
        wrong_password_is_not_retried
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    %% the counters live in an ETS table, so it needs an owner that outlives init
    Self = self(),
    Holder = spawn(fun() ->
        ok = mailio_mcp_stats:init(),
        Self ! stats_ready,
        receive
            stop -> ok
        end
    end),
    receive
        stats_ready -> ok
    end,
    case reachable(?PLAIN) of
        false ->
            {skip, "Dovecot is not running (see the header of this suite)"};
        true ->
            case find_ca(proplists:get_value(data_dir, Config)) of
                undefined ->
                    {skip, "run apps/mailio/test/mailpit/gen-certs.sh and restart Dovecot"};
                CA ->
                    case wait_ready(120) of
                        ok ->
                            [{ca, CA}, {holder, Holder} | Config];
                        timeout ->
                            Holder ! stop,
                            {skip, "Dovecot is running but does not accept logins after 60 seconds"}
                    end
            end
    end.

end_per_suite(Config) ->
    case proplists:get_value(holder, Config) of
        undefined ->
            ok;
        Pid ->
            Pid ! stop,
            ok
    end.

init_per_testcase(_, Config) ->
    purge(<<"INBOX">>),
    mailio_mcp_stats:reset(),
    Config.

reachable(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary], 500) of
        {ok, S} ->
            gen_tcp:close(S),
            true;
        _ ->
            false
    end.

find_ca(Dir) ->
    Rel = "apps/mailio/test/mailpit/certs/ca.pem",
    case filelib:is_file(filename:join(Dir, Rel)) of
        true ->
            filename:join(Dir, Rel);
        false ->
            Up = filename:dirname(string:trim(Dir, trailing, "/")),
            case Up =:= Dir of
                true -> undefined;
                false -> find_ca(Up)
            end
    end.

%%--------------------------------------------------------------------
%% Helpers

account() -> account(#{}).
account(Over) ->
    #{
        id => <<"dovecot">>,
        incoming => maps:merge(
            #{protocol => imap, host => "127.0.0.1", port => ?PLAIN, tls => none}, Over
        ),
        auth => #{user => <<"testuser">>, secret => {value, <<"testpass">>}, mechanism => plain}
    }.

%% Dovecot answers "waiting for authentication" for a few seconds after start.
%% Wait for Dovecot to accept a login, once for the whole suite: a cold
%% container takes a while, and one skip is clearer than every case failing.
wait_ready(0) ->
    timeout;
wait_ready(N) ->
    case mailio_mcp_imap_io:open(account()) of
        {ok, C} ->
            mailio_mcp_imap_io:close(C),
            ok;
        {error, _} ->
            timer:sleep(500),
            wait_ready(N - 1)
    end.

with_conn(Fun) ->
    {ok, C} = mailio_mcp_imap_io:open(account()),
    try
        Fun(C)
    after
        mailio_mcp_imap_io:close(C)
    end.

run(C, Parts) ->
    {ok, Events, _} = mailio_mcp_imap_io:cmd(C, Parts),
    Events.

purge(Box) ->
    with_conn(fun(C) ->
        case
            mailio_mcp_imap_io:cmd(C, [
                <<"SELECT ">>, mailio_mcp_imap_io:quote(mailio_mcp_imap_io:utf7_encode(Box))
            ])
        of
            {ok, Ev, _} ->
                case [N || {exists, N} <- Ev, N > 0] of
                    [] ->
                        ok;
                    _ ->
                        run(C, [<<"STORE 1:* +FLAGS (\\Deleted)">>]),
                        run(C, [<<"EXPUNGE">>])
                end;
            _ ->
                ok
        end
    end).

append(Box, Flags, Date, Raw) ->
    with_conn(fun(C) ->
        {ok, _, _} = mailio_mcp_imap_io:cmd(C, [
            <<"APPEND ">>,
            mailio_mcp_imap_io:quote(mailio_mcp_imap_io:utf7_encode(Box)),
            <<" (">>,
            Flags,
            <<") \"">>,
            Date,
            <<"\" ">>,
            {literal, iolist_to_binary(Raw)}
        ]),
        ok
    end).

msg(Spec) -> mailio_mcp_lib:msg(Spec).

flags_of(Uid) ->
    with_conn(fun(C) ->
        run(C, [<<"EXAMINE INBOX">>]),
        Ev = run(C, [<<"UID FETCH ">>, integer_to_binary(Uid), <<" (FLAGS)">>]),
        [
            [string:lowercase(F) || F <- proplists:get_value(flags, Items, [])]
         || {fetch, _, Items} <- Ev
        ]
    end).

all_uids() ->
    with_conn(fun(C) ->
        run(C, [<<"EXAMINE INBOX">>]),
        lists:sort(lists:append([U || {search, U} <- run(C, [<<"UID SEARCH ALL">>])]))
    end).

counter(Kind) -> maps:get({<<"dovecot">>, Kind, req}, mailio_mcp_stats:snapshot(), 0).

changes(Prev) -> mailio_mcp_imap:changes(account(), <<"INBOX">>, Prev).

%%--------------------------------------------------------------------
%% Cases

advertises_qresync(_) ->
    #{reachable := true, extensions := Ext} = mailio_mcp_imap:capabilities(account()),
    true = lists:member(<<"QRESYNC">>, Ext),
    true = lists:member(<<"CONDSTORE">>, Ext),
    ok.

seed_three() ->
    Pdf = crypto:strong_rand_bytes(2000),
    append(
        <<"INBOX">>,
        <<>>,
        <<"10-Mar-2026 10:00:00 +0000">>,
        msg(#{
            from => <<"billing@vendor.test">>,
            to => <<"me@x.test">>,
            subject => <<"Invoice 2026">>,
            body => <<"Please pay.\r\n">>,
            attachment => {<<"inv.pdf">>, <<"application/pdf">>, Pdf}
        })
    ),
    append(
        <<"INBOX">>,
        <<>>,
        <<"11-Mar-2026 10:00:00 +0000">>,
        msg(#{
            from => <<"a@x.test">>,
            to => <<"me@x.test">>,
            subject => <<"Caf\xc3\xa9 noir"/utf8>>,
            body => <<"Un caf\xc3\xa9, merci.\r\n"/utf8>>
        })
    ),
    append(
        <<"INBOX">>,
        <<"\\Seen">>,
        <<"12-Mar-2026 10:00:00 +0000">>,
        msg(#{
            from => <<"b@x.test">>,
            to => <<"me@x.test">>,
            subject => <<"Lunch">>,
            body => <<"Noon?\r\n">>
        })
    ),
    Pdf.

hits(Q) ->
    {ok, Hits, _} = mailio_mcp_imap:search(account(), maps:merge(#{mailboxes => [<<"INBOX">>]}, Q)),
    Hits.

subjects(Hits) -> lists:sort([maps:get(subject, H) || H <- Hits]).

search_and_read(_) ->
    Pdf = seed_three(),
    [<<"Invoice 2026">>] = subjects(hits(#{subject => <<"Invoice">>})),
    [<<"Invoice 2026">>] = subjects(hits(#{from => <<"vendor">>})),
    [<<"Lunch">>] = subjects(hits(#{text => <<"Noon">>})),
    %% flags and attachments
    [<<"Caf\xc3\xa9 noir"/utf8>>, <<"Invoice 2026">>] = subjects(hits(#{unread => true})),
    [<<"Lunch">>] = subjects(hits(#{unread => false})),
    [<<"Invoice 2026">>] = subjects(hits(#{has_attachment => true})),
    %% exact time window on the received date (inclusive start, exclusive end)
    {ok, S, _} = mailio_mcp_time:parse_bound(<<"2026-03-11T00:00:00Z">>, undefined),
    {ok, E, _} = mailio_mcp_time:parse_bound(<<"2026-03-12T00:00:00Z">>, undefined),
    [<<"Caf\xc3\xa9 noir"/utf8>>] = subjects(hits(#{since => S, before => E})),
    %% read the message with the attachment, then fetch just that part
    [Inv] = hits(#{subject => <<"Invoice">>}),
    Loc = maps:with([mailbox, uv, uid], Inv),
    {ok, Msg} = mailio_mcp_imap:read_message(account(), Loc, #{}),
    <<"Please pay.">> = string:trim(maps:get(text, Msg)),
    [#{id := PartId, name := <<"inv.pdf">>, type := <<"application/pdf">>}] = maps:get(
        attachments, Msg
    ),
    {ok, #{bytes := Pdf, complete := true}} = mailio_mcp_imap:fetch_part(
        account(), Loc, PartId, 1000000
    ),
    ok.

reading_keeps_mail_unread(_) ->
    seed_three(),
    [Inv] = hits(#{subject => <<"Invoice">>}),
    Loc = maps:with([mailbox, uv, uid], Inv),
    {ok, _} = mailio_mcp_imap:read_message(account(), Loc, #{}),
    {ok, _, _} = mailio_mcp_imap:thread(account(), Loc, 10),
    _ = hits(#{text => <<"pay">>}),
    [Flags] = flags_of(maps:get(uid, Loc)),
    false = lists:member(<<"\\seen">>, Flags),
    ok.

utf8_search_uses_a_literal(_) ->
    seed_three(),
    %% a subject with a non-ASCII character goes to the server as a literal
    [<<"Caf\xc3\xa9 noir"/utf8>>] = subjects(hits(#{subject => <<"Caf\xc3\xa9"/utf8>>})),
    [<<"Caf\xc3\xa9 noir"/utf8>>] = subjects(hits(#{text => <<"caf\xc3\xa9"/utf8>>})),
    ok.

utf7_mailbox_name(_) ->
    Name = <<"Envoy\xc3\xa9s"/utf8>>,
    with_conn(fun(C) ->
        _ = mailio_mcp_imap_io:cmd(C, [
            <<"CREATE ">>, mailio_mcp_imap_io:quote(mailio_mcp_imap_io:utf7_encode(Name))
        ])
    end),
    purge(Name),
    append(
        Name,
        <<>>,
        <<"10-Mar-2026 10:00:00 +0000">>,
        msg(#{from => <<"a@x.test">>, to => <<"me@x.test">>, subject => <<"In a folder">>})
    ),
    {ok, Boxes} = mailio_mcp_imap:list_mailboxes(account(), true),
    [Box] = [B || B = #{name := N} <- Boxes, N =:= Name],
    1 = maps:get(messages, Box),
    {ok, [Hit], _} = mailio_mcp_imap:search(account(), #{mailboxes => [Name]}),
    <<"In a folder">> = maps:get(subject, Hit),
    ok.

changes_with_qresync(_) ->
    seed_three(),
    [U1, U2, U3] = all_uids(),
    {ok, #{baseline := true, snapshot := S0}} = changes(undefined),
    true = is_integer(maps:get(modseq, S0)),
    3 = maps:get(exists, S0),
    %% the baseline is the only call that lists the flags; count from here
    mailio_mcp_stats:reset(),
    %% nothing happened
    {ok, #{unchanged := true}} = changes(S0),
    1 = counter(changes_qresync),
    %% a flag changes on the server
    with_conn(fun(C) ->
        run(C, [<<"SELECT INBOX">>]),
        run(C, [<<"UID STORE ">>, integer_to_binary(U1), <<" +FLAGS (\\Seen)">>])
    end),
    {ok, R1} = changes(S0),
    [#{uid := U1, unread := false}] = maps:get(updated, R1),
    [] = maps:get(added, R1),
    [] = maps:get(removed, R1),
    S1 = maps:get(snapshot, R1),
    %% a message arrives
    append(
        <<"INBOX">>,
        <<>>,
        <<"13-Mar-2026 10:00:00 +0000">>,
        msg(#{from => <<"c@x.test">>, to => <<"me@x.test">>, subject => <<"Fresh">>})
    ),
    {ok, R2} = changes(S1),
    1 = maps:get(added_total, R2),
    [#{subject := <<"Fresh">>}] = maps:get(added, R2),
    S2 = maps:get(snapshot, R2),
    4 = maps:get(exists, S2),
    %% a message is expunged
    with_conn(fun(C) ->
        run(C, [<<"SELECT INBOX">>]),
        run(C, [<<"UID STORE ">>, integer_to_binary(U2), <<" +FLAGS (\\Deleted)">>]),
        run(C, [<<"EXPUNGE">>])
    end),
    {ok, R3} = changes(S2),
    [U2] = maps:get(removed, R3),
    S3 = maps:get(snapshot, R3),
    3 = maps:get(exists, S3),
    %% the chain is consistent: nothing is reported twice
    {ok, #{unchanged := true}} = changes(S3),
    %% and the checkpoint from before the expunge still sees it, once
    {ok, R4} = changes(S2),
    [U2] = maps:get(removed, R4),
    %% every call above took the QRESYNC path, none listed the whole mailbox
    0 = counter(changes_full),
    true = counter(changes_qresync) >= 6,
    true = lists:member(U3, maps:keys(maps:get(flags, S3))),
    ok.

changes_fall_back_without_a_modseq(_) ->
    seed_three(),
    {ok, #{snapshot := S0}} = changes(undefined),
    mailio_mcp_stats:reset(),
    [U | _] = all_uids(),
    with_conn(fun(C) ->
        run(C, [<<"SELECT INBOX">>]),
        run(C, [<<"UID STORE ">>, integer_to_binary(U), <<" +FLAGS (\\Seen)">>])
    end),
    {ok, R} = changes(S0#{modseq => undefined}),
    [#{uid := U}] = maps:get(updated, R),
    1 = counter(changes_full),
    0 = counter(changes_qresync),
    ok.

wait(Snap, Ms) -> mailio_mcp_imap:wait_for_change(account(), <<"INBOX">>, Snap, Ms).

timed(Fun) ->
    T0 = erlang:monotonic_time(millisecond),
    R = Fun(),
    {R, erlang:monotonic_time(millisecond) - T0}.

baseline() ->
    {ok, #{snapshot := S}} = changes(undefined),
    S.

idle_times_out(_) ->
    seed_three(),
    S = baseline(),
    {timeout, Ms} = timed(fun() -> wait(S, 1500) end),
    true = Ms >= 1400,
    1 = counter(idle_timeout),
    ok.

idle_wakes_for_new_mail_flags_and_expunges(_) ->
    seed_three(),
    [U1, U2, _] = all_uids(),
    S0 = baseline(),
    %% new mail from another connection while the wait is in IDLE
    spawn_link(fun() ->
        timer:sleep(700),
        append(
            <<"INBOX">>,
            <<>>,
            <<"14-Mar-2026 10:00:00 +0000">>,
            msg(#{from => <<"d@x.test">>, to => <<"me@x.test">>, subject => <<"Pushed">>})
        )
    end),
    {changed, Ms1} = timed(fun() -> wait(S0, 20000) end),
    true = Ms1 < 10000,
    {ok, #{snapshot := S1, added := [#{subject := <<"Pushed">>}]}} = changes(S0),
    %% a flag change
    spawn_link(fun() ->
        timer:sleep(700),
        with_conn(fun(C) ->
            run(C, [<<"SELECT INBOX">>]),
            run(C, [<<"UID STORE ">>, integer_to_binary(U1), <<" +FLAGS (\\Seen)">>])
        end)
    end),
    {changed, Ms2} = timed(fun() -> wait(S1, 20000) end),
    true = Ms2 < 10000,
    {ok, #{snapshot := S2}} = changes(S1),
    %% an expunge
    spawn_link(fun() ->
        timer:sleep(700),
        with_conn(fun(C) ->
            run(C, [<<"SELECT INBOX">>]),
            run(C, [<<"UID STORE ">>, integer_to_binary(U2), <<" +FLAGS (\\Deleted)">>]),
            run(C, [<<"EXPUNGE">>])
        end)
    end),
    {changed, Ms3} = timed(fun() -> wait(S2, 20000) end),
    true = Ms3 < 10000,
    3 = counter(idle_woken),
    ok.

%% The checkpoint is compared before IDLE starts, so a change made just
%% before the wait is reported at once.
idle_sees_a_change_made_before_it_started(_) ->
    seed_three(),
    S = baseline(),
    append(
        <<"INBOX">>,
        <<>>,
        <<"15-Mar-2026 10:00:00 +0000">>,
        msg(#{from => <<"e@x.test">>, to => <<"me@x.test">>, subject => <<"Earlier">>})
    ),
    {changed, Ms} = timed(fun() -> wait(S, 20000) end),
    true = Ms < 5000,
    ok.

implicit_tls_verified(Config) ->
    A = account(#{
        host => "localhost", port => ?TLS, tls => implicit, cacertfile => ?config(ca, Config)
    }),
    seed_three(),
    {ok, Hits, _} = mailio_mcp_imap:search(A, #{mailboxes => [<<"INBOX">>]}),
    3 = length(Hits),
    ok.

starttls_verified(Config) ->
    A = account(#{
        host => "localhost", port => ?PLAIN, tls => starttls, cacertfile => ?config(ca, Config)
    }),
    seed_three(),
    {ok, Hits, _} = mailio_mcp_imap:search(A, #{mailboxes => [<<"INBOX">>]}),
    3 = length(Hits),
    ok.

untrusted_certificate_refused(_) ->
    %% the test CA is not in the default trust store
    {error, {unavailable, _}} =
        mailio_mcp_imap:search(
            account(#{host => "localhost", port => ?TLS, tls => implicit}),
            #{mailboxes => [<<"INBOX">>]}
        ),
    {error, {unavailable, _}} =
        mailio_mcp_imap:search(
            account(#{host => "localhost", port => ?PLAIN, tls => starttls}),
            #{mailboxes => [<<"INBOX">>]}
        ),
    ok.

wrong_password_is_not_retried(_) ->
    A = (account())#{
        auth => #{user => <<"testuser">>, secret => {value, <<"nope">>}, mechanism => plain}
    },
    T0 = erlang:monotonic_time(millisecond),
    {error, {unavailable, authentication_failed}} = mailio_mcp_imap:search(A, #{
        mailboxes => [<<"INBOX">>]
    }),
    {error, {unavailable, authentication_failed}} = mailio_mcp_imap:search(A, #{
        mailboxes => [<<"INBOX">>]
    }),
    true = erlang:monotonic_time(millisecond) - T0 < 20000,
    ok.
