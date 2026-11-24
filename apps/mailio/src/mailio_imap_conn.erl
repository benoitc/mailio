%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
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

-export([
    start_link/1,
    run/2, run/3,
    idle_start/2,
    idle_stop/1,
    capabilities/1,
    close/1
]).
-export([callback_mode/0, init/1, terminate/3]).
-export([
    connect/3,
    greeting/3,
    starttls/3,
    auth/3,
    auth_failed/3,
    tls_failed/3,
    response_too_large/3,
    ready/3,
    running/3,
    idle/3,
    backoff/3
]).

-define(CONNECT_TIMEOUT, 30000).
-define(CMD_TIMEOUT, 30000).
-define(BACKOFF_MIN, 1000).
-define(BACKOFF_MAX, 300000).

-record(data, {
    config :: map(),
    transport :: gen_tcp | ssl,
    sock :: term() | undefined,
    buffer = <<>> :: binary(),
    tagn = 0 :: non_neg_integer(),
    from :: gen_statem:from() | undefined,
    tag :: binary() | undefined,
    untagged = [] :: [term()],
    literal :: binary() | [binary()] | undefined,
    caps = [] :: [binary()],
    notify :: pid() | undefined,
    unsolicited = [] :: [term()],
    backoff = ?BACKOFF_MIN :: pos_integer()
}).

%%====================================================================
%% API
%%====================================================================

%% Config: #{host, port, tls => true | starttls | false, notify => pid(),
%%           io_hook => fun((sent | received, non_neg_integer()) -> term()),
%%           credentials => mailio_credentials:cred(),
%%           verify => verify_peer | verify_none, cacerts | cacertfile}.
%% Credentials are `{password, User, Pass}' (LOGIN) or `{oauth2, User, Token}'
%% (AUTHENTICATE XOAUTH2). `username' and `password' keys still work. TLS
%% certificates and host names are verified unless `verify' says otherwise.
%% A server that refuses the credentials is not retried: later calls return
%% `{error, authentication_failed}'. The same goes for a TLS failure (an
%% untrusted certificate, a wrong host name): `{error, tls_failed}'. With
%% `tls => starttls' the connection is upgraded before any credential is sent,
%% and refused if the server does not offer STARTTLS.
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
    case gen_statem:call(Pid, capabilities) of
        [] ->
            %% A server need not announce its capabilities with the login reply:
            %% ask once, then answer from what the connection learned.
            _ = run(Pid, fun(Tag) -> {mailio_imap_proto:capability(Tag), undefined} end),
            gen_statem:call(Pid, capabilities);
        Caps ->
            Caps
    end.

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
    Transport =
        case maps:get(tls, Config, false) of
            true -> ssl;
            _ -> gen_tcp
        end,
    Data = #data{
        config = Config,
        transport = Transport,
        notify = maps:get(notify, Config, undefined)
    },
    {ok, connect, Data}.

terminate(_Reason, _State, #data{sock = undefined}) ->
    ok;
terminate(_Reason, _State, #data{transport = T, sock = Sock}) ->
    _ = catch_close(T, Sock),
    ok.

%%====================================================================
%% State: connect
%%====================================================================

connect(enter, _Old, Data) ->
    {keep_state, Data, [{state_timeout, 0, do_connect}]};
connect(state_timeout, do_connect, Data) ->
    case do_connect(Data) of
        {ok, Data1} -> {next_state, greeting, Data1};
        {error, {tls_alert, _}} -> {next_state, tls_failed, Data};
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
    Host = binary_to_list(maps:get(host, Config)),
    case maps:get(verify, Config, verify_peer) of
        verify_none ->
            [{verify, verify_none}];
        verify_peer ->
            CA =
                case {maps:find(cacerts, Config), maps:find(cacertfile, Config)} of
                    {{ok, Certs}, _} -> [{cacerts, Certs}];
                    {_, {ok, F}} -> [{cacertfile, F}];
                    _ -> [{cacerts, public_key:cacerts_get()}]
                end,
            [
                {verify, verify_peer},
                {customize_hostname_check, [
                    {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                ]},
                {server_name_indication, Host}
                | CA
            ]
    end.

%% The credentials from the config. A token_fun is resolved by
%% mailio_credentials in a process of its own, with a depth and time limit, so
%% a provider cannot make this process loop or wait for ever.
credentials(#{credentials := Cred} = Config) ->
    case mailio_credentials:resolve(Cred, cred_opts(Config)) of
        {ok, Resolved} -> Resolved;
        {error, _} = E -> E
    end;
credentials(#{username := User, password := Pass}) ->
    {password, User, Pass};
credentials(_) ->
    {error, no_credentials}.

cred_opts(#{credentials_timeout := T}) -> #{timeout => T};
cred_opts(_) -> #{}.

%%====================================================================
%% State: greeting
%%====================================================================

greeting(enter, _Old, Data) ->
    {keep_state, set_active(Data)};
greeting(info, {Tag, Sock, Bin}, #data{sock = Sock} = Data) when
    Tag =:= tcp; Tag =:= ssl
->
    Data1 = set_active(append_buf(Data, Bin)),
    case take_one(Data1) of
        {ok, {untagged, {status_resp, ok, _Code, _Text}}, Data2} ->
            {next_state, after_greeting(Data2), Data2};
        {ok, {untagged, {status_resp, preauth, _, _}}, Data2} ->
            {next_state, ready, Data2};
        {ok, _Other, Data2} ->
            {next_state, backoff, Data2};
        {error, response_too_large} ->
            {next_state, response_too_large, Data1};
        more ->
            {keep_state, Data1}
    end;
greeting(info, Event, Data) ->
    handle_socket_closed(Event, Data);
greeting({call, _From}, _Req, Data) ->
    {keep_state, Data, [{postpone, true}]}.

after_greeting(#data{config = #{tls := starttls}, transport = gen_tcp}) -> starttls;
after_greeting(_) -> auth.

%%====================================================================
%% State: starttls (upgrade the connection before any credential is sent)
%%====================================================================

starttls(enter, _Old, Data) ->
    {Tag, Data1} = next_tag(Data),
    _ = send(Data1, mailio_imap_proto:starttls(Tag)),
    {keep_state, Data1#data{tag = Tag, untagged = []}};
starttls(info, {T, Sock, Bin}, #data{sock = Sock} = Data) when
    T =:= tcp; T =:= ssl
->
    process_until_tagged(
        Data,
        Bin,
        fun
            (ok, _Code, _Text, Data1) -> upgrade(Data1#data{tag = undefined});
            (_Status, _Code, _Text, Data1) -> {next_state, tls_failed, Data1#data{tag = undefined}}
        end
    );
starttls(info, Event, Data) ->
    handle_socket_closed(Event, Data);
starttls({call, _From}, _Req, Data) ->
    {keep_state, Data, [{postpone, true}]}.

upgrade(#data{sock = Sock, config = Config} = Data) ->
    ok = inet:setopts(Sock, [{active, false}]),
    case ssl:connect(Sock, mailio_tls_opts(Config), ?CONNECT_TIMEOUT) of
        {ok, SslSock} ->
            {next_state, auth,
                set_active(Data#data{transport = ssl, sock = SslSock, buffer = <<>>})};
        {error, _Reason} ->
            {next_state, tls_failed, Data}
    end.

%%====================================================================
%% State: auth
%%====================================================================

auth(enter, _Old, #data{config = Config} = Data) ->
    {Tag, Data1} = next_tag(Data),
    case credentials(Config) of
        {password, User, Pass} ->
            _ = send(Data1, mailio_imap_proto:login(Tag, User, Pass)),
            {keep_state, Data1#data{tag = Tag, untagged = []}};
        {oauth2, User, Token} ->
            _ = send(Data1, mailio_imap_proto:authenticate_xoauth2(Tag)),
            %% the token answers the first `+'; an error challenge after it is
            %% answered with an empty line, which ends the exchange
            Replies = [
                iolist_to_binary(mailio_imap_proto:xoauth2_response(User, Token)), <<"\r\n">>
            ],
            {keep_state, Data1#data{tag = Tag, untagged = [], literal = Replies}};
        {error, _} ->
            %% a state change is not allowed from an enter call (nor a next_event):
            %% a zero state timeout makes the change the next thing that happens
            {keep_state, Data1, [{state_timeout, 0, credentials_failed}]}
    end;
auth(state_timeout, credentials_failed, Data) ->
    {next_state, auth_failed, Data};
auth(info, {T, Sock, Bin}, #data{sock = Sock} = Data) when
    T =:= tcp; T =:= ssl
->
    process_until_tagged(
        Data,
        Bin,
        fun(Status, _Code, _Text, Data1) ->
            case Status of
                ok -> {next_state, ready, Data1#data{tag = undefined, literal = undefined}};
                _ -> {next_state, auth_failed, Data1#data{tag = undefined, literal = undefined}}
            end
        end
    );
auth(info, Event, Data) ->
    handle_socket_closed(Event, Data);
auth({call, _From}, _Req, Data) ->
    {keep_state, Data, [{postpone, true}]}.

%%====================================================================
%% State: auth_failed (terminal: the server refused the credentials)
%%====================================================================

auth_failed(enter, _Old, #data{transport = T, sock = Sock} = Data) ->
    _ = catch_close(T, Sock),
    {keep_state, Data#data{sock = undefined}};
auth_failed({call, From}, _Req, Data) ->
    {keep_state, Data, [{reply, From, {error, authentication_failed}}]};
auth_failed(_Type, _Event, Data) ->
    {keep_state, Data}.

%%====================================================================
%% State: tls_failed (terminal: the TLS handshake was refused)
%%====================================================================

tls_failed(enter, _Old, #data{transport = T, sock = Sock} = Data) ->
    _ =
        case Sock of
            undefined -> ok;
            _ -> catch_close(T, Sock)
        end,
    {keep_state, Data#data{sock = undefined}};
tls_failed({call, From}, _Req, Data) ->
    {keep_state, Data, [{reply, From, {error, tls_failed}}]};
tls_failed(_Type, _Event, Data) ->
    {keep_state, Data}.

%%====================================================================
%% State: response_too_large (terminal: the server sent more than allowed)
%%====================================================================

response_too_large(enter, _Old, #data{transport = T, sock = Sock, from = From} = Data) ->
    _ =
        case Sock of
            undefined -> ok;
            _ -> catch_close(T, Sock)
        end,
    Replies =
        case From of
            undefined -> [];
            _ -> [{reply, From, {error, response_too_large}}]
        end,
    {keep_state, Data#data{sock = undefined, buffer = <<>>, from = undefined}, Replies};
response_too_large({call, From}, _Req, Data) ->
    {keep_state, Data, [{reply, From, {error, response_too_large}}]};
response_too_large(_Type, _Event, Data) ->
    {keep_state, Data}.

%%====================================================================
%% State: ready
%%====================================================================

ready(enter, _Old, Data) ->
    {keep_state, Data#data{from = undefined, tag = undefined, untagged = []}};
ready({call, From}, {run, Builder}, Data) ->
    {Tag, Data1} = next_tag(Data),
    {IoData, Literal} = Builder(Tag),
    send(Data1, IoData),
    {next_state, running, Data1#data{from = From, tag = Tag, untagged = [], literal = Literal}};
ready({call, From}, capabilities, Data) ->
    {keep_state, Data, [{reply, From, Data#data.caps}]};
ready({call, From}, {idle_start, NotifyPid}, Data) ->
    {Tag, Data1} = next_tag(Data),
    send(Data1, mailio_imap_proto:idle(Tag)),
    {next_state, idle, Data1#data{from = From, tag = Tag, notify = NotifyPid, untagged = []}};
ready({call, From}, idle_stop, Data) ->
    {keep_state, Data, [{reply, From, ok}]};
ready(info, {T, Sock, Bin}, #data{sock = Sock} = Data) when
    T =:= tcp; T =:= ssl
->
    %% Unsolicited data while idle-at-ready: buffer and drop framed responses.
    Data1 = set_active(append_buf(Data, Bin)),
    case drain_unsolicited(Data1) of
        {ok, Data2} -> {keep_state, Data2};
        {error, response_too_large} -> {next_state, response_too_large, Data1}
    end;
ready(info, Event, Data) ->
    handle_socket_closed(Event, Data).

%%====================================================================
%% State: running
%%====================================================================

running(enter, _Old, Data) ->
    {keep_state, Data};
running(info, {T, Sock, Bin}, #data{sock = Sock} = Data) when
    T =:= tcp; T =:= ssl
->
    process_until_tagged(
        Data,
        Bin,
        fun(Status, Code, Text, Data1) ->
            Reply = {ok, lists:reverse(Data1#data.untagged), {Status, Code, Text}},
            {next_state, ready, Data1, [{reply, Data1#data.from, Reply}]}
        end
    );
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
idle(info, {T, Sock, Bin}, #data{sock = Sock} = Data) when
    T =:= tcp; T =:= ssl
->
    Data1 = set_active(append_buf(Data, Bin)),
    handle_idle_responses(Data1);
idle(info, Event, Data) ->
    handle_socket_closed(Event, Data).

handle_idle_responses(Data) ->
    handle_idle_responses(Data, []).

handle_idle_responses(Data, Acts) ->
    case take_one(Data) of
        more ->
            {keep_state, Data, Acts};
        {error, response_too_large} ->
            {next_state, response_too_large, Data, Acts};
        {ok, {continuation, _Text}, Data1} ->
            %% Server accepted IDLE: acknowledge the idle_start caller now,
            %% while staying in the idle state.
            {Data2, A} = ack_from(Data1),
            handle_idle_responses(Data2, Acts ++ A);
        {ok, {tagged, Tag, _Status, _}, Data1} when Tag =:= Data#data.tag ->
            %% IDLE completed (after DONE): return to ready, ack the stopper.
            {Data2, A} = ack_from(Data1),
            {next_state, ready, Data2#data{tag = undefined}, Acts ++ A};
        {ok, {untagged, Event}, Data1} ->
            _ = notify_idle(Data1, Event),
            handle_idle_responses(Data1, Acts);
        {ok, _Other, Data1} ->
            handle_idle_responses(Data1, Acts)
    end.

ack_from(#data{from = undefined} = Data) -> {Data, []};
ack_from(#data{from = From} = Data) -> {Data#data{from = undefined}, [{reply, From, ok}]}.

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
        {error, response_too_large} ->
            {next_state, response_too_large, Data};
        {ok, {continuation, _Text}, Data1} ->
            case Data1#data.literal of
                undefined ->
                    loop_responses(Data1, Done);
                [Next | Rest] ->
                    %% a scripted exchange (SASL): one reply per continuation
                    send(Data1, Next),
                    loop_responses(Data1#data{literal = Rest}, Done);
                [] ->
                    loop_responses(Data1, Done);
                Lit ->
                    send(Data1, Lit),
                    loop_responses(Data1#data{literal = undefined}, Done)
            end;
        {ok, {tagged, Tag, Status, #{code := Code, text := Text}}, Data1} when
            Tag =:= Data#data.tag
        ->
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
        more -> {ok, Data};
        {error, response_too_large} -> {error, response_too_large};
        {ok, _Resp, Data1} -> drain_unsolicited(Data1)
    end.

%% Frame and parse a single response from the buffer.
take_one(#data{buffer = Buf, config = Config} = Data) ->
    case mailio_imap_proto:read_response(Buf, Config) of
        more ->
            more;
        {error, response_too_large} ->
            {error, response_too_large};
        {ok, Line, Rest} ->
            Resp = mailio_imap_proto:parse_response(Line),
            {ok, Resp, Data#data{buffer = Rest}}
    end.

%%====================================================================
%% Socket helpers
%%====================================================================

set_active(#data{transport = gen_tcp, sock = Sock} = Data) ->
    _ = inet:setopts(Sock, [{active, once}]),
    Data;
set_active(#data{transport = ssl, sock = Sock} = Data) ->
    _ = ssl:setopts(Sock, [{active, once}]),
    Data.

append_buf(#data{buffer = Buf} = Data, Bin) ->
    io_hook(Data, received, byte_size(Bin)),
    Data#data{buffer = <<Buf/binary, Bin/binary>>}.

io_hook(#data{config = #{io_hook := Hook}}, Dir, Bytes) when is_function(Hook, 2) ->
    _ = Hook(Dir, Bytes),
    ok;
io_hook(_Data, _Dir, _Bytes) ->
    ok.

send(#data{transport = Transport, sock = Sock} = Data, IoData) ->
    io_hook(Data, sent, iolist_size(IoData)),
    Transport:send(Sock, IoData).

next_tag(#data{tagn = N} = Data) ->
    Tag = iolist_to_binary([$A, integer_to_binary(N + 1)]),
    {Tag, Data#data{tagn = N + 1}}.

catch_close(gen_tcp, Sock) ->
    try
        gen_tcp:close(Sock)
    catch
        _:_ -> ok
    end;
catch_close(ssl, Sock) ->
    try
        ssl:close(Sock)
    catch
        _:_ -> ok
    end.

handle_socket_closed({Closed, _Sock}, Data) when
    Closed =:= tcp_closed; Closed =:= ssl_closed
->
    {next_state, backoff, Data#data{sock = undefined, buffer = <<>>}};
handle_socket_closed({Err, _Sock, _Reason}, Data) when
    Err =:= tcp_error; Err =:= ssl_error
->
    {next_state, backoff, Data#data{sock = undefined, buffer = <<>>}};
handle_socket_closed(_Other, Data) ->
    {keep_state, Data}.

reply_error_and(Event, #data{from = From} = Data) ->
    Replies =
        case From of
            undefined -> [];
            _ -> [{reply, From, {error, connection_lost}}]
        end,
    case handle_socket_closed(Event, Data) of
        {next_state, S, Data1} -> {next_state, S, Data1#data{from = undefined}, Replies};
        Other -> Other
    end.
