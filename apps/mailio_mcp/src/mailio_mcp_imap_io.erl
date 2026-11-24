%%% @doc IMAP connection for the adapter: one `mailio_imap_conn' (the mailio
%%% library's connection process, which owns TLS, authentication and the wire
%%% format) per tool call. This module builds commands from the adapter's parts
%%% (iodata and `{literal, Binary}'), counts the traffic, and returns the
%%% library's parsed untagged responses.
-module(mailio_mcp_imap_io).

-export([open/1, close/1, cmd/2, caps/1, has_cap/2, quote/1, idle_wait/2]).
-export([utf7_decode/1, utf7_encode/1, tokens_to_term/1]).

-type conn() :: #{pid := pid(), account := binary(), caps := [binary()]}.
-export_type([conn/0]).

%%====================================================================
%% Connection
%%====================================================================

-spec open(map()) -> {ok, conn()} | {error, term()}.
open(#{id := Id, incoming := In, auth := Auth}) ->
    Cfg0 = mailio_mcp_net:config(In, Auth),
    Tls = maps:get(tls, Cfg0),
    Cfg = Cfg0#{
        port => maps:get(port, Cfg0, default_port(Tls)),
        io_hook => fun
            (sent, N) -> mailio_mcp_stats:bump(Id, imap, 0, N);
            (received, N) -> mailio_mcp_stats:bump(Id, imap, 0, N)
        end
    },
    {ok, Pid} = mailio_imap_conn:start_link(Cfg),
    C = #{pid => Pid, account => Id, caps => []},
    case cmd(C, [<<"CAPABILITY">>]) of
        {ok, Events, _} ->
            {ok, C#{caps => capabilities(Events)}};
        {error, _} = E ->
            close(C),
            E;
        Other ->
            close(C),
            {error, Other}
    end.

default_port(true) -> 993;
default_port(_) -> 143.

capabilities(Events) ->
    lists:append([[string:uppercase(X) || X <- Caps] || {capability, Caps} <- Events]).

-spec close(conn()) -> ok.
close(#{pid := Pid}) ->
    _ =
        try
            mailio_imap_conn:run(Pid, fun(Tag) -> {[Tag, <<" LOGOUT\r\n">>], undefined} end, 2000)
        catch
            _:_ -> ok
        end,
    try
        mailio_imap_conn:close(Pid)
    catch
        _:_ -> ok
    end,
    ok.

caps(#{caps := Caps}) -> Caps.
has_cap(#{caps := Caps}, Cap) -> lists:member(Cap, Caps).

%%====================================================================
%% Commands
%%====================================================================

%% @doc Run one command. Parts is a list of iodata and `{literal, Binary}'.
%% Returns the parsed untagged responses and the tagged completion text.
-spec cmd(conn(), list()) ->
    {ok, [term()], binary()} | {no, binary()} | {bad, binary()} | {error, term()}.
cmd(#{pid := Pid, account := Id}, Parts) ->
    try mailio_imap_conn:run(Pid, fun(Tag) -> build(Tag, Parts) end) of
        {ok, Events, {Status, _Code, Text}} ->
            %% counted once the server has answered, so an offline account adds nothing
            mailio_mcp_stats:bump(Id, imap, 1, 0),
            case Status of
                ok -> {ok, Events, Text};
                no -> {no, Text};
                _ -> {bad, Text}
            end;
        {error, _} = E ->
            E
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, connection_lost};
        exit:Reason -> {error, Reason}
    end.

%% @doc Hold the selected mailbox in IDLE until the server reports a change or
%% `Timeout' milliseconds pass. Returns `changed' or `timeout'. The mailbox
%% must already be selected.
-spec idle_wait(conn(), non_neg_integer()) -> changed | timeout | {error, term()}.
idle_wait(#{pid := Pid, account := Id}, Timeout) ->
    case mailio_imap_conn:idle_start(Pid, self()) of
        ok ->
            mailio_mcp_stats:bump(Id, imap, 1, 0),
            Result = wait_event(Pid, Timeout),
            _ = mailio_imap_conn:idle_stop(Pid),
            Result;
        {error, _} = E ->
            E
    end.

%% Anything the server volunteers about the mailbox wakes the waiter, except
%% plain status lines (keep-alives). Waking early only costs one comparison.
wait_event(Pid, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_event(Pid, Deadline, Timeout).

wait_event(Pid, Deadline, Left) ->
    receive
        {imap_idle_event, Pid, {status_resp, _, _, _}} ->
            wait_event(Pid, Deadline, max(0, Deadline - erlang:monotonic_time(millisecond)));
        {imap_idle_event, Pid, _Event} ->
            changed
    after Left ->
        timeout
    end.

%% The command as the library connection wants it: the first chunk up to a
%% literal, then one reply per continuation. Literals are synchronizing, so
%% they work with every server.
build(Tag, Parts) ->
    {Segments, Literals} = split(Parts, [], [], []),
    [First | Rest] = Segments,
    case Literals of
        [] ->
            {[Tag, <<" ">>, First, <<"\r\n">>], undefined};
        [L0 | _] ->
            Head = [Tag, <<" ">>, First, spec(L0)],
            {Head, replies(Literals, Rest)}
    end.

replies([L], [Seg]) ->
    [[L, Seg, <<"\r\n">>]];
replies([L, Next | Ls], [Seg | Segs]) ->
    [[L, Seg, spec(Next)] | replies([Next | Ls], Segs)].

spec(Literal) -> [<<"{">>, integer_to_binary(byte_size(Literal)), <<"}\r\n">>].

split([], Cur, Segs, Lits) ->
    {lists:reverse([lists:reverse(Cur) | Segs]), lists:reverse(Lits)};
split([{literal, B} | Rest], Cur, Segs, Lits) ->
    split(Rest, [], [lists:reverse(Cur) | Segs], [B | Lits]);
split([P | Rest], Cur, Segs, Lits) ->
    split(Rest, [P | Cur], Segs, Lits).

%% @doc Quote a string for use in a command. Non-ASCII or control bytes must
%% go as {literal, _} instead.
-spec quote(binary()) -> iodata() | {literal, binary()}.
quote(Bin) ->
    case re:run(Bin, <<"[^\\x20-\\x7e]">>) of
        nomatch ->
            [
                <<"\"">>,
                binary:replace(
                    binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]), <<"\"">>, <<"\\\"">>, [
                        global
                    ]
                ),
                <<"\"">>
            ];
        _ ->
            {literal, Bin}
    end.

%% @doc The library's tokens in the shape the BODYSTRUCTURE walker uses:
%% lists, `{s, Binary}' for strings, binaries for atoms and numbers, `nil'.
-spec tokens_to_term(term()) -> term().
tokens_to_term({list, L}) -> [tokens_to_term(X) || X <- L];
tokens_to_term({string, B}) -> {s, B};
tokens_to_term({atom, B}) -> B;
tokens_to_term({number, N}) -> integer_to_binary(N);
tokens_to_term(nil) -> nil;
tokens_to_term(L) when is_list(L) -> [tokens_to_term(X) || X <- L];
tokens_to_term(B) when is_binary(B) -> B.

%%====================================================================
%% Modified UTF-7 mailbox names (RFC 3501 5.1.3)
%%====================================================================

utf7_decode(Bin) ->
    case binary:match(Bin, <<"&">>) of
        nomatch -> Bin;
        _ -> unicode:characters_to_binary(u7d(Bin, []))
    end.

u7d(<<>>, Acc) ->
    lists:reverse(Acc);
u7d(<<"&-", R/binary>>, Acc) ->
    u7d(R, [$& | Acc]);
u7d(<<$&, R/binary>>, Acc) ->
    case binary:split(R, <<"-">>) of
        [B64, Rest] ->
            B = binary:replace(B64, <<",">>, <<"/">>, [global]),
            Pad = binary:copy(<<"=">>, (4 - byte_size(B) rem 4) rem 4),
            Utf16 = base64:decode(<<B/binary, Pad/binary>>),
            Chars = unicode:characters_to_list(Utf16, {utf16, big}),
            u7d(Rest, lists:reverse(Chars) ++ Acc);
        _ ->
            lists:reverse(binary_to_list(R)) ++ Acc
    end;
u7d(<<C/utf8, R/binary>>, Acc) ->
    u7d(R, [C | Acc]);
u7d(<<C, R/binary>>, Acc) ->
    u7d(R, [C | Acc]).

utf7_encode(Bin) ->
    case re:run(Bin, <<"[^\\x20-\\x7e]|&">>) of
        nomatch -> Bin;
        _ -> iolist_to_binary(u7e(unicode:characters_to_list(Bin), []))
    end.

u7e([], Acc) ->
    lists:reverse(Acc);
u7e([$& | R], Acc) ->
    u7e(R, [<<"&-">> | Acc]);
u7e([C | R], Acc) when C >= 16#20, C =< 16#7e -> u7e(R, [<<C>> | Acc]);
u7e(L, Acc) ->
    {NonAscii, Rest} = lists:splitwith(fun(C) -> C < 16#20 orelse C > 16#7e end, L),
    B = base64:encode(unicode:characters_to_binary(NonAscii, utf8, {utf16, big}), #{
        padding => false
    }),
    u7e(Rest, [<<"&", (binary:replace(B, <<"/">>, <<",">>, [global]))/binary, "-">> | Acc]).
