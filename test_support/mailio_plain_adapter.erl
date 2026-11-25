%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc An adapter that does what an older one would: it has no way to fetch a
%%% message under a UIDVALIDITY (no fetch_message/5). For a test that the store
%%% refuses to trust such an adapter with UIDs it listed under a UIDVALIDITY.
-module(mailio_plain_adapter).

-export([
    connect/1,
    close/1,
    capabilities/1,
    list_mailboxes/1,
    fetch_changes_since/4,
    fetch_message/4
]).

connect(Config) -> mailio_imap:connect(Config).
close(Conn) -> mailio_imap:close(Conn).
capabilities(Conn) -> mailio_imap:capabilities(Conn).
list_mailboxes(Conn) -> mailio_imap:list_mailboxes(Conn).
fetch_changes_since(Conn, Box, State, Opts) ->
    mailio_imap:fetch_changes_since(Conn, Box, State, Opts).
fetch_message(Conn, Box, Uid, Sink) -> mailio_imap:fetch_message(Conn, Box, Uid, Sink).
