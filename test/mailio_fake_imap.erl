%%% @doc Scripted fake IMAP server for adapter tests.
%%%
%%% Implements just enough of IMAP4rev1 (+ a couple of extensions) to drive
%%% the adapter end to end against a real socket: greeting, CAPABILITY,
%%% LOGIN, LIST, SELECT, UID FETCH (metadata and BODY.PEEK[]), UID STORE,
%%% NOOP, LOGOUT. Backed by a tiny fixed mailbox so SELECT/FETCH/STORE
%%% return believable data. Not a conformant server — a test double.
-module(mailio_fake_imap).

-export([start/0, start/1, stop/1, port/1, last_flags/2]).
-export([init/2]).

-record(srv, {port, pid, ref}).

%% Two messages in INBOX. {Seq, Uid, FlagsList, Raw}
messages() ->
    [{1, 100, [<<"\\Seen">>], msg(<<"m100@x">>, <<"First message">>)},
     {2, 101, [], msg(<<"m101@x">>, <<"Second message">>)}].

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
    Owner = self(),
    Pid = spawn(fun() -> accept_loop(LSock, Opts, Owner, Ref) end),
    #srv{port = Port, pid = Pid, ref = Ref}.

stop(#srv{pid = Pid}) -> exit(Pid, shutdown), ok.

port(#srv{port = Port}) -> Port.

%% @doc Ask the server for the flags it currently holds for a uid (lets a
%% test assert that a STORE took effect).
last_flags(#srv{pid = Pid, ref = Ref}, Uid) ->
    Pid ! {get_flags, self(), Ref, Uid},
    receive {flags, Ref, Flags} -> Flags after 1000 -> timeout end.

%%====================================================================
%% Server loop
%%====================================================================

accept_loop(LSock, Opts, Owner, Ref) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            gen_tcp:send(Sock, <<"* OK [CAPABILITY IMAP4rev1 IDLE CONDSTORE QRESYNC MOVE UIDPLUS SPECIAL-USE] ready\r\n">>),
            State = init(Opts, messages()),
            inet:setopts(Sock, [{active, once}]),
            loop(Sock, State, Owner, Ref),
            accept_loop(LSock, Opts, Owner, Ref);
        {error, _} ->
            ok
    end.

init(_Opts, Messages) ->
    #{messages => Messages, selected => undefined}.

%% Message-driven so control requests (get_flags) are answered even while
%% the socket is idle between commands.
loop(Sock, State, Owner, Ref) ->
    receive
        {tcp, Sock, Line} ->
            case handle_line(Sock, Line, State) of
                {continue, State1} ->
                    inet:setopts(Sock, [{active, once}]),
                    loop(Sock, State1, Owner, Ref);
                stop ->
                    gen_tcp:close(Sock)
            end;
        {get_flags, From, Ref, Uid} ->
            From ! {flags, Ref, flags_for(State, Uid)},
            loop(Sock, State, Owner, Ref);
        {tcp_closed, Sock} ->
            ok;
        {tcp_error, Sock, _} ->
            gen_tcp:close(Sock)
    end.

flags_for(#{messages := Ms}, Uid) ->
    case lists:keyfind(Uid, 2, Ms) of
        {_, _, Flags, _} -> Flags;
        false -> undefined
    end.

%%====================================================================
%% Command handling
%%====================================================================

handle_line(Sock, Line, State) ->
    Trimmed = chomp(Line),
    case binary:split(Trimmed, <<" ">>) of
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
    send(Sock, <<"* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n">>),
    send(Sock, <<"* ", N/binary, " EXISTS\r\n">>),
    send(Sock, <<"* 0 RECENT\r\n">>),
    send(Sock, <<"* OK [UIDVALIDITY 1] UIDs valid\r\n">>),
    send(Sock, <<"* OK [UIDNEXT 102] Predicted next UID\r\n">>),
    send(Sock, <<"* OK [HIGHESTMODSEQ 10] Highest\r\n">>).

handle_uid(Sock, Tag, Args, State) ->
    {Sub, Rest} = split1(Args),
    case string:uppercase(Sub) of
        <<"FETCH">> -> handle_uid_fetch(Sock, Tag, Rest, State);
        <<"STORE">> -> handle_uid_store(Sock, Tag, Rest, State);
        _ ->
            tagged(Sock, Tag, <<"BAD unsupported UID command">>),
            {continue, State}
    end.

%% UID FETCH <set> (<items>)
handle_uid_fetch(Sock, Tag, Rest, #{messages := Ms} = State) ->
    {SetBin, ItemsBin} = split1(Rest),
    case is_body_fetch(ItemsBin) of
        true ->
            Uid = first_uid(SetBin),
            case lists:keyfind(Uid, 2, Ms) of
                {Seq, Uid, _Flags, Raw} ->
                    send_body(Sock, Seq, Uid, Raw);
                false ->
                    ok
            end,
            tagged(Sock, Tag, <<"OK UID FETCH done">>),
            {continue, State};
        false ->
            Lo = set_low(SetBin),
            [send_meta(Sock, M) || {_, Uid, _, _} = M <- Ms, Uid >= Lo],
            tagged(Sock, Tag, <<"OK UID FETCH done">>),
            {continue, State}
    end.

send_meta(Sock, {Seq, Uid, Flags, Raw}) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    Size = integer_to_binary(byte_size(Raw)),
    FlagsB = lists:join(<<" ">>, Flags),
    send(Sock, [<<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " FLAGS (">>,
                FlagsB, <<") INTERNALDATE \"02-Jun-2025 09:00:00 +0000\" RFC822.SIZE ">>,
                Size, <<")\r\n">>]).

send_body(Sock, Seq, Uid, Raw) ->
    SeqB = integer_to_binary(Seq),
    UidB = integer_to_binary(Uid),
    Len = integer_to_binary(byte_size(Raw)),
    send(Sock, [<<"* ", SeqB/binary, " FETCH (UID ", UidB/binary, " BODY[] {">>,
                Len, <<"}\r\n">>, Raw, <<")\r\n">>]).

%% UID STORE <set> (+|-)FLAGS(.SILENT) (<flags>)
handle_uid_store(Sock, Tag, Rest, #{messages := Ms} = State) ->
    {SetBin, OpAndFlags} = split1(Rest),
    Uid = first_uid(SetBin),
    {OpBin, FlagsParen} = split1(OpAndFlags),
    Flags = parse_paren_flags(FlagsParen),
    Op = store_op(OpBin),
    Ms1 = update_flags(Ms, Uid, Op, Flags),
    tagged(Sock, Tag, <<"OK UID STORE done">>),
    {continue, State#{messages => Ms1}}.

store_op(Bin) ->
    case Bin of
        <<"+FLAGS", _/binary>> -> add;
        <<"-FLAGS", _/binary>> -> remove;
        _ -> set
    end.

update_flags(Ms, Uid, Op, Flags) ->
    lists:map(
        fun({Seq, U, Existing, Raw}) when U =:= Uid ->
                New = case Op of
                          add -> lists:usort(Existing ++ Flags);
                          remove -> Existing -- Flags;
                          set -> Flags
                      end,
                {Seq, U, New, Raw};
           (M) -> M
        end, Ms).

%%====================================================================
%% Parsing helpers
%%====================================================================

is_body_fetch(ItemsBin) ->
    nomatch =/= binary:match(string:uppercase(ItemsBin), <<"BODY">>).

first_uid(SetBin) ->
    set_low(SetBin).

%% Lowest uid named by a set like "100", "100:*", "100:200".
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
