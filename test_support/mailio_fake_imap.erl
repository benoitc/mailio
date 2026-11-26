%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Scripted fake IMAP server for adapter and sync tests.
%%%
%%% Implements enough of IMAP4rev1 + CONDSTORE/QRESYNC + IDLE to drive the
%%% adapter and sync engine end to end over a real socket: greeting,
%%% CAPABILITY, LOGIN, ENABLE, LIST, SELECT (plain and QRESYNC), UID FETCH
%%% (metadata, BODY.PEEK[], CHANGEDSINCE), UID STORE, IDLE/DONE, NOOP,
%%% LOGOUT. Messages carry a MODSEQ; expunged UIDs are remembered with the
%%% MODSEQ at which they vanished so a QRESYNC SELECT can replay VANISHED.
%%% Control messages let a test change flags, deliver new mail, and expunge.
%%% Not a conformant server — a test double.
-module(mailio_fake_imap).

-export([start/0, start/1, stop/1, port/1, commands/1]).
-export([last_flags/2, set_flags/3, deliver/2, expunge/2, new_validity/2, set_failure/3]).
-export([set_option/3, inject/2, set_uidnext/2, set_search/2, drop_connection/1, set_capabilities/2]).

-record(srv, {port, pid, ref, tab}).

%% {Seq, Uid, FlagsList, ModSeq, Raw}
messages() ->
    [
        {1, 100, [<<"\\Seen">>], 5, msg(<<"m100@x">>, <<"First message">>)},
        {2, 101, [], 6, msg(<<"m101@x">>, <<"Second message">>)}
    ].

msg(Id, Subject) ->
    <<"From: sender@example.com\r\n", "To: me@example.com\r\n", "Subject: ", Subject/binary, "\r\n",
        "Message-ID: <", Id/binary, ">\r\n", "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\n",
        "Content-Type: text/plain; charset=utf-8\r\n", "\r\n", "Body of ", Subject/binary,
        ".\r\n">>.

%%====================================================================
%% Control
%%====================================================================

start() -> start(#{}).

start(Opts) ->
    {ok, LSock} = gen_tcp:listen(maps:get(port, Opts, 0), [
        binary,
        {active, false},
        {packet, line},
        {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(LSock),
    Ref = make_ref(),
    Tab = ets:new(fake_imap_log, [public, ordered_set]),
    Pid = spawn(fun() -> accept_loop(LSock, Opts#{log => Tab}, Ref, init_state()) end),
    #srv{port = Port, pid = Pid, ref = Ref, tab = Tab}.

stop(#srv{pid = Pid}) ->
    exit(Pid, shutdown),
    ok.

port(#srv{port = Port}) -> Port.

%% @doc Every command the server received, in order, as binaries.
commands(#srv{tab = Tab}) -> [C || {_, C} <- ets:tab2list(Tab)].

last_flags(Srv, Uid) -> call(Srv, {get_flags, Uid}, flags).

set_flags(Srv, Uid, Flags) -> call(Srv, {set_flags, Uid, Flags}, ok).

%% @doc Deliver a new message to INBOX (uid auto-assigned).
deliver(Srv, Subject) -> call(Srv, {deliver, Subject}, ok).

%% @doc Expunge a message by uid.
expunge(Srv, Uid) -> call(Srv, {expunge, Uid}, ok).

%% @doc Make a kind of UID FETCH answer `NO': `meta' (the listing of UIDs and
%% flags), `body' (a message body) or `{body, Uid}' (the body of one message).
set_failure(Srv, Kind, Bool) when
    Kind =:= meta; Kind =:= body; (is_tuple(Kind) andalso element(1, Kind) =:= body)
->
    call(Srv, {set_failure, Kind, Bool}, ok).

%% @doc Server behaviour switches: `no_uidnext' (EXAMINE does not report UIDNEXT,
%% which RFC 3501 allows), `fail_max_uid' (UID FETCH * answers NO) and
%% `bad_vanished' (a QRESYNC answer with a VANISHED line that lists nothing) and
%% `no_exists' (EXAMINE does not report EXISTS), `zero_max_uid' (UID FETCH *
%% answers with UID 0), `fail_flags_fetch' (FETCH 1:* answers NO), `enforce_enable' (a QRESYNC parameter
%% on SELECT or EXAMINE is BAD unless this connection sent ENABLE QRESYNC) and `bad_validity' (UIDVALIDITY 01). `set_search/2' makes UID SEARCH
%% answer badly.
set_option(Srv, Option, Bool) when
    Option =:= no_uidnext;
    Option =:= no_exists;
    Option =:= fail_max_uid;
    Option =:= zero_max_uid;
    Option =:= fail_flags_fetch;
    Option =:= enforce_enable;
    Option =:= preauth_greeting;
    Option =:= empty_enabled;
    Option =:= bad_validity;
    Option =:= bad_vanished
->
    call(Srv, {set_option, Option, Bool}, ok).

%% @doc How UID SEARCH answers: `normal', `none' (tagged OK and no SEARCH line)
%% `junk' (a SEARCH line with a number that is not one), `outside' (a UID that was
%% not asked for), `bracket' (`* SEARCH )'), `bracket_between' (`* SEARCH 5 ) 7') or
%% `modseq' (the CONDSTORE form: the UIDs, then `(MODSEQ n)') or `modseq_alone'
%% (`* SEARCH (MODSEQ n)' with no UIDs, which is malformed), `empty' (an explicit, empty `* SEARCH' although the mailbox holds mail), `modseq_glued' (no space
%% before the suffix) or `modseq_zero' (`(MODSEQ 0)').
set_search(Srv, Mode) when
    Mode =:= normal;
    Mode =:= none;
    Mode =:= junk;
    Mode =:= outside;
    Mode =:= bracket;
    Mode =:= bracket_between;
    Mode =:= modseq;
    Mode =:= modseq_alone;
    Mode =:= empty;
    Mode =:= modseq_glued;
    Mode =:= modseq_zero
->
    call(Srv, {set_search, Mode}, ok).

%% @doc The UIDNEXT the server reports, for a mailbox whose UIDs are far apart. A
%% binary is sent as it is, to send one that is not a valid number.
set_uidnext(Srv, N) -> call(Srv, {set_uidnext, N}, ok).

%% @doc What the server announces from now on (a binary after `IMAP4rev1 ': the
%% capabilities).
set_capabilities(Srv, Caps) -> call(Srv, {set_capabilities, Caps}, ok).

%% @doc The server closes the connection it has now, as a network failure would.
drop_connection(Srv) -> call(Srv, drop_connection, ok).

%% @doc Raw lines the server volunteers with its next answer to a UID FETCH,
%% for example a flag update for a message that was not asked for.
inject(Srv, Lines) -> call(Srv, {inject, Lines}, ok).

%% @doc The mailbox is recreated: a new UIDVALIDITY and these messages, with
%% UIDs that start again at 100, so old UIDs now mean other messages.
new_validity(Srv, Subjects) -> call(Srv, {new_validity, Subjects}, ok).

call(#srv{pid = Pid, ref = Ref}, Msg, Reply) ->
    Pid ! {control, self(), Ref, Msg},
    receive
        {Reply, Ref, Result} -> Result
    after 2000 -> timeout
    end.

%%====================================================================
%% Server loop
%%====================================================================

%% The mailbox outlives a connection: control calls are served between
%% connections, and the next connection sees what the last one left.
accept_loop(LSock, Opts, Ref, State) ->
    case gen_tcp:accept(LSock, 50) of
        {ok, Sock} ->
            put(fake_opts, Opts),
            Greeting =
                case maps:get({opt, preauth_greeting}, State, false) of
                    true -> <<"* PREAUTH logged in\r\n">>;
                    false -> [<<"* OK [CAPABILITY ">>, capabilities(State), <<"] ready\r\n">>]
                end,
            gen_tcp:send(Sock, Greeting),
            inet:setopts(Sock, [{active, once}]),
            State1 = loop(
                Sock, State#{selected => undefined, idling => undefined, enabled => false}, Ref
            ),
            accept_loop(LSock, Opts, Ref, State1);
        {error, timeout} ->
            receive
                {control, From, Ref, Msg} ->
                    {Reply, State1} = handle_control(undefined, Ref, Msg, State),
                    From ! Reply,
                    accept_loop(LSock, Opts, Ref, State1)
            after 0 ->
                accept_loop(LSock, Opts, Ref, State)
            end;
        {error, _} ->
            ok
    end.

capabilities(State) ->
    [
        <<"IMAP4rev1 ">>,
        maps:get(caps, State, <<"IDLE CONDSTORE QRESYNC MOVE UIDPLUS SPECIAL-USE">>)
    ].

init_state() ->
    #{
        messages => messages(),
        selected => undefined,
        idling => undefined,
        vanished => [],
        uidvalidity => 1,
        uidnext => 102
    }.

loop(Sock, State, Ref) ->
    receive
        {tcp, Sock, Line} ->
            case handle_line(Sock, Line, State) of
                {continue, State1} ->
                    inet:setopts(Sock, [{active, once}]),
                    loop(Sock, State1, Ref);
                stop ->
                    gen_tcp:close(Sock),
                    State
            end;
        {control, From, Ref, drop_connection} ->
            From ! {ok, Ref, ok},
            gen_tcp:close(Sock),
            State;
        {control, From, Ref, Msg} ->
            {Reply, State1} = handle_control(Sock, Ref, Msg, State),
            From ! Reply,
            loop(Sock, State1, Ref);
        {tcp_closed, Sock} ->
            State;
        {tcp_error, Sock, _} ->
            gen_tcp:close(Sock),
            State
    end.

%%====================================================================
%% Control handling
%%====================================================================

handle_control(_Sock, Ref, {get_flags, Uid}, State) ->
    {{flags, Ref, flags_for(State, Uid)}, State};
handle_control(Sock, Ref, {set_flags, Uid, Flags}, #{messages := Ms} = State) ->
    Next = highestmodseq(State) + 1,
    Ms1 = [
        case M of
            {Seq, U, _F, _MS, Raw} when U =:= Uid -> {Seq, U, Flags, Next, Raw};
            _ -> M
        end
     || M <- Ms
    ],
    State1 = State#{messages => Ms1},
    notify_flags(Sock, State1, Uid),
    {{ok, Ref, ok}, State1};
handle_control(Sock, Ref, {deliver, Subject}, #{messages := Ms, uidnext := Uid} = State) ->
    Next = highestmodseq(State) + 1,
    Seq = length(Ms) + 1,
    Raw = msg(<<"new@x">>, Subject),
    Ms1 = Ms ++ [{Seq, Uid, [], Next, Raw}],
    State1 = State#{messages => Ms1, uidnext => Uid + 1},
    notify_exists(Sock, State1),
    {{ok, Ref, ok}, State1};
handle_control(_Sock, Ref, {set_option, Option, Bool}, State) ->
    {{ok, Ref, ok}, State#{{opt, Option} => Bool}};
handle_control(_Sock, Ref, {set_capabilities, Caps}, State) ->
    {{ok, Ref, ok}, State#{caps => Caps}};
handle_control(_Sock, Ref, drop_connection, State) ->
    {{ok, Ref, ok}, State};
handle_control(_Sock, Ref, {set_search, Mode}, State) ->
    {{ok, Ref, ok}, State#{search_mode => Mode}};
handle_control(_Sock, Ref, {set_uidnext, N}, State) ->
    {{ok, Ref, ok}, State#{uidnext => N}};
handle_control(_Sock, Ref, {inject, Lines}, State) ->
    {{ok, Ref, ok}, State#{injected => Lines}};
handle_control(_Sock, Ref, {set_failure, Kind, Bool}, State) ->
    {{ok, Ref, ok}, State#{{fail, Kind} => Bool}};
handle_control(_Sock, Ref, {new_validity, Subjects}, #{uidvalidity := V} = State) ->
    Ms = [
        {Seq, 99 + Seq, [], 4 + Seq, msg(<<"nv", (integer_to_binary(Seq))/binary, "@x">>, S)}
     || {Seq, S} <- lists:zip(lists:seq(1, length(Subjects)), Subjects)
    ],
    State1 = State#{
        messages => Ms,
        vanished => [],
        uidvalidity => V + 1,
        uidnext => 100 + length(Subjects)
    },
    {{ok, Ref, ok}, State1};
handle_control(Sock, Ref, {expunge, Uid}, #{messages := Ms, vanished := V} = State) ->
    Next = highestmodseq(State) + 1,
    case lists:keyfind(Uid, 2, Ms) of
        {Seq, Uid, _F, _MS, _Raw} ->
            Ms1 = lists:keydelete(Uid, 2, Ms),
            State1 = State#{messages => Ms1, vanished => [{Uid, Next} | V]},
            notify_expunge(Sock, Seq, State1),
            {{ok, Ref, ok}, State1};
        false ->
            {{ok, Ref, ok}, State}
    end.

%% A flag change while a client is in IDLE is volunteered as an untagged FETCH.
notify_flags(Sock, #{idling := Tag, messages := Ms} = State, Uid) when Tag =/= undefined ->
    case lists:keyfind(Uid, 2, Ms) of
        {Seq, Uid, Flags, MS, _Raw} -> send_changed(Sock, {Seq, Uid, Flags, MS, <<>>});
        false -> ok
    end,
    State;
notify_flags(_Sock, State, _Uid) ->
    State.

notify_exists(Sock, #{idling := Tag, messages := Ms}) when Tag =/= undefined ->
    N = integer_to_binary(length(Ms)),
    gen_tcp:send(Sock, <<"* ", N/binary, " EXISTS\r\n">>);
notify_exists(_Sock, _State) ->
    ok.

notify_expunge(Sock, Seq, #{idling := Tag}) when Tag =/= undefined ->
    SeqB = integer_to_binary(Seq),
    gen_tcp:send(Sock, <<"* ", SeqB/binary, " EXPUNGE\r\n">>);
notify_expunge(_Sock, _Seq, _State) ->
    ok.

flags_for(#{messages := Ms}, Uid) ->
    case lists:keyfind(Uid, 2, Ms) of
        {_, _, Flags, _, _} -> Flags;
        false -> undefined
    end.

highestmodseq(#{messages := Ms, vanished := V}) ->
    MsSeqs = [MS || {_, _, _, MS, _} <- Ms],
    VSeqs = [MS || {_, MS} <- V],
    lists:max([0 | MsSeqs ++ VSeqs]).

%%====================================================================
%% Command handling
%%====================================================================

handle_line(Sock, Line, State) ->
    case chomp(Line) of
        <<"DONE">> ->
            handle_done(Sock, State);
        Trimmed ->
            case binary:split(Trimmed, <<" ">>) of
                [Tag, Rest] -> dispatch(Sock, Tag, Rest, State);
                [_] -> {continue, State}
            end
    end.

handle_done(Sock, #{idling := Tag} = State) when Tag =/= undefined ->
    tagged(Sock, Tag, <<"OK IDLE terminated">>),
    {continue, State#{idling => undefined}};
handle_done(_Sock, State) ->
    {continue, State}.

log_command(Rest) ->
    case maps:get(log, get(fake_opts), undefined) of
        undefined -> ok;
        Tab -> ets:insert(Tab, {erlang:unique_integer([monotonic]), chomp(Rest)})
    end.

%% FETCH 1:* (UID FLAGS): the flags of every message.
handle_plain_fetch(Sock, Tag, Args, #{messages := Ms0} = State) ->
    %% `N:*' is the messages from the Nth, as a real server answers
    Ms =
        case re:run(Args, <<"^([0-9]+):\\*">>, [{capture, all_but_first, binary}]) of
            {match, [From]} -> lists:nthtail(min(length(Ms0), binary_to_integer(From) - 1), Ms0);
            nomatch -> Ms0
        end,
    case maps:get({opt, fail_flags_fetch}, State, false) of
        true ->
            tagged(Sock, Tag, <<"NO cannot read flags">>),
            {continue, State};
        false ->
            plain_fetch_answer(Sock, Tag, Ms, State)
    end.

plain_fetch_answer(Sock, Tag, Ms, State) ->
    [
        send(Sock, [
            <<"* ", (integer_to_binary(Seq))/binary, " FETCH (UID ",
                (integer_to_binary(Uid))/binary, " FLAGS (">>,
            lists:join(<<" ">>, Flags),
            <<"))\r\n">>
        ])
     || {Seq, Uid, Flags, _MS, _Raw} <- Ms
    ],
    tagged(Sock, Tag, <<"OK FETCH done">>),
    {continue, State}.

auth_mode() ->
    maps:get(auth, get(fake_opts), accept).

notify_auth(Event) ->
    case maps:get(auth_log, get(fake_opts), undefined) of
        undefined -> ok;
        Pid -> Pid ! {fake_imap_auth, Event}
    end.

chomp(Bin) ->
    S = byte_size(Bin),
    case S > 0 andalso lists:member(binary:at(Bin, S - 1), [$\r, $\n]) of
        true -> chomp(binary:part(Bin, 0, S - 1));
        false -> Bin
    end.

dispatch(Sock, Tag, Rest, State) ->
    log_command(Rest),
    {Cmd, Args} = split1(Rest),
    case string:uppercase(Cmd) of
        <<"CAPABILITY">> ->
            send(
                Sock,
                [<<"* CAPABILITY ">>, capabilities(State), <<"\r\n">>]
            ),
            tagged(Sock, Tag, <<"OK CAPABILITY done">>),
            {continue, State};
        <<"LOGIN">> ->
            notify_auth({login, Args}),
            case auth_mode() of
                reject -> tagged(Sock, Tag, <<"NO [AUTHENTICATIONFAILED] bad credentials">>);
                _ -> tagged(Sock, Tag, <<"OK LOGIN completed">>)
            end,
            {continue, State};
        <<"AUTHENTICATE">> ->
            send(Sock, <<"+ \r\n">>),
            inet:setopts(Sock, [{active, false}]),
            {ok, TokenLine} = gen_tcp:recv(Sock, 0, 2000),
            notify_auth({authenticate, Args, chomp(TokenLine)}),
            case auth_mode() of
                reject_xoauth2 ->
                    %% an error challenge; the client ends the exchange with an empty line
                    send(Sock, <<"+ eyJzdGF0dXMiOiI0MDEifQ==\r\n">>),
                    _ = gen_tcp:recv(Sock, 0, 2000),
                    tagged(Sock, Tag, <<"NO [AUTHENTICATIONFAILED] token refused">>);
                _ ->
                    tagged(Sock, Tag, <<"OK AUTHENTICATE completed">>)
            end,
            {continue, State};
        <<"ENABLE">> ->
            case maps:get({opt, empty_enabled}, State, false) of
                true -> send(Sock, <<"* ENABLED\r\n">>);
                false -> send(Sock, <<"* ENABLED QRESYNC\r\n">>)
            end,
            tagged(Sock, Tag, <<"OK ENABLE done">>),
            {continue, State#{enabled => true}};
        <<"NOOP">> ->
            tagged(Sock, Tag, <<"OK NOOP done">>),
            {continue, State};
        <<"IDLE">> ->
            send(Sock, <<"+ idling\r\n">>),
            {continue, State#{idling => Tag}};
        <<"LIST">> ->
            send(Sock, <<"* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n">>),
            send(Sock, <<"* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"\r\n">>),
            send(Sock, <<"* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n">>),
            tagged(Sock, Tag, <<"OK LIST done">>),
            {continue, State};
        <<"SELECT">> ->
            handle_select(Sock, Tag, Args, State);
        <<"EXAMINE">> ->
            handle_select(Sock, Tag, Args, State);
        <<"FETCH">> ->
            handle_plain_fetch(Sock, Tag, Args, State);
        <<"UID">> ->
            handle_uid(Sock, Tag, Args, State);
        <<"LOGOUT">> ->
            send(Sock, <<"* BYE logging out\r\n">>),
            tagged(Sock, Tag, <<"OK LOGOUT completed">>),
            stop;
        _ ->
            tagged(Sock, Tag, <<"BAD unknown command">>),
            {continue, State}
    end.

handle_select(Sock, Tag, Args, State) ->
    case
        maps:get({opt, enforce_enable}, State, false) andalso
            not maps:get(enabled, State, false) andalso qresync_modseq(Args) =/= none
    of
        true ->
            tagged(Sock, Tag, <<"BAD QRESYNC was not enabled">>),
            {continue, State};
        false ->
            handle_select_ok(Sock, Tag, Args, State)
    end.

handle_select_ok(Sock, Tag, Args, State) ->
    Mailbox = unquote(first_token(Args)),
    send_select(Sock, State),
    case qresync_modseq(Args) of
        {ok, Validity, Since} ->
            %% a client that remembers another UIDVALIDITY is told nothing
            %% about what it missed: the new validity says it all
            case Validity =:= maps:get(uidvalidity, State, 1) of
                true -> emit_qresync(Sock, State, Since);
                false -> ok
            end;
        none ->
            ok
    end,
    tagged(Sock, Tag, <<"OK [READ-WRITE] SELECT completed">>),
    {continue, State#{selected => Mailbox}}.

send_select(Sock, #{messages := Ms, uidnext := UidNext} = State) ->
    N = integer_to_binary(length(Ms)),
    HMS = integer_to_binary(highestmodseq(State)),
    UN = uidnext_text(UidNext),
    send(Sock, <<"* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n">>),
    case maps:get({opt, no_exists}, State, false) of
        true -> ok;
        false -> send(Sock, <<"* ", N/binary, " EXISTS\r\n">>)
    end,
    send(Sock, <<"* 0 RECENT\r\n">>),
    Validity =
        case maps:get({opt, bad_validity}, State, false) of
            true -> <<"01">>;
            false -> integer_to_binary(maps:get(uidvalidity, State, 1))
        end,
    send(Sock, <<"* OK [UIDVALIDITY ", Validity/binary, "] UIDs valid\r\n">>),
    case maps:get({opt, no_uidnext}, State, false) of
        true -> ok;
        false -> send(Sock, <<"* OK [UIDNEXT ", UN/binary, "] Predicted next UID\r\n">>)
    end,
    send(Sock, <<"* OK [HIGHESTMODSEQ ", HMS/binary, "] Highest\r\n">>).

uidnext_text(N) when is_integer(N) -> integer_to_binary(N);
uidnext_text(Bin) when is_binary(Bin) -> Bin.

emit_qresync(Sock, #{vanished := V, messages := Ms} = State, Since) ->
    Gone = [Uid || {Uid, MS} <- V, MS > Since],
    case Gone of
        [] ->
            ok;
        _ ->
            Set = lists:join(<<",">>, [integer_to_binary(U) || U <- lists:sort(Gone)]),
            case maps:get({opt, bad_vanished}, State, false) of
                true -> send(Sock, <<"* VANISHED (EARLIER)\r\n">>);
                false -> send(Sock, [<<"* VANISHED (EARLIER) ">>, Set, <<"\r\n">>])
            end
    end,
    [send_changed(Sock, M) || {_, _, _, MS, _} = M <- Ms, MS > Since],
    ok.

qresync_modseq(Args) ->
    case
        re:run(
            string:uppercase(Args),
            <<"QRESYNC \\(([0-9]+) ([0-9]+)\\)">>,
            [{capture, all_but_first, binary}]
        )
    of
        {match, [V, N]} -> {ok, binary_to_integer(V), binary_to_integer(N)};
        nomatch -> none
    end.

handle_uid(Sock, Tag, Args, State) ->
    {Sub, Rest} = split1(Args),
    case string:uppercase(Sub) of
        <<"FETCH">> ->
            handle_uid_fetch(Sock, Tag, Rest, State);
        <<"STORE">> ->
            handle_uid_store(Sock, Tag, Rest, State);
        <<"SEARCH">> ->
            handle_uid_search(Sock, Tag, Rest, State);
        _ ->
            tagged(Sock, Tag, <<"BAD unsupported UID command">>),
            {continue, State}
    end.

handle_uid_fetch(Sock, Tag, Rest, #{messages := Ms} = State) ->
    {SetBin, ItemsBin} = split1(Rest),
    case changedsince(ItemsBin) of
        {ok, Since} ->
            {Lo0, Hi0} = set_range(SetBin),
            [
                send_changed(Sock, M)
             || {_, U0, _, MS, _} = M <- Ms, MS > Since, U0 >= Lo0, U0 =< Hi0
            ],
            tagged(Sock, Tag, <<"OK UID FETCH done">>),
            {continue, State};
        none when
            SetBin =:= <<"*">>
        ->
            case
                {
                    maps:get({opt, fail_max_uid}, State, false),
                    maps:get({opt, zero_max_uid}, State, false)
                }
            of
                {true, _} ->
                    tagged(Sock, Tag, <<"NO no highest uid">>),
                    {continue, State};
                {_, true} ->
                    [send(Sock, [Line, <<"\r\n">>]) || Line <- maps:get(injected, State, [])],
                    send(Sock, <<"* 2 FETCH (UID 0)\r\n">>),
                    tagged(Sock, Tag, <<"OK UID FETCH done">>),
                    {continue, maps:remove(injected, State)};
                _ ->
                    handle_uid_fetch_data(Sock, Tag, SetBin, ItemsBin, State)
            end;
        none ->
            case body_uid_fails(SetBin, ItemsBin, State) of
                true ->
                    tagged(Sock, Tag, <<"NO cannot read this message">>),
                    {continue, State};
                false ->
                    handle_uid_fetch_checked(Sock, Tag, SetBin, ItemsBin, State)
            end
    end.

body_uid_fails(SetBin, ItemsBin, State) ->
    case is_body_fetch(ItemsBin) of
        true ->
            try set_low(SetBin) of
                Uid -> maps:get({fail, {body, Uid}}, State, false)
            catch
                _:_ -> false
            end;
        false ->
            false
    end.

handle_uid_fetch_checked(Sock, Tag, SetBin, ItemsBin, State) ->
    case {is_body_fetch(ItemsBin), maps:get({fail, body}, State, false)} of
        {true, true} ->
            tagged(Sock, Tag, <<"NO cannot read the message">>),
            {continue, State};
        {false, _} ->
            case maps:get({fail, meta}, State, false) of
                true ->
                    tagged(Sock, Tag, <<"NO cannot list">>),
                    {continue, State};
                false ->
                    handle_uid_fetch_data(Sock, Tag, SetBin, ItemsBin, State)
            end;
        _ ->
            handle_uid_fetch_data(Sock, Tag, SetBin, ItemsBin, State)
    end.

handle_uid_fetch_data(Sock, Tag, SetBin, ItemsBin, #{messages := Ms} = State) ->
    case is_body_fetch(ItemsBin) of
        true ->
            Uid = set_low(SetBin),
            case lists:keyfind(Uid, 2, Ms) of
                {Seq, Uid, _F, _MS, Raw} -> send_body(Sock, Seq, Uid, Raw);
                false -> ok
            end,
            tagged(Sock, Tag, <<"OK UID FETCH done">>),
            {continue, State};
        false when SetBin =:= <<"*">> ->
            %% `*' alone is the message with the highest UID
            [send_meta(Sock, M) || M <- last_message(Ms)],
            tagged(Sock, Tag, <<"OK UID FETCH done">>),
            {continue, State};
        false ->
            {Lo, Hi} = set_range(SetBin),
            %% like a real server: `N:*' always includes the highest
            %% message, even when N is past it (RFC 3501, section 9)
            Hits =
                case [M || {_, Uid, _, _, _} = M <- Ms, Uid >= Lo, Uid =< Hi] of
                    [] when
                        Ms =/= [], binary_part(SetBin, byte_size(SetBin), -1) =:= <<"*">>
                    ->
                        [lists:last(Ms)];
                    Found ->
                        Found
                end,
            [send_meta(Sock, M) || M <- Hits],
            [send(Sock, [Line, <<"\r\n">>]) || Line <- maps:get(injected, State, [])],
            tagged(Sock, Tag, <<"OK UID FETCH done">>),
            {continue, maps:remove(injected, State)}
    end.

handle_uid_search(Sock, Tag, Rest, #{messages := Ms} = State) ->
    {Lo, Hi} =
        case
            re:run(string:uppercase(Rest), <<"UID ([0-9:*]+)">>, [{capture, all_but_first, binary}])
        of
            {match, [Set]} -> set_range(Set);
            nomatch -> {0, infinity}
        end,
    Uids = lists:join(<<" ">>, [
        integer_to_binary(U)
     || {_, U, _, _, _} <- Ms, U >= Lo, U =< Hi
    ]),
    case maps:get(search_mode, State, normal) of
        normal -> send(Sock, [<<"* SEARCH ">>, Uids, <<"\r\n">>]);
        none -> ok;
        empty -> send(Sock, <<"* SEARCH\r\n">>);
        junk -> send(Sock, [<<"* SEARCH 5 abc 7\r\n">>]);
        outside -> send(Sock, <<"* SEARCH 99999\r\n">>);
        bracket -> send(Sock, <<"* SEARCH )\r\n">>);
        bracket_between -> send(Sock, <<"* SEARCH 5 ) 7\r\n">>);
        modseq -> send(Sock, [<<"* SEARCH ">>, Uids, <<" (MODSEQ 9)\r\n">>]);
        modseq_alone -> send(Sock, <<"* SEARCH (MODSEQ 9)\r\n">>);
        modseq_glued -> send(Sock, [<<"* SEARCH ">>, Uids, <<"(MODSEQ 9)\r\n">>]);
        modseq_zero -> send(Sock, [<<"* SEARCH ">>, Uids, <<" (MODSEQ 0)\r\n">>])
    end,
    tagged(Sock, Tag, <<"OK UID SEARCH done">>),
    {continue, State}.

changedsince(Bin) ->
    case
        re:run(
            string:uppercase(Bin),
            <<"CHANGEDSINCE ([0-9]+)">>,
            [{capture, all_but_first, binary}]
        )
    of
        {match, [N]} -> {ok, binary_to_integer(N)};
        nomatch -> none
    end.

send_meta(Sock, {Seq, Uid, Flags, _MS, Raw}) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    Size = integer_to_binary(byte_size(Raw)),
    FlagsB = lists:join(<<" ">>, Flags),
    send(Sock, [
        <<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " FLAGS (">>,
        FlagsB,
        <<") INTERNALDATE \"02-Jun-2025 09:00:00 +0000\" RFC822.SIZE ">>,
        Size,
        <<")\r\n">>
    ]).

send_changed(Sock, {Seq, Uid, Flags, MS, _Raw}) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    MSB = integer_to_binary(MS),
    FlagsB = lists:join(<<" ">>, Flags),
    send(Sock, [
        <<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " MODSEQ (">>,
        MSB,
        <<") FLAGS (">>,
        FlagsB,
        <<"))\r\n">>
    ]).

send_body(Sock, Seq, Uid, Raw) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    Len = integer_to_binary(byte_size(Raw)),
    send(Sock, [
        <<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " BODY[] {">>,
        Len,
        <<"}\r\n">>,
        Raw,
        <<")\r\n">>
    ]).

handle_uid_store(Sock, Tag, Rest, #{messages := Ms} = State) ->
    {SetBin, OpAndFlags} = split1(Rest),
    Uid = set_low(SetBin),
    {OpBin, FlagsParen} = split1(OpAndFlags),
    Flags = parse_paren_flags(FlagsParen),
    Op = store_op(OpBin),
    Ms1 = update_flags(State, Ms, Uid, Op, Flags),
    tagged(Sock, Tag, <<"OK UID STORE done">>),
    {continue, State#{messages => Ms1}}.

store_op(<<"+FLAGS", _/binary>>) -> add;
store_op(<<"-FLAGS", _/binary>>) -> remove;
store_op(_) -> set.

update_flags(State, Ms, Uid, Op, Flags) ->
    Next = highestmodseq(State) + 1,
    lists:map(
        fun
            ({Seq, U, Existing, _MS, Raw}) when U =:= Uid ->
                New =
                    case Op of
                        add -> lists:usort(Existing ++ Flags);
                        remove -> Existing -- Flags;
                        set -> Flags
                    end,
                {Seq, U, New, Next, Raw};
            (M) ->
                M
        end,
        Ms
    ).

%%====================================================================
%% Parsing helpers
%%====================================================================

%% Only a request for the whole body (BODY[] or BODY.PEEK[]) gets the raw
%% message; BODYSTRUCTURE and header-field sections are metadata.
is_body_fetch(ItemsBin) ->
    re:run(string:uppercase(ItemsBin), <<"BODY(\\.PEEK)?\\[\\]">>) =/= nomatch.

last_message([]) -> [];
last_message(Ms) -> [lists:last(Ms)].

%% The two ends of the first range of a set, `*' being no upper end.
set_range(SetBin) ->
    Clean = unparen(SetBin),
    First = hd(binary:split(Clean, <<",">>, [global])),
    case binary:split(First, <<":">>) of
        [Lo, <<"*">>] -> {binary_to_integer(Lo), infinity};
        [Lo, Hi] -> {binary_to_integer(Lo), binary_to_integer(Hi)};
        [One] -> {binary_to_integer(One), binary_to_integer(One)}
    end.

set_low(SetBin) ->
    Clean = unparen(SetBin),
    First = hd(binary:split(Clean, <<",">>, [global])),
    Lo = hd(binary:split(First, <<":">>)),
    binary_to_integer(Lo).

parse_paren_flags(Bin) ->
    Inner = unparen(Bin),
    [F || F <- binary:split(Inner, <<" ">>, [global]), F =/= <<>>].

unparen(Bin) ->
    B1 = string:trim(Bin),
    B2 =
        case B1 of
            <<"(", R/binary>> -> R;
            _ -> B1
        end,
    case B2 of
        <<>> ->
            <<>>;
        _ ->
            case binary:last(B2) of
                $) -> binary:part(B2, 0, byte_size(B2) - 1);
                _ -> B2
            end
    end.

first_token(Bin) -> hd(binary:split(string:trim(Bin, leading), <<" ">>)).

unquote(Bin) ->
    T = string:trim(Bin),
    case T of
        <<"\"", R/binary>> ->
            case binary:last(R) of
                $" -> binary:part(R, 0, byte_size(R) - 1);
                _ -> T
            end;
        _ ->
            T
    end.

split1(Bin) ->
    case binary:split(string:trim(Bin, leading), <<" ">>) of
        [A, B] -> {A, B};
        [A] -> {A, <<>>}
    end.

send(Sock, Data) -> gen_tcp:send(Sock, Data).

tagged(Sock, Tag, Text) ->
    gen_tcp:send(Sock, [Tag, <<" ">>, Text, <<"\r\n">>]).
