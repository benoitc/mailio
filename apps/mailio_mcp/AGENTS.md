# Agents: mailio_mcp

Read [the umbrella AGENTS.md](../../AGENTS.md) first: the three checks, the
required commands, the code style, the pull request rules and the specification
list apply here too. This page is only what is specific to the MCP server.

## What it is

An MCP server that lets an agent find mail, read the part it needs and draft or
send a reply on existing accounts (IMAP or POP3 in, authenticated SMTP out). It
works without an LLM and stays cheap for small local models. The protocols and
MIME come from the `mailio` app: use `mailio_imap_conn`, `mailio_imap_proto`,
`mailio_smtp`, `mailio_pop3`, `mailio_mime`, `mailio_mime_decode`,
`mailio_mime_render` and `mailio_rfc5322` instead of writing new parsing code
here. `mailio_mcp` must not depend on `mailio_store` or `barrel_docdb`.

| You want to | Look at |
|---|---|
| Add or change a tool | `src/mailio_mcp_tools.erl`, then the module it calls |
| Change search | `src/mailio_mcp_search.erl`, `mailio_mcp_budget`, `mailio_mcp_time` |
| Add a protocol adapter | `src/mailio_mcp_adapter.erl` (the behaviour), `mailio_mcp_imap`, `mailio_mcp_pop3` |
| Change permissions | `src/mailio_mcp_authz.erl`, `mailio_mcp_config` |
| Change sending | `src/mailio_mcp_draft.erl`, `mailio_mcp_send`, `mailio_mcp_smtp` (a bridge to `mailio_smtp`) |
| Change waiting for mail | `src/mailio_mcp_changes.erl`, `mailio_mcp_imap:wait_for_change/4` |

## Rules for this app

1. **Output is bounded.** Search returns metadata only, 20 hits and 8 KiB at
   most, and never inlines a body or an attachment. Binary data stays out of
   normal text results.
2. **Scope is checked on every call.** Search, read, resource fetch, cursor and
   write re-check the caller's permissions. An account the caller may not see
   gives the same error as one that does not exist.
3. **Never lose or resend mail.** Deduplication only changes how results are
   shown. A send that ended without a final reply is `outcome_unknown` and is
   never resent automatically.
4. **No message content in logs.** Mail text is returned marked as untrusted.
5. **A new tool needs a schema, accurate read and write annotations, an error
   that says what to do next, and a place in the catalog size** reported in
   `doc/capabilities.md`.

## Tests

Unit tests: `rebar3 eunit --module mailio_mcp_unit_tests` and the
`mailio_mcp_imap_changes_tests` module. End to end, with a real MCP client:
`mailio_mcp_e2e_SUITE` (GreenMail). The IMAP adapter against a real server:
`mailio_mcp_imap_dovecot_SUITE`. How to start the servers is in the umbrella
AGENTS.md.

Keep `doc/capabilities.md` in step with the code: a feature is listed as
implemented, tested or deferred, and the measured costs are re-measured when the
tool catalog or a tool's result changes.
