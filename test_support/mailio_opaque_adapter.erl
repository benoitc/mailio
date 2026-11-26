%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc An adapter whose message ids are opaque binaries, not numbers, as a
%%% provider that is not IMAP would have. It has no network: the messages are
%%% in the `mailio_store' env key `opaque_messages' (`#{Id => Raw}'). For a test
%%% that the store does not assume ids are integers.
-module(mailio_opaque_adapter).

-export([
    connect/1,
    close/1,
    capabilities/1,
    list_mailboxes/1,
    fetch_changes_since/4,
    fetch_message/4,
    list_uids/2
]).

connect(_Config) -> {ok, #{}}.
close(_Conn) -> ok.
capabilities(_Conn) -> #{}.

list_mailboxes(_Conn) ->
    {ok, [
        #{
            id => <<"INBOX">>,
            name => <<"INBOX">>,
            role => inbox,
            parent_id => null,
            delimiter => <<"/">>,
            attrs => []
        }
    ]}.

messages() -> application:get_env(mailio_store, opaque_messages, #{}).

fetch_changes_since(_Conn, _Box, _State, _Opts) ->
    Ids = lists:sort(maps:keys(messages())),
    State = term_to_binary({opaque_state, length(Ids)}),
    {ok, [{added, #{uid => Id, keywords => []}} || Id <- Ids], State, done}.

fetch_message(_Conn, _Box, Id, Sink) ->
    case maps:find(Id, messages()) of
        {ok, Raw} ->
            Sink(Raw),
            {ok, #{size => byte_size(Raw)}};
        error ->
            {error, not_found}
    end.

list_uids(_Conn, _Box) -> {ok, lists:sort(maps:keys(messages()))}.
