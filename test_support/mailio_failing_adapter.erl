%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc The IMAP adapter with a switch that makes a full re-read of a mailbox
%%% fail, to test that a sync which cannot finish does not move its cursor.
%%% The switch is the `mailio_store' env key `fail_full_read'.
-module(mailio_failing_adapter).

-export([
    connect/1,
    close/1,
    capabilities/1,
    list_mailboxes/1,
    fetch_changes_since/4,
    fetch_message/4,
    fetch_message/5,
    list_uids/2,
    watch/3,
    unwatch/2
]).

connect(Config) -> mailio_imap:connect(Config).
close(Conn) -> mailio_imap:close(Conn).
capabilities(Conn) -> mailio_imap:capabilities(Conn).
list_mailboxes(Conn) -> mailio_imap:list_mailboxes(Conn).
fetch_message(Conn, Box, Uid, Sink) -> mailio_imap:fetch_message(Conn, Box, Uid, Sink).
fetch_message(Conn, Box, Uid, Sink, Opts) -> mailio_imap:fetch_message(Conn, Box, Uid, Sink, Opts).
list_uids(Conn, Box) -> mailio_imap:list_uids(Conn, Box).
watch(Conn, Box, Pid) -> mailio_imap:watch(Conn, Box, Pid).
unwatch(Conn, Ref) -> mailio_imap:unwatch(Conn, Ref).

fetch_changes_since(Conn, Box, initial, Opts) ->
    %% a hook for a test to change the server between two reads
    case application:get_env(mailio_store, before_full_read) of
        {ok, Hook} -> Hook();
        undefined -> ok
    end,
    case application:get_env(mailio_store, fail_full_read, false) of
        true -> {error, {imap, simulated_failure}};
        false -> mailio_imap:fetch_changes_since(Conn, Box, initial, Opts)
    end;
fetch_changes_since(Conn, Box, State, Opts) ->
    mailio_imap:fetch_changes_since(Conn, Box, State, Opts).
