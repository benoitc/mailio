%%% @doc IMAP connection FSM (gen_statem).
%%%
%%% Owns one TCP/TLS socket and serializes commands over it. The core
%%% primitive is {@link run/3}: the caller supplies a builder that, given a
%%% freshly allocated tag, returns the command bytes (and optional literal
%%% payload to send after a `+' continuation). The FSM sends the command,
%%% accumulates untagged responses, and replies with them plus the matching
%%% tagged result. Response interpretation lives in {@link mailio_imap} so
%%% this module only deals with framing and command/response correlation.
%%%
%%% States: connect -> greeting -> auth -> ready; `running' while a command
%%% is in flight; `idle' while in IDLE; `backoff' between reconnect attempts.
-module(mailio_imap_conn).
-behaviour(gen_statem).

-export([start_link/1, run/2, run/3, idle_start/2, idle_stop/1, capabilities/1,
         close/1]).
-export([callback_mode/0, init/1, terminate/3]).
-export([connect/3, greeting/3, auth/3, ready/3, running/3, idle/3, backoff/3]).

-define(CONNECT_TIMEOUT, 30000).
-define(CMD_TIMEOUT, 30000).
-define(BACKOFF_MIN, 1000).
-define(BACKOFF_MAX, 300000).

-record(data, {config :: map(),
               transport :: gen_tcp | ssl,
               sock :: term() | undefined,
               buffer = <<>> :: binary(),
               tagn = 0 :: non_neg_integer(),
               from :: gen_statem:from() | undefined,
               tag :: binary() | undefined,
               untagged = [] :: [term()],
               literal :: binary() | undefined,
               caps = [] :: [binary()],
               notify :: pid() | undefined,
               unsolicited = [] :: [term()],
               backoff = ?BACKOFF_MIN :: pos_integer()}).

%%====================================================================
%% API
%%====================================================================

%% Config: #{host, port, tls => true | false | starttls, username, password,
%%           notify => pid()}.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

%% @doc Run a command. `Builder(Tag) -> {iodata(), Literal | undefined}'.
-spec run(pid(), fun((binary()) -> {iodata(), binary() | undefined})) ->
    {ok, [term()], {atom(), term(), binary()}} | {error, term()}.
run(Pid, Builder) ->
    run(Pid, Builder, ?CMD_TIMEOUT).

-spec run(pid(), fun((binary()) -> {iodata(), binary() | undefined}), timeout()) ->
    {ok, [term()], {atom(), term(), binary()}} | {error, term()}.
run(Pid, Builder, Timeout) ->
    gen_statem:call(Pid, {run, Builder}, Timeout).

-spec capabilities(pid()) -> [binary()].
capabilities(Pid) ->
    gen_statem:call(Pid, capabilities).

%% @doc Enter IDLE; unsolicited events are sent to NotifyPid as
%% `{imap_idle_event, self(), Event}'.
-spec idle_start(pid(), pid()) -> ok | {error, term()}.
idle_start(Pid, NotifyPid) ->
    gen_statem:call(Pid, {idle_start, NotifyPid}).

-spec idle_stop(pid()) -> ok.
idle_stop(Pid) ->
    gen_statem:call(Pid, idle_stop).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_statem:stop(Pid).

%%====================================================================
%% gen_statem
%%====================================================================

callback_mode() -> [state_functions, state_enter].

init(Config) ->
    Transport = case maps:get(tls, Config, false) of
                    true -> ssl;
                    _ -> gen_tcp
                end,
    Data = #data{config = Config, transport = Transport,
                 notify = maps:get(notify, Config, undefined)},
    {ok, connect, Data}.

terminate(_Reason, _State, #data{sock = undefined}) -> ok;
terminate(_Reason, _State, #data{transport = T, sock = Sock}) ->
    catch_close(T, Sock),
    ok.

%%====================================================================
%% State: connect
%%====================================================================

connect(enter, _Old, Data) ->
    {keep_state, Data, [{state_timeout, 0, do_connect}]};
connect(state_timeout, do_connect, Data) ->
    case do_connect(Data) of
        {ok, Data1} -> {next_state, greeting, Data1};
        {error, _Reason} -> {next_state, backoff, Data}
    end;
connect({call, From}, _Req, Data) ->
    {keep_state, Data, [{reply, From, {error, not_connected}}]};
connect(_Type, _Event, Data) ->
    {keep_state, Data}.

do_connect(#data{config = Config, transport = Transport} = Data) ->
    Host = binary_to_list(maps:get(host, Config)),
    Port = maps:get(port, Config),
    TcpOpts = [binary, {active, once}, {packet, raw}, {keepalive, true}],
    case Transport of
        gen_tcp ->
            case gen_tcp:connect(Host, Port, TcpOpts, ?CONNECT_TIMEOUT) of
                {ok, Sock} -> {ok, Data#data{sock = Sock}};
                {error, _} = E -> E
            end;
        ssl ->
            SslOpts = TcpOpts ++ mailio_tls_opts(Config),
            case ssl:connect(Host, Port, SslOpts, ?CONNECT_TIMEOUT) of
                {ok, Sock} -> {ok, Data#data{sock = Sock}};
                {error, _} = E -> E
            end
    end.

mailio_tls_opts(Config) ->
    case maps:get(verify, Config, verify_none) of
        verify_none -> [{verify, verify_none}];
        verify_peer ->
            [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
             {server_name_indication, binary_to_list(maps:get(host, Config))}]
    end.

%%====================================================================
%% State: greeting
%%====================================================================

greeting(enter, _Old, Data) ->
    {keep_state, set_active(Data)};
greeting(info, {Tag, Sock, Bin}, #data{sock = Sock} = Data)
  when Tag =:= tcp; Tag =:= ssl ->
    Data1 = set_active(append_buf(Data, Bin)),
    case take_one(Data1) of
        {ok, {untagged, {status_resp, ok, _Code, _Text}}, Data2} ->
            {next_state, auth, Data2};
        {ok, {untagged, {status_resp, preauth, _, _}}, Data2} ->
            {next_state, ready, Data2};
        {ok, _Other, Data2} ->
            {next_state, backoff, Data2};
        more ->
            {keep_state, Data1}
    end;
greeting(info, Event, Data) ->
    handle_socket_closed(Event, Data);
greeting({call, _From}, _Req, Data) ->
    {keep_state, Data, [{postpone, true}]}.

%%====================================================================
%% State: auth
%%====================================================================

auth(enter, _Old, #data{config = Config} = Data) ->
    User = maps:get(username, Config),
    Pass = maps:get(password, Config),
    {Tag, Data1} = next_tag(Data),
    send(Data1, mailio_imap_proto:login(Tag, User, Pass)),
    {keep_state, Data1#data{tag = Tag, untagged = []}};
auth(info, {T, Sock, Bin}, #data{sock = Sock} = Data)
  when T =:= tcp; T =:= ssl ->
    process_until_tagged(Data, Bin,
        fun(Status, _Code, _Text, Data1) ->
            case Status of
                ok -> {next_state, ready, Data1#data{tag = undefined}};
                _ -> {next_state, backoff, Data1#data{tag = undefined}}
            end
        end);
auth(info, Event, Data) ->
    handle_socket_closed(Event, Data);
auth({call, _From}, _Req, Data) ->
    {keep_state, Data, [{postpone, true}]}.

%%====================================================================
%% State: ready
%%====================================================================

ready(enter, _Old, Data) ->
    {keep_state, Data#data{from = undefined, tag = undefined, untagged = []}};
ready({call, From}, {run, Builder}, Data) ->
    {Tag, Data1} = next_tag(Data),
    {IoData, Literal} = Builder(Tag),
    send(Data1, IoData),
    {next_state, running,
     Data1#data{from = From, tag = Tag, untagged = [], literal = Literal}};
ready({call, From}, capabilities, Data) ->
    {keep_state, Data, [{reply, From, Data#data.caps}]};
ready({call, From}, {idle_start, NotifyPid}, Data) ->
    {Tag, Data1} = next_tag(Data),
    send(Data1, mailio_imap_proto:idle(Tag)),
    {next_state, idle,
     Data1#data{from = From, tag = Tag, notify = NotifyPid, untagged = []}};
ready({call, From}, idle_stop, Data) ->
    {keep_state, Data, [{reply, From, ok}]};
ready(info, {T, Sock, Bin}, #data{sock = Sock} = Data)
  when T =:= tcp; T =:= ssl ->
    %% Unsolicited data while idle-at-ready: buffer and drop framed responses.
    Data1 = set_active(append_buf(Data, Bin)),
    {keep_state, drain_unsolicited(Data1)};
ready(info, Event, Data) ->
    handle_socket_closed(Event, Data).

%%====================================================================
%% State: running
%%====================================================================

running(enter, _Old, Data) ->
    {keep_state, Data};
running(info, {T, Sock, Bin}, #data{sock = Sock} = Data)
  when T =:= tcp; T =:= ssl ->
    process_until_tagged(Data, Bin,
        fun(Status, Code, Text, Data1) ->
            Reply = {ok, lists:reverse(Data1#data.untagged), {Status, Code, Text}},
            {next_state, ready, Data1, [{reply, Data1#data.from, Reply}]}
        end);
running(info, Event, Data) ->
    reply_error_and(Event, Data);
running({call, _From}, _Req, Data) ->
    {keep_state, Data, [{postpone, true}]}.

%%====================================================================
%% State: idle
%%====================================================================

idle(enter, _Old, Data) ->
    {keep_state, Data};
idle({call, From}, idle_stop, Data) ->
    send(Data, mailio_imap_proto:idle_done()),
    %% Wait for the tagged completion of the IDLE command.
    {keep_state, Data#data{from = From}};
idle({call, _From}, _Req, Data) ->
    {keep_state, Data, [{postpone, true}]};
idle(info, {T, Sock, Bin}, #data{sock = Sock} = Data)
  when T =:= tcp; T =:= ssl ->
    Data1 = set_active(append_buf(Data, Bin)),
    handle_idle_responses(Data1);
idle(info, Event, Data) ->
    handle_socket_closed(Event, Data).

handle_idle_responses(Data) ->
    case take_one(Data) of
        more ->
            {keep_state, Data};
        {ok, {tagged, Tag, _Status, _}, Data1} when Tag =:= Data#data.tag ->
            %% IDLE completed (after DONE): return to ready, ack the stopper.
            Replies = case Data1#data.from of
                          undefined -> [];
                          From -> [{reply, From, ok}]
                      end,
            {next_state, ready, Data1#data{from = undefined, tag = undefined}, Replies};
        {ok, {untagged, Event}, Data1} ->
            notify_idle(Data1, Event),
            handle_idle_responses(Data1);
        {ok, _Other, Data1} ->
            handle_idle_responses(Data1)
    end.

notify_idle(#data{notify = Pid}, Event) when is_pid(Pid) ->
    Pid ! {imap_idle_event, self(), Event};
notify_idle(_Data, _Event) ->
    ok.

%%====================================================================
%% State: backoff
%%====================================================================

backoff(enter, _Old, #data{backoff = B} = Data) ->
    {keep_state, Data, [{state_timeout, B, retry}]};
backoff(state_timeout, retry, #data{backoff = B} = Data) ->
    NextB = min(B * 2, ?BACKOFF_MAX),
    {next_state, connect, Data#data{backoff = NextB, buffer = <<>>}};
backoff({call, From}, _Req, Data) ->
    {keep_state, Data, [{reply, From, {error, not_connected}}]};
backoff(_Type, _Event, Data) ->
    {keep_state, Data}.

%%====================================================================
%% Response processing
%%====================================================================

%% Append new bytes, then frame and process responses until the in-flight
%% command's tagged response arrives. Handles `+' continuations (literals).
process_until_tagged(Data0, Bin, Done) ->
    Data = set_active(append_buf(Data0, Bin)),
    loop_responses(Data, Done).

loop_responses(Data, Done) ->
    case take_one(Data) of
        more ->
            {keep_state, Data};
        {ok, {continuation, _Text}, Data1} ->
            case Data1#data.literal of
                undefined -> loop_responses(Data1, Done);
                Lit ->
                    send(Data1, Lit),
                    loop_responses(Data1#data{literal = undefined}, Done)
            end;
        {ok, {tagged, Tag, Status, #{code := Code, text := Text}}, Data1}
          when Tag =:= Data#data.tag ->
            Done(Status, Code, Text, Data1);
        {ok, {untagged, Event}, Data1} ->
            Data2 = Data1#data{untagged = [Event | Data1#data.untagged]},
            Data3 = maybe_capture_caps(Data2, Event),
            loop_responses(Data3, Done);
        {ok, _Other, Data1} ->
            loop_responses(Data1, Done)
    end.

maybe_capture_caps(Data, {capability, Caps}) -> Data#data{caps = Caps};
maybe_capture_caps(Data, _) -> Data.

%% Drain and discard any complete framed responses (used at ready state for
%% stray unsolicited data we are not actively collecting).
drain_unsolicited(Data) ->
    case take_one(Data) of
        more -> Data;
        {ok, _Resp, Data1} -> drain_unsolicited(Data1)
    end.

%% Frame and parse a single response from the buffer.
take_one(#data{buffer = Buf} = Data) ->
    case mailio_imap_proto:read_response(Buf) of
        more -> more;
        {ok, Line, Rest} ->
            Resp = mailio_imap_proto:parse_response(Line),
            {ok, Resp, Data#data{buffer = Rest}}
    end.

%%====================================================================
%% Socket helpers
%%====================================================================

set_active(#data{transport = gen_tcp, sock = Sock} = Data) ->
    inet:setopts(Sock, [{active, once}]), Data;
set_active(#data{transport = ssl, sock = Sock} = Data) ->
    ssl:setopts(Sock, [{active, once}]), Data.

append_buf(#data{buffer = Buf} = Data, Bin) ->
    Data#data{buffer = <<Buf/binary, Bin/binary>>}.

send(#data{transport = gen_tcp, sock = Sock}, IoData) -> gen_tcp:send(Sock, IoData);
send(#data{transport = ssl, sock = Sock}, IoData) -> ssl:send(Sock, IoData).

next_tag(#data{tagn = N} = Data) ->
    Tag = iolist_to_binary([$A, integer_to_binary(N + 1)]),
    {Tag, Data#data{tagn = N + 1}}.

catch_close(gen_tcp, Sock) -> try gen_tcp:close(Sock) catch _:_ -> ok end;
catch_close(ssl, Sock) -> try ssl:close(Sock) catch _:_ -> ok end.

handle_socket_closed({Closed, _Sock}, Data)
  when Closed =:= tcp_closed; Closed =:= ssl_closed ->
    {next_state, backoff, Data#data{sock = undefined, buffer = <<>>}};
handle_socket_closed({Err, _Sock, _Reason}, Data)
  when Err =:= tcp_error; Err =:= ssl_error ->
    {next_state, backoff, Data#data{sock = undefined, buffer = <<>>}};
handle_socket_closed(_Other, Data) ->
    {keep_state, Data}.

reply_error_and(Event, #data{from = From} = Data) ->
    Replies = case From of
                  undefined -> [];
                  _ -> [{reply, From, {error, connection_lost}}]
              end,
    case handle_socket_closed(Event, Data) of
        {next_state, S, Data1} -> {next_state, S, Data1#data{from = undefined}, Replies};
        Other -> Other
    end.
