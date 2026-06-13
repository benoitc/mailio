%%% @doc Scripted fake IMAP server for adapter and sync tests.
%%%
%%% Implements just enough of IMAP4rev1 (+ CONDSTORE-style CHANGEDSINCE) to
%%% drive the adapter and sync engine end to end against a real socket:
%%% greeting, CAPABILITY, LOGIN, LIST, SELECT, UID FETCH (metadata,
%%% BODY.PEEK[], and CHANGEDSINCE), UID STORE, NOOP, LOGOUT. Messages carry
%%% a MODSEQ so a flag change can be replayed to the client. Not a
%%% conformant server — a test double.
-module(mailio_fake_imap).

-export([start/0, start/1, stop/1, port/1, last_flags/2, set_flags/3]).

-record(srv, {port, pid, ref}).

%% {Seq, Uid, FlagsList, ModSeq, Raw}
messages() ->
    [{1, 100, [<<"\\Seen">>], 5, msg(<<"m100@x">>, <<"First message">>)},
     {2, 101, [], 6, msg(<<"m101@x">>, <<"Second message">>)}].

msg(Id, Subject) ->
    <<"From: sender@example.com\r\n",
      "To: me@example.com\r\n",
      "Subject: ", Subject/binary, "\r\n",
      "Message-ID: <", Id/binary, ">\r\n",
      "Date: Mon, 2 Jun 2025 09:00:00 +0000\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "\r\n",
      "Body of ", Subject/binary, ".\r\n">>.

%%====================================================================
%% Control
%%====================================================================

start() -> start(#{}).

start(Opts) ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false},
                                     {packet, line}, {reuseaddr, true}]),
    {ok, Port} = inet:port(LSock),
    Ref = make_ref(),
    Pid = spawn(fun() -> accept_loop(LSock, Opts, Ref) end),
    #srv{port = Port, pid = Pid, ref = Ref}.

stop(#srv{pid = Pid}) -> exit(Pid, shutdown), ok.

port(#srv{port = Port}) -> Port.

last_flags(#srv{pid = Pid, ref = Ref}, Uid) ->
    Pid ! {get_flags, self(), Ref, Uid},
    receive {flags, Ref, Flags} -> Flags after 1000 -> timeout end.

%% @doc Change a message's flags and bump its MODSEQ, so the next
%% CHANGEDSINCE sync reports it as updated.
set_flags(#srv{pid = Pid, ref = Ref}, Uid, Flags) ->
    Pid ! {set_flags, self(), Ref, Uid, Flags},
    receive {ok, Ref} -> ok after 1000 -> timeout end.

%%====================================================================
%% Server loop
%%====================================================================

accept_loop(LSock, Opts, Ref) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            gen_tcp:send(Sock, <<"* OK [CAPABILITY IMAP4rev1 IDLE CONDSTORE QRESYNC MOVE UIDPLUS SPECIAL-USE] ready\r\n">>),
            inet:setopts(Sock, [{active, once}]),
            loop(Sock, #{messages => messages(), selected => undefined}, Ref),
            accept_loop(LSock, Opts, Ref);
        {error, _} ->
            ok
    end.

loop(Sock, State, Ref) ->
    receive
        {tcp, Sock, Line} ->
            case handle_line(Sock, Line, State) of
                {continue, State1} ->
                    inet:setopts(Sock, [{active, once}]),
                    loop(Sock, State1, Ref);
                stop ->
                    gen_tcp:close(Sock)
            end;
        {get_flags, From, Ref, Uid} ->
            From ! {flags, Ref, flags_for(State, Uid)},
            loop(Sock, State, Ref);
        {set_flags, From, Ref, Uid, Flags} ->
            State1 = do_set_flags(State, Uid, Flags),
            From ! {ok, Ref},
            loop(Sock, State1, Ref);
        {tcp_closed, Sock} ->
            ok;
        {tcp_error, Sock, _} ->
            gen_tcp:close(Sock)
    end.

flags_for(#{messages := Ms}, Uid) ->
    case lists:keyfind(Uid, 2, Ms) of
        {_, _, Flags, _, _} -> Flags;
        false -> undefined
    end.

do_set_flags(#{messages := Ms} = State, Uid, Flags) ->
    Next = highestmodseq(Ms) + 1,
    Ms1 = [case M of
               {Seq, U, _F, _MS, Raw} when U =:= Uid -> {Seq, U, Flags, Next, Raw};
               _ -> M
           end || M <- Ms],
    State#{messages => Ms1}.

highestmodseq(Ms) -> lists:max([MS || {_, _, _, MS, _} <- Ms]).

%%====================================================================
%% Command handling
%%====================================================================

handle_line(Sock, Line, State) ->
    case binary:split(chomp(Line), <<" ">>) of
        [Tag, Rest] -> dispatch(Sock, Tag, Rest, State);
        [_] -> {continue, State}
    end.

chomp(Bin) ->
    S = byte_size(Bin),
    case S > 0 andalso lists:member(binary:at(Bin, S - 1), [$\r, $\n]) of
        true -> chomp(binary:part(Bin, 0, S - 1));
        false -> Bin
    end.

dispatch(Sock, Tag, Rest, State) ->
    {Cmd, Args} = split1(Rest),
    case string:uppercase(Cmd) of
        <<"CAPABILITY">> ->
            send(Sock, <<"* CAPABILITY IMAP4rev1 IDLE CONDSTORE QRESYNC MOVE UIDPLUS SPECIAL-USE\r\n">>),
            tagged(Sock, Tag, <<"OK CAPABILITY done">>),
            {continue, State};
        <<"LOGIN">> ->
            tagged(Sock, Tag, <<"OK LOGIN completed">>),
            {continue, State};
        <<"NOOP">> ->
            tagged(Sock, Tag, <<"OK NOOP done">>),
            {continue, State};
        <<"LIST">> ->
            send(Sock, <<"* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n">>),
            send(Sock, <<"* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"\r\n">>),
            send(Sock, <<"* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n">>),
            tagged(Sock, Tag, <<"OK LIST done">>),
            {continue, State};
        <<"SELECT">> ->
            Mailbox = unquote(Args),
            send_select(Sock, State),
            tagged(Sock, Tag, <<"OK [READ-WRITE] SELECT completed">>),
            {continue, State#{selected => Mailbox}};
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

send_select(Sock, #{messages := Ms}) ->
    N = integer_to_binary(length(Ms)),
    HMS = integer_to_binary(highestmodseq(Ms)),
    send(Sock, <<"* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n">>),
    send(Sock, <<"* ", N/binary, " EXISTS\r\n">>),
    send(Sock, <<"* 0 RECENT\r\n">>),
    send(Sock, <<"* OK [UIDVALIDITY 1] UIDs valid\r\n">>),
    send(Sock, <<"* OK [UIDNEXT 102] Predicted next UID\r\n">>),
    send(Sock, <<"* OK [HIGHESTMODSEQ ", HMS/binary, "] Highest\r\n">>).

handle_uid(Sock, Tag, Args, State) ->
    {Sub, Rest} = split1(Args),
    case string:uppercase(Sub) of
        <<"FETCH">> -> handle_uid_fetch(Sock, Tag, Rest, State);
        <<"STORE">> -> handle_uid_store(Sock, Tag, Rest, State);
        _ ->
            tagged(Sock, Tag, <<"BAD unsupported UID command">>),
            {continue, State}
    end.

handle_uid_fetch(Sock, Tag, Rest, #{messages := Ms} = State) ->
    {SetBin, ItemsBin} = split1(Rest),
    case changedsince(ItemsBin) of
        {ok, Since} ->
            [send_changed(Sock, M) || {_, _, _, MS, _} = M <- Ms, MS > Since],
            tagged(Sock, Tag, <<"OK UID FETCH done">>),
            {continue, State};
        none ->
            case is_body_fetch(ItemsBin) of
                true ->
                    Uid = set_low(SetBin),
                    case lists:keyfind(Uid, 2, Ms) of
                        {Seq, Uid, _F, _MS, Raw} -> send_body(Sock, Seq, Uid, Raw);
                        false -> ok
                    end,
                    tagged(Sock, Tag, <<"OK UID FETCH done">>),
                    {continue, State};
                false ->
                    Lo = set_low(SetBin),
                    [send_meta(Sock, M) || {_, Uid, _, _, _} = M <- Ms, Uid >= Lo],
                    tagged(Sock, Tag, <<"OK UID FETCH done">>),
                    {continue, State}
            end
    end.

changedsince(Bin) ->
    case re:run(string:uppercase(Bin), <<"CHANGEDSINCE ([0-9]+)">>,
                [{capture, all_but_first, binary}]) of
        {match, [N]} -> {ok, binary_to_integer(N)};
        nomatch -> none
    end.

send_meta(Sock, {Seq, Uid, Flags, _MS, Raw}) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    Size = integer_to_binary(byte_size(Raw)),
    FlagsB = lists:join(<<" ">>, Flags),
    send(Sock, [<<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " FLAGS (">>,
                FlagsB, <<") INTERNALDATE \"02-Jun-2025 09:00:00 +0000\" RFC822.SIZE ">>,
                Size, <<")\r\n">>]).

send_changed(Sock, {Seq, Uid, Flags, MS, _Raw}) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    MSB = integer_to_binary(MS),
    FlagsB = lists:join(<<" ">>, Flags),
    send(Sock, [<<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " MODSEQ (">>,
                MSB, <<") FLAGS (">>, FlagsB, <<"))\r\n">>]).

send_body(Sock, Seq, Uid, Raw) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    Len = integer_to_binary(byte_size(Raw)),
    send(Sock, [<<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " BODY[] {">>,
                Len, <<"}\r\n">>, Raw, <<")\r\n">>]).

handle_uid_store(Sock, Tag, Rest, #{messages := Ms} = State) ->
    {SetBin, OpAndFlags} = split1(Rest),
    Uid = set_low(SetBin),
    {OpBin, FlagsParen} = split1(OpAndFlags),
    Flags = parse_paren_flags(FlagsParen),
    Op = store_op(OpBin),
    Ms1 = update_flags(Ms, Uid, Op, Flags),
    tagged(Sock, Tag, <<"OK UID STORE done">>),
    {continue, State#{messages => Ms1}}.

store_op(<<"+FLAGS", _/binary>>) -> add;
store_op(<<"-FLAGS", _/binary>>) -> remove;
store_op(_) -> set.

update_flags(Ms, Uid, Op, Flags) ->
    Next = highestmodseq(Ms) + 1,
    lists:map(
        fun({Seq, U, Existing, _MS, Raw}) when U =:= Uid ->
                New = case Op of
                          add -> lists:usort(Existing ++ Flags);
                          remove -> Existing -- Flags;
                          set -> Flags
                      end,
                {Seq, U, New, Next, Raw};
           (M) -> M
        end, Ms).

%%====================================================================
%% Parsing helpers
%%====================================================================

is_body_fetch(ItemsBin) ->
    nomatch =/= binary:match(string:uppercase(ItemsBin), <<"BODY">>).

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
    B2 = case B1 of <<"(", R/binary>> -> R; _ -> B1 end,
    case B2 of
        <<>> -> <<>>;
        _ -> case binary:last(B2) of
                 $) -> binary:part(B2, 0, byte_size(B2) - 1);
                 _ -> B2
             end
    end.

unquote(Bin) ->
    T = string:trim(Bin),
    case T of
        <<"\"", R/binary>> ->
            case binary:last(R) of
                $" -> binary:part(R, 0, byte_size(R) - 1);
                _ -> T
            end;
        _ -> T
    end.

split1(Bin) ->
    case binary:split(string:trim(Bin, leading), <<" ">>) of
        [A, B] -> {A, B};
        [A] -> {A, <<>>}
    end.

send(Sock, Data) -> gen_tcp:send(Sock, Data).

tagged(Sock, Tag, Text) ->
    gen_tcp:send(Sock, [Tag, <<" ">>, Text, <<"\r\n">>]).
