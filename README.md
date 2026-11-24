# mailio

An Erlang/OTP umbrella for working with mail. This page tells you which app to use and how to run the checks.

| App | What it is | Depends on |
|---|---|---|
| `apps/mailio` | Mail protocol and MIME library: IMAP client, POP3 client, SMTP submission, RFC 5322, MIME parse and render, charsets, HTML to text. No database. | OTP only |
| `apps/mailio_store` | Mail store, sync, search, threading, rules and the agent surface. Raw messages can be [kept as files](apps/mailio_store/doc/blobs.md) | `mailio`, `barrel_docdb` |
| `apps/mailio_mcp` | MCP server: find mail, read the part you need, draft and send. See [client setup](apps/mailio_mcp/doc/client-setup.md) | `mailio`, `barrel_mcp` |

## Build and test

```bash
rebar3 compile
rebar3 eunit
rebar3 ct --dir apps/mailio/test
rebar3 ct --dir apps/mailio_store/test
```

The `mailio_mcp` end-to-end tests need a disposable mail server:

```bash
(cd apps/mailio_mcp/test && docker compose up -d)
rebar3 ct --suite apps/mailio_mcp/test/mailio_mcp_e2e_SUITE
```

The SMTP client is also tested against a real server, Mailpit, which captures every message and shows it over an API:

```bash
apps/mailio/test/mailpit/gen-certs.sh
(cd apps/mailio/test/mailpit && docker compose up -d)
rebar3 ct --suite apps/mailio/test/mailio_smtp_mailpit_SUITE
```

It listens on ports 11025 and 18025, not the Mailpit defaults, because 1025 is also the default port of local mail tools such as Proton Mail Bridge.

The IMAP adapter is tested against a real Dovecot, which has QRESYNC, STARTTLS and implicit TLS (GreenMail has none of them). It reuses the certificate from the Mailpit setup:

```bash
apps/mailio/test/mailpit/gen-certs.sh
(cd apps/mailio_mcp/test/dovecot && docker compose up -d --build)
rebar3 ct --suite apps/mailio_mcp/test/mailio_mcp_imap_dovecot_SUITE
```

Formatting and lint rules apply to `apps/mailio_mcp` only: `rebar3 fmt --check`, `rebar3 lint`. See `apps/mailio_mcp/AGENTS.md` for the full list of checks.

## Notes

- `mailio` and `mailio_mcp` do not depend on `barrel_docdb`.
- TLS certificates and host names are verified by default in every client; set `verify => verify_none` to turn it off for a test server.
