# Connect an MCP client to your mail

This page gets the mailio_mcp server running and connected to an MCP client such as Claude Code or Claude Desktop. You need it once per machine, and again when you add an account or a caller.

## Build

From the root of the mailio umbrella:

```bash
rebar3 compile
```

You need Erlang/OTP 28 or later. The launcher is `apps/mailio_mcp/bin/mailio-mcp`.

## Configure one account

Copy `apps/mailio_mcp/config/one-account.config` and edit it. Secrets are references, never literal passwords:

```erlang
[
  {mailio_mcp, [
    {data_dir, "/var/lib/mailio_mcp"},
    {accounts, [
      #{id => <<"work">>,
        name => <<"Work mail">>,
        incoming => #{protocol => imap, host => "imap.example.com", port => 993, tls => implicit},
        outgoing => #{host => "smtp.example.com", port => 587, tls => starttls},
        auth => #{user => <<"me@example.com">>, mechanism => plain,
                  secret => {env, "WORK_MAIL_PASSWORD"}},
        identities => [#{address => <<"me@example.com">>, name => <<"Me">>}]}
    ]}
  ]}
].
```

A secret is `{env, Name}`, `{file, Path}` or `{cmd, Command}`. Use `mechanism => xoauth2` with a `{cmd, ...}` that prints a fresh access token for accounts that need OAuth. Use `protocol => pop3` for a POP3 account. TLS certificates and host names are checked unless you set `verify => false` on the incoming or outgoing settings.

With no `principals` list, the one caller may read, draft and send on every account.

## Configure two accounts and separate callers

`apps/mailio_mcp/config/two-accounts.config` shows two accounts with different incoming and outgoing settings, and two callers:

```erlang
{principals, [
  #{id => <<"assistant">>,
    grants => #{<<"work">> => #{role => send, identities => all},
                <<"personal">> => #{role => draft, identities => all}}},
  #{id => <<"reader">>,
    grants => #{<<"personal">> => #{role => read, identities => []}}}
]}
```

A role is `read`, `draft` or `send`, and each includes the ones before it. A caller sees only the accounts it is granted. Naming an account the caller cannot see gives the same error as naming one that does not exist.

## Run over stdio (Claude Code, Claude Desktop)

Add the server to your client. For Claude Code:

```bash
claude mcp add mail --env MAILIO_MCP_CONFIG=/path/to/mail.config --env WORK_MAIL_PASSWORD=... \
  -- /path/to/mailio/apps/mailio_mcp/bin/mailio-mcp stdio
```

Or put it in `.mcp.json`:

```json
{
  "mcpServers": {
    "mail": {
      "command": "/path/to/mailio/apps/mailio_mcp/bin/mailio-mcp",
      "args": ["stdio"],
      "env": {
        "MAILIO_MCP_CONFIG": "/path/to/mail.config",
        "WORK_MAIL_PASSWORD": "..."
      }
    }
  }
}
```

Over stdio the caller is the principal named by `stdio_principal` (default `local`). The server writes only protocol messages to stdout and logs to stderr.

## Run over Streamable HTTP (shared deployment)

Add an `http` entry to the config and start the server with `http`:

```erlang
{http, #{port => 8420,
         auth => #{provider => barrel_mcp_auth_bearer,
                   provider_opts => #{...}}}}
```

```bash
MAILIO_MCP_CONFIG=/path/to/mail.config apps/mailio_mcp/bin/mailio-mcp http
```

The `sub` claim of the bearer token must equal a principal `id` from your `principals` list. The server listens on 127.0.0.1 by default; put TLS in front of it or use barrel_mcp's `ssl` option before exposing it. The end-to-end tests run this transport with a verifier function; the other `barrel_mcp_auth_bearer` options are barrel_mcp's, see its authentication guide.

## Check that it works

Ask your agent to list the accounts, or call the tools directly. A search for one local day:

```json
{"name": "mail_search",
 "arguments": {"on": "2026-03-29", "time_zone": "Europe/Paris",
               "text": "invoice", "has_attachment": true}}
```

Search returns at most 20 hits and 8 KiB, with a `next_cursor` when there is more. Open a hit with `mail_read` and its `handle`. Reading never marks mail as read.

## Wait for new mail

Instead of calling `mail_changes` in a loop, take a baseline once, then pass its checkpoint with `wait_seconds`:

```json
{"name": "mail_changes",
 "arguments": {"checkpoint": "<from the last call>", "wait_seconds": 20}}
```

The call returns as soon as the server reports a change, or after the wait (at most 25 seconds) with `unchanged: true` and the same checkpoint. `waited.result` says which: `changed`, `timeout` or `unsupported` (POP3 accounts). A call without a checkpoint is a baseline and returns at once.

## Notes

- Mail text is returned as `content_untrusted`. Your agent must not follow instructions found in it.
- `draft_send` needs the `send` role and an `idempotency_key`. A result of `accepted` means the mail server took the message, not that it was delivered. An `outcome_unknown` result is never resent automatically.
- The tests need a disposable mail server: `(cd apps/mailio_mcp/test && docker compose up -d)`.
