# Use mailio on its own

This guide shows how to send a message, read a POP3 mailbox, run an IMAP command and parse a message with mailio and nothing else. You need it once, to get a first call working; the [overview](overview.md) lists everything the library offers.

Add the dependency and start `ssl`:

```erlang
%% rebar.config
{deps, [mailio]}.
```

```erlang
{ok, _} = application:ensure_all_started(ssl).
```

## Build and send a message

```erlang
Raw = mailio_mime_render:render(#{
    type => <<"text">>,
    subtype => <<"plain">>,
    charset => <<"utf-8">>,
    encoding => <<"7bit">>,
    headers => [
        {<<"From">>, <<"me@example.org">>},
        {<<"To">>, <<"you@example.org">>},
        {<<"Subject">>, <<"Hello">>},
        {<<"Message-ID">>, <<"<1@example.org>">>},
        {<<"Date">>, <<"Mon, 23 Nov 2026 10:00:00 +0000">>},
        {<<"MIME-Version">>, <<"1.0">>}
    ],
    body => <<"Hello.\r\n">>
}).

Config = #{
    host => <<"smtp.example.org">>,
    port => 587,
    tls => starttls,
    credentials => {password, <<"me">>, <<"secret">>}
}.

case mailio_smtp:submit(Config, <<"me@example.org">>, [<<"you@example.org">>], Raw) of
    {ok, #{accepted := Accepted, rejected := Rejected}} ->
        {Accepted, Rejected};
    {error, Error} ->
        %% smtp_transient: nothing was sent, you may retry
        %% smtp_rejected: the server refused it
        %% smtp_outcome_unknown: it may have been sent, do not resend by yourself
        mailio_error:code(Error)
end.
```

`accepted` means the server took the message for delivery, not that it arrived. Some recipients can be refused while others are accepted.

## Read a POP3 mailbox

```erlang
{ok, Conn} = mailio_pop3:open(#{
    host => <<"pop.example.org">>,
    tls => true,
    credentials => {password, <<"me">>, <<"secret">>}
}),
{ok, Count, _Bytes} = mailio_pop3:stat(Conn),
{ok, Ids} = mailio_pop3:uidl(Conn),            %% [{1, <<"uid-1">>}, ...]
{ok, Headers} = mailio_pop3:top(Conn, 1, 0),   %% headers only
{ok, Message} = mailio_pop3:retr(Conn, 1, 5 * 1024 * 1024),  %% refuse over 5 MiB
mailio_pop3:close(Conn).
```

The library never sends `DELE`: mail stays on the server.

## Run a command on an IMAP server

`mailio_imap_conn` owns the connection, the TLS upgrade and the login. You give it a function that builds a command for a tag, and it returns what the server said.

```erlang
{ok, Imap} = mailio_imap_conn:start_link(#{
    host => <<"imap.example.org">>,
    port => 993,
    tls => true,
    credentials => {password, <<"me">>, <<"secret">>}
}),
{ok, Untagged, {ok, _Code, _Text}} =
    mailio_imap_conn:run(Imap, fun(Tag) -> {mailio_imap_proto:examine(Tag, <<"INBOX">>), undefined} end),
mailio_imap_conn:close(Imap).
```

`examine` opens the mailbox read-only; use `select` only when you will change flags. The answer is a list of parsed untagged replies, for example `{exists, 42}`.

A connection that the server refused, or whose answer was too large, stays closed: every later call returns the same error. Start a new one.

## Parse a message

```erlang
Part = mailio_mime:parse(Raw),
<<"text">> = mailio_mime:type(Part),
Subject = mailio_mime:header(<<"subject">>, Part),
Leaves = mailio_mime:leaves(Part),             %% the parts that hold content
[{mailio_mime:content_type(P), mailio_mime:filename(P)} || P <- Leaves].
```

`mailio_mime:defects/1` lists what was wrong with the message, such as a missing closing boundary or too many parts, instead of failing.

## Next

- [Overview](overview.md): the public modules and the limits you can change.
- `CONTRIBUTING.md` in the repository, if you want to change the library.
