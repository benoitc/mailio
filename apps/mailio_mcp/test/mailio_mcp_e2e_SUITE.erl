%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% End-to-end tests: a real MCP client (barrel_mcp_client over Streamable
%%% HTTP, plus one stdio run) against the service, with GreenMail as the
%%% disposable mail server. Start it first: (cd test && docker compose up -d).
%%% Tool calls, response bytes and backend requests are written to
%%% e2e_trace.txt in the CT log directory.
-module(mailio_mcp_e2e_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    paris_invoices/1,
    changes_and_restart/1,
    changes_wait_for_mail/1,
    reply_from_alias/1,
    lost_smtp_ack/1,
    read_only_agent/1,
    pop3_adapter/1,
    stdio_smoke/1,
    costs/1
]).

all() ->
    [
        paris_invoices,
        changes_and_restart,
        changes_wait_for_mail,
        reply_from_alias,
        lost_smtp_ack,
        read_only_agent,
        pop3_adapter,
        stdio_smoke,
        costs
    ].

-define(DIR, "/tmp/mcp_e2e_data").

init_per_suite(Config) ->
    case mailio_mcp_lib:reachable(3143) andalso mailio_mcp_lib:reachable(3025) of
        false ->
            {skip, "GreenMail is not running (cd test && docker compose up -d)"};
        true ->
            {ok, _} = application:ensure_all_started(ssl),
            lists:foreach(fun purge/1, ["support", "carol", "bob", "alice"]),
            os:cmd("rm -rf " ++ ?DIR),
            Pdf = crypto:strong_rand_bytes(3000),
            [{pdf, Pdf} | Config]
    end.

end_per_suite(_) -> ok.

init_per_testcase(_, Config) ->
    ok = mailio_mcp_lib:start_app(?DIR, accounts(Config), principals()),
    mailio_mcp_lib:start_http(),
    Config.

end_per_testcase(Case, _Config) ->
    dump_trace(Case),
    mailio_mcp_lib:stop_http(),
    mailio_mcp_lib:stop_app(),
    mailio_mcp_lib:log_reset(),
    ok.

accounts(Config) ->
    Flaky =
        case proplists:get_value(flaky, Config) of
            undefined -> 3999;
            P -> P
        end,
    [
        mailio_mcp_lib:acct(
            <<"work1">>,
            <<"support">>,
            [{<<"support@example.test">>, <<"Support">>}, {<<"sales@example.test">>, <<"Sales">>}],
            #{}
        ),
        mailio_mcp_lib:acct(
            <<"work2">>, <<"carol">>, [{<<"carol@example.test">>, <<"Carol">>}], #{}
        ),
        %% a work account whose server is down
        mailio_mcp_lib:acct(
            <<"work3">>,
            <<"carol">>,
            [{<<"carol3@example.test">>, <<"Carol">>}],
            #{},
            #{incoming => #{protocol => imap, host => "127.0.0.1", port => 3999, tls => none}}
        ),
        %% an account whose SMTP server loses the final reply
        mailio_mcp_lib:acct(
            <<"flaky">>,
            <<"alice">>,
            [{<<"alice@example.test">>, <<"Alice">>}],
            #{},
            #{
                outgoing => #{host => "127.0.0.1", port => Flaky, tls => none},
                auth_out => #{
                    user => <<"alice">>, secret => {value, <<"secret">>}, mechanism => plain
                }
            }
        )
    ].

principals() ->
    [
        #{
            id => <<"assistant">>,
            grants => #{
                <<"work1">> => #{role => send, identities => all},
                <<"work2">> => #{role => draft, identities => all},
                <<"work3">> => #{role => read, identities => []},
                <<"flaky">> => #{role => send, identities => all}
            }
        },
        #{
            id => <<"reader">>,
            grants => #{<<"work2">> => #{role => read, identities => []}}
        }
    ].

purge(Login) ->
    C = mailio_mcp_lib:imap_conn(Login),
    case mailio_mcp_imap_io:cmd(C, [<<"SELECT INBOX">>]) of
        {ok, _, _} ->
            _ = mailio_mcp_imap_io:cmd(C, [<<"STORE 1:* +FLAGS (\\Deleted)">>]),
            _ = mailio_mcp_imap_io:cmd(C, [<<"EXPUNGE">>]);
        _ ->
            ok
    end,
    mailio_mcp_imap_io:close(C).

dump_trace(Case) ->
    Path = filename:join(proplists:get_value(priv_dir, ct:get_config(x, []), "/tmp"), "x"),
    _ = Path,
    {ok, Fd} = file:open("/tmp/e2e_trace.txt", [append]),
    io:format(Fd, "~n=== ~p ===~n", [Case]),
    lists:foreach(
        fun({Name, Args, Bytes, Backend, Ms, Out}) ->
            io:format(
                Fd,
                "~s ~s~n  response_bytes=~p backend=~p ms=~p~n  result=~s~n",
                [
                    Name,
                    short(json:encode(Args), 300),
                    Bytes,
                    Backend,
                    Ms,
                    short(result(Out), 400)
                ]
            )
        end,
        try
            mailio_mcp_lib:log()
        catch
            _:_ -> []
        end
    ),
    file:close(Fd).

result({ok, M}) -> json:encode(M);
result({error, T}) -> io_lib:format("ERROR ~s", [T]).

short(IoData, Max) ->
    B = iolist_to_binary(IoData),
    case byte_size(B) > Max of
        true -> <<(binary:part(B, 0, Max))/binary, "...">>;
        false -> B
    end.

%%====================================================================
%% Helpers

ok({ok, V}) -> V;
ok(Other) -> ct:fail({unexpected, Other}).

pdf_msg(Config, M) ->
    mailio_mcp_lib:msg(M#{
        attachment => {<<"invoice.pdf">>, <<"application/pdf">>, proplists:get_value(pdf, Config)}
    }).

seed(Login, Date, Raw) -> mailio_mcp_lib:append(Login, <<"INBOX">>, Date, <<>>, Raw).

hdate(Day, Time) -> iolist_to_binary(["Sun, ", Day, " Mar 2026 ", Time, " +0000"]).

subjects(Hits) -> [maps:get(<<"subject">>, H) || H <- Hits].

%%====================================================================
%% 1. Invoices with attachments, "yesterday" in Europe/Paris

paris_invoices(Config) ->
    purge("support"),
    purge("carol"),
    From = <<"billing@vendor.test">>,
    Mk = fun(Subj, Id, DateHdr, Att, To, Body) ->
        M = #{from => From, to => To, subject => Subj, msgid => Id, date => DateHdr, body => Body},
        case Att of
            true -> pdf_msg(Config, M);
            false -> mailio_mcp_lib:msg(M)
        end
    end,
    W1 = <<"support@example.test">>,
    %% 29 March 2026 is the Paris spring-forward day: local day = 23 hours
    seed(
        "support",
        <<"28-Mar-2026 22:59:00 +0000">>,
        Mk(
            <<"Invoice A before">>,
            <<"<a@v>">>,
            hdate(<<"28">>, <<"22:59:00">>),
            true,
            W1,
            <<"Please pay the invoice.\r\n">>
        )
    ),
    RawB = Mk(
        <<"Invoice B start">>,
        <<"<b@v>">>,
        hdate(<<"28">>, <<"23:00:00">>),
        true,
        W1,
        <<"Please pay the invoice.\r\n">>
    ),
    seed("support", <<"28-Mar-2026 23:00:00 +0000">>, RawB),
    seed(
        "support",
        <<"29-Mar-2026 10:00:00 +0000">>,
        Mk(
            <<"Invoice C no attachment">>,
            <<"<c@v>">>,
            hdate(<<"29">>, <<"10:00:00">>),
            false,
            W1,
            <<"Please pay the invoice.\r\n">>
        )
    ),
    seed(
        "support",
        <<"29-Mar-2026 12:00:00 +0000">>,
        Mk(
            <<"Holiday photos">>,
            <<"<p@v>">>,
            hdate(<<"29">>, <<"12:00:00">>),
            true,
            W1,
            <<"See attached.\r\n">>
        )
    ),
    seed(
        "support",
        <<"29-Mar-2026 21:59:00 +0000">>,
        Mk(
            <<"Invoice D late">>,
            <<"<d@v>">>,
            hdate(<<"29">>, <<"21:59:00">>),
            true,
            W1,
            <<"Please pay the invoice.\r\n">>
        )
    ),
    seed(
        "support",
        <<"29-Mar-2026 22:00:00 +0000">>,
        Mk(
            <<"Invoice E end">>,
            <<"<e@v>">>,
            hdate(<<"29">>, <<"22:00:00">>),
            true,
            W1,
            <<"Please pay the invoice.\r\n">>
        )
    ),
    %% work2: a copy of B (same message delivered to both mailboxes), one more
    %% invoice inside the day and one outside
    W2 = <<"carol@example.test">>,
    seed("carol", <<"28-Mar-2026 23:00:01 +0000">>, RawB),
    seed(
        "carol",
        <<"29-Mar-2026 08:00:00 +0000">>,
        Mk(
            <<"Invoice F carol">>,
            <<"<f@v>">>,
            hdate(<<"29">>, <<"08:00:00">>),
            true,
            W2,
            <<"Please pay the invoice.\r\n">>
        )
    ),
    seed(
        "carol",
        <<"29-Mar-2026 23:30:00 +0000">>,
        Mk(
            <<"Invoice G outside">>,
            <<"<g@v>">>,
            hdate(<<"29">>, <<"23:30:00">>),
            true,
            W2,
            <<"Please pay the invoice.\r\n">>
        )
    ),

    C = mailio_mcp_lib:client(<<"assistant">>),
    Accts = ok(mailio_mcp_lib:call(C, <<"accounts_list">>, #{})),
    4 = length(maps:get(<<"accounts">>, Accts)),

    Q = #{
        <<"account_ids">> => [<<"work1">>, <<"work2">>, <<"work3">>],
        <<"text">> => <<"invoice">>,
        <<"has_attachment">> => true,
        <<"on">> => <<"2026-03-29">>,
        <<"time_zone">> => <<"Europe/Paris">>,
        <<"fields">> => [<<"from">>, <<"subject">>, <<"date">>, <<"attachments">>, <<"copies">>]
    },
    R = ok(mailio_mcp_lib:call(C, <<"mail_search">>, Q)),
    Hits = maps:get(<<"hits">>, R),
    %% D (21:59Z), F (08:00Z), B (28th 23:00Z): A, C, E, G and the photos are out
    [<<"Invoice D late">>, <<"Invoice F carol">>, <<"Invoice B start">>] = subjects(Hits),
    3 = maps:get(<<"count">>, R),
    %% the offline account is reported, and the count is marked approximate
    true = maps:get(<<"count_approximate">>, R),
    [#{<<"account">> := <<"work3">>, <<"status">> := <<"offline">>}] = maps:get(<<"coverage">>, R),
    %% B exists in both accounts: one hit, both locations kept
    [B] = [H || H = #{<<"subject">> := <<"Invoice B start">>} <- Hits],
    [#{<<"account">> := Other}] = maps:get(<<"copies">>, B),
    true = lists:sort([maps:get(<<"account">>, B), Other]) =:= [<<"work1">>, <<"work2">>],
    true = byte_size(iolist_to_binary(json:encode(R))) =< 8192,

    %% warm: same search answered from cache, no backend request
    R2 = ok(mailio_mcp_lib:call(C, <<"mail_search">>, Q)),
    R2 = R#{<<"freshness">> := maps:get(<<"freshness">>, R2)},
    #{<<"source">> := <<"cache">>} = maps:get(<<"freshness">>, R2),
    {_, _, _, Backend, _, _} = lists:last(mailio_mcp_lib:log()),
    0 = maps:get(imap, Backend, 0),
    %% refresh goes back to the server
    _ = ok(mailio_mcp_lib:call(C, <<"mail_search">>, Q#{<<"refresh">> => true})),

    %% open only the matching attachment of D
    [D | _] = Hits,
    Msg = ok(mailio_mcp_lib:call(C, <<"mail_read">>, #{<<"handle">> => maps:get(<<"handle">>, D)})),
    [Att] = maps:get(<<"attachments">>, Msg),
    <<"invoice.pdf">> = maps:get(<<"name">>, Att),
    <<"application/pdf">> = maps:get(<<"type">>, Att),
    PartH = maps:get(<<"part_handle">>, Att),
    Part = ok(mailio_mcp_lib:call(C, <<"mail_read">>, #{<<"handle">> => PartH})),
    true = maps:get(<<"binary">>, Part),
    false = maps:is_key(<<"content_base64">>, Part),
    Part2 = ok(
        mailio_mcp_lib:call(C, <<"mail_read">>, #{
            <<"handle">> => PartH, <<"include_content">> => true
        })
    ),
    Pdf = proplists:get_value(pdf, Config),
    Pdf = base64:decode(maps:get(<<"content_base64">>, Part2)),
    %% and through the resource link
    {ok, Res} = barrel_mcp_client:read_resource(C, maps:get(<<"resource_uri">>, Att)),
    [#{<<"blob">> := Blob}] = maps:get(<<"contents">>, Res),
    Pdf = base64:decode(Blob),

    %% searching and reading never mark mail as read
    lists:foreach(
        fun(Uid) ->
            false = lists:member(<<"\\seen">>, mailio_mcp_lib:imap_flags("support", Uid))
        end,
        mailio_mcp_lib:imap_uids("support")
    ),
    ok.

%%====================================================================
%% 2. What changed since my last check, across a restart

changes_and_restart(_Config) ->
    purge("carol"),
    seed(
        "bob",
        <<"01-Apr-2026 10:00:00 +0000">>,
        mailio_mcp_lib:msg(#{
            from => <<"x@y.test">>, to => <<"bob@example.test">>, subject => <<"first">>
        })
    ),
    Q = #{<<"account_ids">> => [<<"work2">>], <<"mailbox">> => <<"INBOX">>},
    C = mailio_mcp_lib:client(<<"assistant">>),
    B0 = ok(mailio_mcp_lib:call(C, <<"mail_changes">>, Q)),
    Ck0 = maps:get(<<"checkpoint">>, B0),
    [<<"work2">>] = maps:get(<<"baseline">>, B0),
    %% a new message arrives
    seed(
        "carol",
        <<"02-Apr-2026 10:00:00 +0000">>,
        mailio_mcp_lib:msg(#{
            from => <<"x@y.test">>,
            to => <<"carol@example.test">>,
            subject => <<"fresh news">>,
            msgid => <<"<n1@y>">>
        })
    ),
    Ch1 = ok(mailio_mcp_lib:call(C, <<"mail_changes">>, Q#{<<"checkpoint">> => Ck0})),
    [#{<<"subject">> := <<"fresh news">>}] = maps:get(<<"added">>, Ch1),
    Ck1 = maps:get(<<"checkpoint">>, Ch1),
    false = (Ck0 =:= Ck1),
    Occ1 = length(mailio_mcp_store:all(occ)),
    %% restart the service, then replay the old checkpoint
    barrel_mcp_client:close(C),
    mailio_mcp_lib:stop_http(),
    mailio_mcp_lib:stop_app(),
    ok = mailio_mcp_lib:start_app(?DIR, accounts([]), principals()),
    mailio_mcp_lib:start_http(),
    C2 = mailio_mcp_lib:client(<<"assistant">>),
    Replay = ok(mailio_mcp_lib:call(C2, <<"mail_changes">>, Q#{<<"checkpoint">> => Ck0})),
    [#{<<"subject">> := <<"fresh news">>}] = maps:get(<<"added">>, Replay),
    %% the replay did not store the message again
    case length(mailio_mcp_store:all(occ)) of
        Occ1 -> ok;
        More -> ct:fail({replay_created_occurrences, Occ1, More})
    end,
    %% a repeat on the unchanged mailbox is small and returns the same checkpoint
    Same = ok(mailio_mcp_lib:call(C2, <<"mail_changes">>, Q#{<<"checkpoint">> => Ck1})),
    #{<<"unchanged">> := true, <<"checkpoint">> := Ck1} = Same,
    false = maps:is_key(<<"added">>, Same),
    {_, _, Bytes, _, _, _} = lists:last(mailio_mcp_lib:log()),
    true = Bytes < 200,
    %% a flag change and a removal are reported
    [Uid | _] = lists:reverse(mailio_mcp_lib:imap_uids("carol")),
    {ok, _, _} = mailio_mcp_lib:imap_cmd("carol", [<<"SELECT INBOX">>]) =:= x orelse {ok, [], []},
    C3 = mailio_mcp_lib:imap_conn("carol"),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C3, [<<"SELECT INBOX">>]),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C3, [
        <<"UID STORE ">>, integer_to_binary(Uid), <<" +FLAGS (\\Seen)">>
    ]),
    mailio_mcp_imap_io:close(C3),
    Upd = ok(mailio_mcp_lib:call(C2, <<"mail_changes">>, Q#{<<"checkpoint">> => Ck1})),
    [#{<<"unread">> := false}] = maps:get(<<"updated">>, Upd),
    Ck2 = maps:get(<<"checkpoint">>, Upd),
    C4 = mailio_mcp_lib:imap_conn("carol"),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C4, [<<"SELECT INBOX">>]),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C4, [
        <<"UID STORE ">>, integer_to_binary(Uid), <<" +FLAGS (\\Deleted)">>
    ]),
    {ok, _, _} = mailio_mcp_imap_io:cmd(C4, [<<"EXPUNGE">>]),
    mailio_mcp_imap_io:close(C4),
    Rem = ok(mailio_mcp_lib:call(C2, <<"mail_changes">>, Q#{<<"checkpoint">> => Ck2})),
    1 = length(maps:get(<<"removed">>, Rem)),
    %% a made-up checkpoint is refused with a way forward
    {error, Text} = mailio_mcp_lib:call(C2, <<"mail_changes">>, Q#{
        <<"checkpoint">> => <<"nonsense">>
    }),
    true = binary:match(Text, <<"without a checkpoint">>) =/= nomatch,
    ok.

%%====================================================================
%% 2b. Wait for the next change instead of polling

changes_wait_for_mail(_Config) ->
    purge("carol"),
    C = mailio_mcp_lib:client(<<"assistant">>),
    Q = #{<<"account_ids">> => [<<"work2">>]},
    %% the baseline returns at once, whatever wait_seconds says
    {Base, BaseMs} = timed(fun() ->
        ok(mailio_mcp_lib:call(C, <<"mail_changes">>, Q#{<<"wait_seconds">> => 20}))
    end),
    true = BaseMs < 5000,
    false = maps:is_key(<<"waited">>, Base),
    Ck = maps:get(<<"checkpoint">>, Base),
    %% nothing arrives: the call waits its time and says so, with the same checkpoint
    {Quiet, QuietMs} = timed(fun() ->
        ok(
            mailio_mcp_lib:call(C, <<"mail_changes">>, Q#{
                <<"checkpoint">> => Ck, <<"wait_seconds">> => 2
            })
        )
    end),
    true = QuietMs >= 1800,
    true = QuietMs < 8000,
    #{<<"seconds">> := 2, <<"result">> := <<"timeout">>} = maps:get(<<"waited">>, Quiet),
    #{<<"unchanged">> := true, <<"checkpoint">> := Ck} = Quiet,
    %% mail arrives from another connection while the call waits: it returns
    %% as soon as the server says so, with the new message
    spawn_link(fun() ->
        timer:sleep(1500),
        seed(
            "carol",
            <<"20-Apr-2026 10:00:00 +0000">>,
            mailio_mcp_lib:msg(#{
                from => <<"x@y.test">>,
                to => <<"carol@example.test">>,
                subject => <<"pushed">>,
                msgid => <<"<w1@y>">>
            })
        )
    end),
    {Woken, WokenMs} = timed(fun() ->
        ok(
            mailio_mcp_lib:call(C, <<"mail_changes">>, Q#{
                <<"checkpoint">> => Ck, <<"wait_seconds">> => 20
            })
        )
    end),
    true = WokenMs < 12000,
    #{<<"result">> := <<"changed">>} = maps:get(<<"waited">>, Woken),
    [#{<<"subject">> := <<"pushed">>}] = maps:get(<<"added">>, Woken),
    false = (maps:get(<<"checkpoint">>, Woken) =:= Ck),
    ok.

timed(Fun) ->
    T0 = erlang:monotonic_time(millisecond),
    R = Fun(),
    {R, erlang:monotonic_time(millisecond) - T0}.

%%====================================================================
%% 3. Read the latest reply of a long thread, draft from the support alias

thread_msgs(N) ->
    Ids = [iolist_to_binary(["<t", integer_to_list(I), "@thread.test>"]) || I <- lists:seq(1, N)],
    lists:map(
        fun(I) ->
            Id = lists:nth(I, Ids),
            Refs = lists:sublist(Ids, I - 1),
            M = #{
                from => <<"Bob <bob@example.test>">>,
                to => <<"support@example.test">>,
                subject => <<"Re: printer on fire">>,
                msgid => Id,
                body => iolist_to_binary([
                    "Message number ",
                    integer_to_list(I),
                    ".\r\n\r\nOn Mon, 1 Jan 2026, Support wrote:\r\n> earlier text\r\n"
                ]),
                date => iolist_to_binary([
                    "Mon, 1 Jun 2026 ", io_lib:format("~2..0w", [I]), ":00:00 +0000"
                ])
            },
            M2 =
                case Refs of
                    [] ->
                        M;
                    _ ->
                        M#{
                            in_reply_to => lists:last(Refs),
                            references => iolist_to_binary(lists:join(<<" ">>, Refs))
                        }
                end,
            {I, Id, mailio_mcp_lib:msg(M2)}
        end,
        lists:seq(1, N)
    ).

reply_from_alias(_Config) ->
    purge("support"),
    Msgs = thread_msgs(12),
    lists:foreach(
        fun({I, _, Raw}) ->
            seed(
                "support",
                iolist_to_binary(["01-Jun-2026 ", io_lib:format("~2..0w", [I]), ":00:00 +0000"]),
                Raw
            )
        end,
        Msgs
    ),
    C = mailio_mcp_lib:client(<<"assistant">>),
    S = ok(
        mailio_mcp_lib:call(C, <<"mail_search">>, #{
            <<"account_ids">> => [<<"work1">>], <<"subject">> => <<"printer">>
        })
    ),
    12 = maps:get(<<"count">>, S),
    Any = maps:get(<<"handle">>, hd(maps:get(<<"hits">>, S))),
    T = ok(
        mailio_mcp_lib:call(C, <<"mail_read">>, #{
            <<"handle">> => Any, <<"mode">> => <<"thread">>, <<"expand">> => <<"latest">>
        })
    ),
    12 = maps:get(<<"message_count">>, T),
    true = byte_size(iolist_to_binary(json:encode(T))) =< 8192,
    Latest = maps:get(<<"latest_message">>, T),
    %% quoted history is hidden by default
    #{<<"content_untrusted">> := Text} = maps:get(<<"text">>, Latest),
    <<"Message number 12.">> = Text,
    LatestH = maps:get(<<"latest">>, T),
    %% the unread flag is untouched
    lists:foreach(
        fun(Uid) ->
            false = lists:member(<<"\\seen">>, mailio_mcp_lib:imap_flags("support", Uid))
        end,
        mailio_mcp_lib:imap_uids("support")
    ),
    Before = mailio_mcp_lib:gm_count("bob", <<"INBOX">>),
    %% draft: the account and the support alias come from the message itself
    Dr = ok(
        mailio_mcp_lib:call(C, <<"draft_save">>, #{
            <<"reply_to">> => LatestH, <<"body">> => <<"We are on it.">>
        })
    ),
    <<"work1">> = maps:get(<<"account">>, Dr),
    <<"Support <support@example.test>">> = maps:get(<<"from">>, Dr),
    [<<"bob@example.test">>] = maps:get(<<"to">>, Dr),
    <<"<t12@thread.test>">> = maps:get(<<"in_reply_to">>, Dr),
    <<"Re: printer on fire">> = maps:get(<<"subject">>, Dr),
    Id = maps:get(<<"draft_id">>, Dr),
    Rev = maps:get(<<"revision">>, Dr),
    %% changing the sender is explicit and limited to your identities
    {error, _} = mailio_mcp_lib:call(C, <<"draft_save">>, #{
        <<"draft_id">> => Id, <<"from">> => <<"ceo@example.test">>
    }),
    %% nothing was sent by saving
    Before = mailio_mcp_lib:gm_count("bob", <<"INBOX">>),
    %% six concurrent sends with the same key: one message, one recorded status
    Parent = self(),
    Args = #{<<"draft_id">> => Id, <<"revision">> => Rev, <<"idempotency_key">> => <<"send-1">>},
    Pids = [
        spawn_link(fun() -> Parent ! {self(), mailio_mcp_lib:call(C, <<"draft_send">>, Args)} end)
     || _ <- lists:seq(1, 6)
    ],
    Results = [
        receive
            {P, R} -> R
        after 60000 -> timeout
        end
     || P <- Pids
    ],
    [First | Rest] = [ok(R) || R <- Results],
    <<"accepted">> = maps:get(<<"status">>, First),
    <<"unknown">> = maps:get(<<"delivered">>, First),
    true = lists:all(fun(X) -> X =:= First end, Rest),
    timer:sleep(300),
    Before1 = Before + 1,
    Before1 = mailio_mcp_lib:gm_count("bob", <<"INBOX">>),
    %% the message on the wire: sender, threading headers
    BobC = mailio_mcp_lib:imap_conn("bob"),
    {ok, _, _} = mailio_mcp_imap_io:cmd(BobC, [<<"EXAMINE INBOX">>]),
    {ok, U, _} = mailio_mcp_imap_io:cmd(BobC, [<<"UID FETCH * (BODY.PEEK[HEADER])">>]),
    mailio_mcp_imap_io:close(BobC),
    [Hdr | _] = [V || {fetch, _, Items} <- U, {<<"BODY[HEADER]">>, V} <- Items],
    true = binary:match(Hdr, <<"Support <support@example.test>">>) =/= nomatch,
    true = binary:match(Hdr, <<"In-Reply-To: <t12@thread.test>">>) =/= nomatch,
    true = binary:match(Hdr, <<"<t1@thread.test> <t2@thread.test>">>) =/= nomatch,
    true = binary:match(Hdr, <<"<t12@thread.test>">>) =/= nomatch,
    %% another key for the same revision does not send again
    {error, Dup} = mailio_mcp_lib:call(C, <<"draft_send">>, Args#{
        <<"idempotency_key">> => <<"send-2">>
    }),
    true = binary:match(Dup, <<"already submitted">>) =/= nomatch,
    %% the same key with different content is refused
    {error, _} = mailio_mcp_lib:call(C, <<"draft_send">>, Args#{<<"draft_id">> => <<"d_other">>}),
    Before1 = mailio_mcp_lib:gm_count("bob", <<"INBOX">>),
    ok.

%%====================================================================
%% 3b. SMTP connection lost after the body was sent

lost_smtp_ack(Config) ->
    Fake = mailio_mcp_lib:fake_smtp(drop_after_data),
    mailio_mcp_lib:stop_http(),
    mailio_mcp_lib:stop_app(),
    ok = mailio_mcp_lib:start_app(
        ?DIR, accounts([{flaky, maps:get(port, Fake)} | Config]), principals()
    ),
    mailio_mcp_lib:start_http(),
    C = mailio_mcp_lib:client(<<"assistant">>),
    Dr = ok(
        mailio_mcp_lib:call(C, <<"draft_save">>, #{
            <<"account_ids">> => [<<"flaky">>],
            <<"to">> => [<<"bob@example.test">>],
            <<"subject">> => <<"hello">>,
            <<"body">> => <<"Hi.">>
        })
    ),
    Id = maps:get(<<"draft_id">>, Dr),
    Rev = maps:get(<<"revision">>, Dr),
    Args = #{<<"draft_id">> => Id, <<"revision">> => Rev, <<"idempotency_key">> => <<"k-lost">>},
    S1 = ok(mailio_mcp_lib:call(C, <<"draft_send">>, Args)),
    <<"outcome_unknown">> = maps:get(<<"status">>, S1),
    true = binary:match(maps:get(<<"note">>, S1), <<"will not be resent">>) =/= nomatch,
    1 = mailio_mcp_lib:fake_smtp_data_count(Fake),
    %% retry with the same key: the recorded status, no second submission
    S2 = ok(mailio_mcp_lib:call(C, <<"draft_send">>, Args)),
    S1 = S2,
    %% a fresh key does not resend either
    {error, _} = mailio_mcp_lib:call(C, <<"draft_send">>, Args#{
        <<"idempotency_key">> => <<"k-new">>
    }),
    %% the draft is locked
    {error, Locked} = mailio_mcp_lib:call(C, <<"draft_save">>, #{
        <<"draft_id">> => Id, <<"body">> => <<"changed">>
    }),
    true = binary:match(Locked, <<"already submitted">>) =/= nomatch,
    1 = mailio_mcp_lib:fake_smtp_data_count(Fake),
    %% a restart keeps the record
    mailio_mcp_lib:stop_http(),
    mailio_mcp_lib:stop_app(),
    ok = mailio_mcp_lib:start_app(
        ?DIR, accounts([{flaky, maps:get(port, Fake)} | Config]), principals()
    ),
    mailio_mcp_lib:start_http(),
    C2 = mailio_mcp_lib:client(<<"assistant">>),
    S3 = ok(mailio_mcp_lib:call(C2, <<"draft_send">>, Args)),
    S1 = S3,
    1 = mailio_mcp_lib:fake_smtp_data_count(Fake),
    mailio_mcp_lib:fake_smtp_stop(Fake),
    ok.

%%====================================================================
%% 4. A read-only agent on one account

read_only_agent(Config) ->
    purge("support"),
    purge("carol"),
    %% data from the earlier cases: work1 and work2 both hold a copy of "Invoice B"
    Pdf = proplists:get_value(pdf, Config),
    Raw = mailio_mcp_lib:msg(#{
        from => <<"billing@vendor.test">>,
        to => <<"carol@example.test">>,
        subject => <<"Invoice B start">>,
        msgid => <<"<b@v>">>,
        date => hdate(<<"28">>, <<"23:00:00">>),
        body => <<"Please pay the invoice.\r\n">>,
        attachment => {<<"invoice.pdf">>, <<"application/pdf">>, Pdf}
    }),
    seed("support", <<"28-Mar-2026 23:00:00 +0000">>, Raw),
    seed("carol", <<"28-Mar-2026 23:00:01 +0000">>, Raw),
    seed(
        "support",
        <<"30-Mar-2026 09:00:00 +0000">>,
        mailio_mcp_lib:msg(#{
            from => <<"a@v.test">>, to => <<"support@example.test">>, subject => <<"Invoice X">>
        })
    ),
    seed(
        "carol",
        <<"30-Mar-2026 09:30:00 +0000">>,
        mailio_mcp_lib:msg(#{
            from => <<"a@v.test">>, to => <<"carol@example.test">>, subject => <<"Invoice Y">>
        })
    ),
    Boss = mailio_mcp_lib:client(<<"assistant">>),
    Rd = mailio_mcp_lib:client(<<"reader">>),
    %% what the reader can see
    #{<<"accounts">> := [Only]} = ok(mailio_mcp_lib:call(Rd, <<"accounts_list">>, #{})),
    <<"work2">> = maps:get(<<"id">>, Only),
    #{<<"can_send">> := false, <<"can_draft">> := false} = maps:get(<<"capabilities">>, Only),
    %% omitting account_ids works because exactly one account is visible
    Own = ok(
        mailio_mcp_lib:call(Rd, <<"mail_search">>, #{
            <<"subject">> => <<"Invoice">>, <<"limit">> => 1
        })
    ),
    [<<"work2">>] = maps:get(<<"accounts_searched">>, Own),
    %% an account that exists and one that does not give the same answer
    {error, E1} = mailio_mcp_lib:call(Rd, <<"mail_search">>, #{<<"account_ids">> => [<<"work1">>]}),
    {error, E2} = mailio_mcp_lib:call(Rd, <<"mail_search">>, #{
        <<"account_ids">> => [<<"nonexistent">>]
    }),
    E1 = E2,
    {error, E3} = mailio_mcp_lib:call(Rd, <<"mail_changes">>, #{<<"account_ids">> => [<<"work1">>]}),
    E1 = E3,
    {error, E4} = mailio_mcp_lib:call(Rd, <<"mailboxes_list">>, #{
        <<"account_ids">> => [<<"work1">>]
    }),
    E1 = E4,
    %% "all" means all authorized: counts and copy groups cover only work2
    All = ok(
        mailio_mcp_lib:call(Rd, <<"mail_search">>, #{
            <<"account_ids">> => <<"all">>,
            <<"subject">> => <<"Invoice">>,
            <<"count_only">> => true
        })
    ),
    OnlyW2 = ok(
        mailio_mcp_lib:call(Boss, <<"mail_search">>, #{
            <<"account_ids">> => [<<"work2">>],
            <<"subject">> => <<"Invoice">>,
            <<"count_only">> => true
        })
    ),
    maps:get(<<"count">>, All) =:= maps:get(<<"count">>, OnlyW2) orelse ct:fail(count_leak),
    Both = ok(
        mailio_mcp_lib:call(Boss, <<"mail_search">>, #{
            <<"account_ids">> => [<<"work1">>, <<"work2">>],
            <<"subject">> => <<"Invoice B">>,
            <<"fields">> => [<<"subject">>]
        })
    ),
    [_] = maps:get(<<"hits">>, Both),
    [#{<<"copies">> := [_]}] = maps:get(<<"hits">>, Both),
    RdB = ok(
        mailio_mcp_lib:call(Rd, <<"mail_search">>, #{
            <<"subject">> => <<"Invoice B">>, <<"fields">> => [<<"subject">>]
        })
    ),
    [Hit] = maps:get(<<"hits">>, RdB),
    false = maps:is_key(<<"copies">>, Hit),
    %% a cursor made for the assistant is useless to the reader
    Page = ok(
        mailio_mcp_lib:call(Boss, <<"mail_search">>, #{
            <<"account_ids">> => [<<"work1">>, <<"work2">>],
            <<"limit">> => 1,
            <<"subject">> => <<"Invoice">>
        })
    ),
    Cursor = maps:get(<<"next_cursor">>, Page),
    {error, EC} = mailio_mcp_lib:call(Rd, <<"mail_search">>, #{
        <<"subject">> => <<"Invoice">>, <<"cursor">> => Cursor
    }),
    true = binary:match(EC, <<"Invalid cursor">>) =/= nomatch,
    %% handles minted for the assistant on work1: message, part, resource
    W1 = ok(
        mailio_mcp_lib:call(Boss, <<"mail_search">>, #{
            <<"account_ids">> => [<<"work1">>], <<"subject">> => <<"Invoice B">>
        })
    ),
    [#{<<"handle">> := H1}] = maps:get(<<"hits">>, W1),
    {error, EH} = mailio_mcp_lib:call(Rd, <<"mail_read">>, #{<<"handle">> => H1}),
    true = binary:match(EH, <<"Invalid or expired handle">>) =/= nomatch,
    Msg = ok(mailio_mcp_lib:call(Boss, <<"mail_read">>, #{<<"handle">> => H1})),
    [Att] = maps:get(<<"attachments">>, Msg),
    {error, EP} = mailio_mcp_lib:call(Rd, <<"mail_read">>, #{
        <<"handle">> => maps:get(<<"part_handle">>, Att)
    }),
    EH = EP,
    {error, _} = barrel_mcp_client:read_resource(Rd, maps:get(<<"resource_uri">>, Att)),
    {ok, _} = barrel_mcp_client:read_resource(Boss, maps:get(<<"resource_uri">>, Att)),
    %% no drafting or sending
    {error, ED} = mailio_mcp_lib:call(Rd, <<"draft_save">>, #{
        <<"to">> => [<<"x@y.test">>], <<"body">> => <<"hi">>
    }),
    true = binary:match(ED, <<"may not">>) =/= nomatch,
    {error, _} = mailio_mcp_lib:call(Rd, <<"draft_send">>, #{
        <<"draft_id">> => <<"d_1">>, <<"revision">> => 1, <<"idempotency_key">> => <<"k">>
    }),
    %% the assistant has only the draft role on work2: it can draft there but not send
    Dr = ok(
        mailio_mcp_lib:call(Boss, <<"draft_save">>, #{
            <<"account_ids">> => [<<"work2">>],
            <<"to">> => [<<"x@y.test">>],
            <<"subject">> => <<"s">>,
            <<"body">> => <<"b">>
        })
    ),
    {error, ES} = mailio_mcp_lib:call(Boss, <<"draft_send">>, #{
        <<"draft_id">> => maps:get(<<"draft_id">>, Dr),
        <<"revision">> => 1,
        <<"idempotency_key">> => <<"k">>
    }),
    true = binary:match(ES, <<"send role">>) =/= nomatch,
    %% the reader cannot use the assistant's draft
    {error, _} = mailio_mcp_lib:call(Rd, <<"draft_save">>, #{
        <<"draft_id">> => maps:get(<<"draft_id">>, Dr), <<"body">> => <<"x">>
    }),
    ok.

%%====================================================================
%% POP3

pop3_adapter(_Config) ->
    Pop = mailio_mcp_lib:acct(
        <<"pop">>,
        <<"bob">>,
        [{<<"bob@example.test">>, <<"Bob">>}],
        #{},
        #{incoming => #{protocol => pop3, host => "127.0.0.1", port => 3110, tls => none}}
    ),
    mailio_mcp_lib:stop_http(),
    mailio_mcp_lib:stop_app(),
    ok = mailio_mcp_lib:start_app(?DIR, [Pop], undefined),
    mailio_mcp_lib:start_http(),
    Pdf = crypto:strong_rand_bytes(1500),
    mailio_mcp_lib:smtp_send(
        <<"a@vendor.test">>,
        <<"bob@example.test">>,
        mailio_mcp_lib:msg(#{
            from => <<"a@vendor.test">>,
            to => <<"bob@example.test">>,
            subject => <<"Pop invoice">>,
            body => <<"Pay.\r\n">>,
            attachment => {<<"inv.pdf">>, <<"application/pdf">>, Pdf},
            date => <<"Mon, 30 Mar 2026 10:00:00 +0000">>
        })
    ),
    mailio_mcp_lib:smtp_send(
        <<"a@vendor.test">>,
        <<"bob@example.test">>,
        mailio_mcp_lib:msg(#{
            from => <<"a@vendor.test">>,
            to => <<"bob@example.test">>,
            subject => <<"Pop hello">>,
            body => <<"Hello.\r\n">>,
            date => <<"Mon, 30 Mar 2026 11:00:00 +0000">>
        })
    ),
    C = mailio_mcp_lib:client(<<"anyone">>),
    Caps = ok(mailio_mcp_lib:call(C, <<"accounts_list">>, #{<<"discover">> => true})),
    [#{<<"capabilities">> := #{<<"protocol">> := <<"pop3">>, <<"time_bases">> := Bases}}] = maps:get(
        <<"accounts">>, Caps
    ),
    [<<"sent_at">>, <<"first_seen_at">>] = Bases,
    %% sent_at works, found by header text; the attachment indicator comes from Content-Type
    R = ok(
        mailio_mcp_lib:call(C, <<"mail_search">>, #{
            <<"subject">> => <<"Pop">>,
            <<"time_basis">> => <<"sent_at">>,
            <<"on">> => <<"2026-03-30">>,
            <<"time_zone">> => <<"Europe/Paris">>,
            <<"has_attachment">> => true
        })
    ),
    [#{<<"subject">> := <<"Pop invoice">>, <<"unread">> := null}] = maps:get(<<"hits">>, R),
    %% what POP3 cannot do is refused or reported, not silently ignored
    U = ok(mailio_mcp_lib:call(C, <<"mail_search">>, #{<<"unread">> => true})),
    [#{<<"status">> := <<"unsupported">>}] = maps:get(<<"coverage">>, U),
    Rb = ok(
        mailio_mcp_lib:call(C, <<"mail_search">>, #{
            <<"on">> => <<"2026-03-30">>, <<"time_zone">> => <<"Europe/Paris">>
        })
    ),
    [#{<<"status">> := <<"unsupported">>, <<"note">> := Note}] = maps:get(<<"coverage">>, Rb),
    true = binary:match(Note, <<"sent_at">>) =/= nomatch,
    %% read and open the attachment
    [#{<<"handle">> := H}] = maps:get(<<"hits">>, R),
    Msg = ok(mailio_mcp_lib:call(C, <<"mail_read">>, #{<<"handle">> => H})),
    [Att] = maps:get(<<"attachments">>, Msg),
    P = ok(
        mailio_mcp_lib:call(C, <<"mail_read">>, #{
            <<"handle">> => maps:get(<<"part_handle">>, Att), <<"include_content">> => true
        })
    ),
    Pdf = base64:decode(maps:get(<<"content_base64">>, P)),
    %% the mail is still on the server
    true = mailio_mcp_lib:gm_count("bob", <<"INBOX">>) >= 2,
    %% changes by UIDL
    B = ok(mailio_mcp_lib:call(C, <<"mail_changes">>, #{})),
    Ck = maps:get(<<"checkpoint">>, B),
    mailio_mcp_lib:smtp_send(
        <<"a@vendor.test">>,
        <<"bob@example.test">>,
        mailio_mcp_lib:msg(#{
            from => <<"a@vendor.test">>, to => <<"bob@example.test">>, subject => <<"Pop third">>
        })
    ),
    timer:sleep(300),
    Ch = ok(mailio_mcp_lib:call(C, <<"mail_changes">>, #{<<"checkpoint">> => Ck})),
    [#{<<"subject">> := <<"Pop third">>}] = maps:get(<<"added">>, Ch),
    Same = ok(
        mailio_mcp_lib:call(C, <<"mail_changes">>, #{
            <<"checkpoint">> => maps:get(<<"checkpoint">>, Ch)
        })
    ),
    #{<<"unchanged">> := true} = Same,
    %% POP3 has no push: asking to wait returns at once and says why
    {PopWait, PopMs} = timed(fun() ->
        ok(
            mailio_mcp_lib:call(C, <<"mail_changes">>, #{
                <<"checkpoint">> => maps:get(<<"checkpoint">>, Ch), <<"wait_seconds">> => 10
            })
        )
    end),
    true = PopMs < 5000,
    #{<<"result">> := <<"unsupported">>} = maps:get(<<"waited">>, PopWait),
    %% a reused UIDL gets an ordinal so both copies keep an identity
    [{1, <<"u1">>}, {2, <<"u1#1">>}, {3, <<"u2">>}] = mailio_pop3:unique_ids([
        {1, <<"u1">>}, {2, <<"u1">>}, {3, <<"u2">>}
    ]),
    ok.

%%====================================================================
%% stdio transport, as an MCP host would start it

stdio_smoke(_Config) ->
    CfgFile = "/tmp/mcp_stdio.config",
    Acc = (mailio_mcp_lib:acct(
        <<"work">>, <<"carol">>, [{<<"carol@example.test">>, <<"Carol">>}], #{}
    ))#{
        auth => #{user => <<"carol">>, mechanism => login, secret => {env, "BEA_PW"}}
    },
    ok = file:write_file(
        CfgFile,
        io_lib:format(
            "[{mailio_mcp, [{data_dir, \"/tmp/mcp_stdio_data\"}, {accounts, [~p]}]}].~n", [
                Acc
            ]
        )
    ),
    Bin = filename:join(
        find_root(proplists:get_value(data_dir, _Config)), "apps/mailio_mcp/bin/mailio-mcp"
    ),
    {ok, C} = barrel_mcp_client:start_link(#{
        transport =>
            {stdio, #{
                command => Bin,
                args => ["stdio"],
                env => [{"MAILIO_MCP_CONFIG", CfgFile}, {"BEA_PW", "secret"}]
            }},
        request_timeout => 60000
    }),
    wait(C, 100),
    {ok, Tools} = barrel_mcp_client:list_tools(C),
    Names = lists:sort([maps:get(<<"name">>, T) || T <- Tools]),
    [
        <<"accounts_list">>,
        <<"draft_save">>,
        <<"draft_send">>,
        <<"mail_changes">>,
        <<"mail_read">>,
        <<"mail_search">>,
        <<"mailboxes_list">>
    ] = Names,
    %% no principals configured: the single account is used without account_ids
    {ok, #{<<"content">> := [#{<<"text">> := T1}]}} = barrel_mcp_client:call_tool(
        C, <<"mailboxes_list">>, #{}
    ),
    #{<<"accounts">> := [#{<<"mailboxes">> := [_ | _]}]} = json:decode(T1),
    {ok, #{<<"content">> := [#{<<"text">> := T2}]}} = barrel_mcp_client:call_tool(
        C, <<"mail_search">>, #{<<"subject">> => <<"zzzz-none">>}
    ),
    #{<<"count">> := 0} = json:decode(T2),
    barrel_mcp_client:close(C),
    ok.

find_root(Dir) ->
    case filelib:is_file(filename:join(Dir, "apps/mailio_mcp/bin/mailio-mcp")) of
        true ->
            Dir;
        false ->
            Up = filename:dirname(string:trim(Dir, trailing, "/")),
            case Up =:= Dir of
                true -> ct:fail(no_project_root);
                false -> find_root(Up)
            end
    end.

wait(_, 0) ->
    ct:fail(not_ready);
wait(C, N) ->
    case barrel_mcp_client:server_capabilities(C) of
        {ok, _} ->
            ok;
        _ ->
            timer:sleep(100),
            wait(C, N - 1)
    end.

%%====================================================================
%% Catalog size and the cost of cold / warm / unchanged

costs(_Config) ->
    C = mailio_mcp_lib:client(<<"assistant">>),
    {ok, Tools} = barrel_mcp_client:list_tools(C),
    CatalogBytes = iolist_size(json:encode(Tools)),
    Q = #{
        <<"account_ids">> => [<<"work2">>],
        <<"text">> => <<"invoice">>,
        <<"has_attachment">> => true,
        <<"on">> => <<"2026-03-29">>,
        <<"time_zone">> => <<"Europe/Paris">>
    },
    Cold = measure(C, <<"mail_search">>, Q#{<<"refresh">> => true}),
    Warm = measure(C, <<"mail_search">>, Q),
    Ck = maps:get(
        <<"checkpoint">>,
        ok(mailio_mcp_lib:call(C, <<"mail_changes">>, #{<<"account_ids">> => [<<"work2">>]}))
    ),
    Poll = measure(C, <<"mail_changes">>, #{
        <<"account_ids">> => [<<"work2">>], <<"checkpoint">> => Ck
    }),
    Report = io_lib:format(
        "catalog_bytes=~p tools=~p~ncold=~p~nwarm=~p~nunchanged_poll=~p~n",
        [CatalogBytes, length(Tools), Cold, Warm, Poll]
    ),
    ok = file:write_file("/tmp/e2e_costs.txt", Report),
    ct:pal("~s", [Report]),
    true = CatalogBytes < 12000,
    #{imap := 0} = maps:merge(#{imap => 0}, maps:with([imap], element(2, Warm))),
    ok.

measure(C, Name, Args) ->
    _ = ok(mailio_mcp_lib:call(C, Name, Args)),
    {_, _, Bytes, Backend, Ms, _} = lists:last(mailio_mcp_lib:log()),
    {response_bytes, Backend, Ms, Bytes}.
