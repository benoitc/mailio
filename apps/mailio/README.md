# mailio

IMAP, POP3 and SMTP clients, MIME and RFC 5322, for Erlang/OTP 28 or later. No database and no other dependencies. This page tells you what you get and where to start.

You use mailio when you want to read or send mail from your own Erlang or Elixir code: connect to a server with TLS, list and fetch messages, parse a message into parts, build one, and submit it. Every size a server controls is bounded, so a broken or hostile server cannot make the client use unlimited memory.

## Install

```erlang
%% rebar.config
{deps, [mailio]}.
```

```elixir
# mix.exs
{:mailio, "~> 0.1"}
```

## Send a message

```erlang
{ok, _} = application:ensure_all_started(ssl),
Raw = mailio_mime_render:render(#{
    type => <<"text">>, subtype => <<"plain">>,
    charset => <<"utf-8">>, encoding => <<"7bit">>,
    headers => [
        {<<"From">>, <<"me@example.org">>},
        {<<"To">>, <<"you@example.org">>},
        {<<"Subject">>, <<"Hello">>}
    ],
    body => <<"Hello.\r\n">>
}),
{ok, #{accepted := [<<"you@example.org">>]}} =
    mailio_smtp:submit(
        #{host => <<"smtp.example.org">>, port => 587, tls => starttls,
          credentials => {password, <<"me">>, <<"secret">>}},
        <<"me@example.org">>, [<<"you@example.org">>], Raw).
```

## Read on

- [Use mailio on its own](doc/usage.md): sending, POP3, IMAP and parsing, step by step.
- [Overview](doc/overview.md): which modules are public API, the limits you can change, and how errors work.
- The module pages in this documentation: `mailio_smtp`, `mailio_pop3`, `mailio_imap_conn`, `mailio_mime`.

## Not in this package

The repository also holds `mailio_mcp` (an MCP server that lets an agent work with mail) and `mailio_store` (a local mail index with sync and rules). They are separate applications and are not published with this package. Their documentation, the architecture page and the contributor guide are in the [GitHub repository](https://github.com/benoitc/mailio).

## License

Apache License 2.0.
