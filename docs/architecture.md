# Architecture

This page explains how mailio is put together and why, so you can tell which part to read or change. You need it before you add a feature that could live in more than one app, and before you propose moving code between them.

mailio is three Erlang applications in one repository. One is a library. The other two are independent products built on it. They do not depend on each other, on purpose.

```
        mailio_mcp                      mailio_store
   live, bounded access            durable local index,
   for MCP clients                 sync, rules, agent surface
        |       \                    /        |
        |        \                  /         |
   barrel_mcp     mailio  (OTP only)     barrel_docdb
                  IMAP, POP3, SMTP, MIME
```

## The three apps

| App | What it is for | You use it when | Depends on |
|---|---|---|---|
| `mailio` | Speak the mail protocols and read and write messages | you want mail in your own code, or you are changing how a server is spoken to | OTP only |
| `mailio_mcp` | Let an agent find mail, read the part it needs, and draft or send, on accounts that already exist | you want to give an MCP client access to a mailbox | `mailio`, `barrel_mcp` |
| `mailio_store` | Keep a durable local copy: sync from a server, index, thread, apply rules, serve an agent API with grants | you want mail kept locally and queried without going back to the server | `mailio`, `barrel_docdb` |

`mailio_mcp` must not depend on `mailio_store` or `barrel_docdb`, and `mailio` must not depend on either. `rebar3 tree` shows it, and a change that breaks the rule is a design change, not a fix.

## Why two products and not one

They answer different needs.

- **`mailio_mcp` is live and stateless towards the mail.** It asks the server each time (with a small cache), keeps every answer bounded for a small model, and holds only what it must remember: checkpoints, drafts and send records. You can point it at an account in a minute and nothing else has to run.
- **`mailio_store` is a local index.** It copies mail, keeps it searchable and threaded, and reacts to it with rules. It is the right base for work that needs the whole mailbox at hand, or that must keep working when the server is slow.

So they repeat some ideas on purpose: each has its own permission model (roles and identities in `mailio_mcp`, grants with scopes in `mailio_store`), its own search, and its own durable state. Do not merge them to remove the repetition. If the two ever should share code, that is a separate decision with its own page here. The shared part is `mailio`.

## `mailio`: the library

It exists so that protocol and message code is written once and tested against hostile input once. It holds no state of its own beyond a connection.

- **Protocol clients:** `mailio_imap_conn` (one connection as a state machine), `mailio_imap_proto` (IMAP bytes to terms and back, no I/O), `mailio_pop3`, `mailio_smtp`.
- **Messages:** `mailio_mime` parses, `mailio_mime_render` builds, `mailio_mime_decode` handles transfer encodings and charsets, `mailio_rfc5322` handles headers, addresses and dates.
- **Safety:** every size a server controls is bounded. The limits are in [the overview](../apps/mailio/doc/overview.md). A change that reads server data without a bound is a bug under `AGENTS.md`.

Some modules in the library are there only for `mailio_store` (`mailio_adapter`, `mailio_imap`, `mailio_imap_map`, `mailio_events`, `mailio_registry`, `mailio_id`). They are not part of the supported API.

## `mailio_mcp`: how a call flows

You start at `mailio_mcp_tools`, which holds the tool catalog and passes each call to a focused module.

1. **Who is asking.** `mailio_mcp_authz` checks the caller's role on each account. A handle, cursor or checkpoint is signed and bound to the caller, so one caller cannot use another's.
2. **Which accounts.** `mailio_mcp_config` normalizes accounts; there is no "current account", every call names its own.
3. **The adapter.** `mailio_mcp_imap` or `mailio_mcp_pop3` turns the question into protocol commands, through the library. Mailboxes are opened read-only and messages fetched with `BODY.PEEK`, so reading never marks mail as read.
4. **Bounded output.** `mailio_mcp_budget` keeps a result under 20 hits and 8 KiB, shortening fields first and then dropping hits, and returns a cursor when it cut something.
5. **State.** `mailio_mcp_store` keeps what must survive a restart (checkpoints, drafts, send records). `mailio_mcp_cache` keeps what can be fetched again.

Sending goes through `mailio_mcp_draft` and `mailio_mcp_send`. A send is recorded before the connection opens, runs in a supervised worker with a time limit and a cap on how many run at once, and ends as `accepted`, `rejected`, `failed_temporary` or `outcome_unknown`. `outcome_unknown` is never retried automatically, because the message body may already have gone out. [The design notes](../apps/mailio_mcp/doc/design.md) give the reasons for the rest.

Supervision: `mailio_mcp_sup` starts the store, the cache, the send server and the send workers, in that order. If one restarts, everything after it restarts too, so a restarted send server never leaves a worker behind.

## `mailio_store`: how mail gets in and out

1. **Sync.** One `mailio_sync_mgr` per account connects through `mailio_adapter`'s IMAP implementation, finds the mailboxes and reads changes since a saved cursor. An unreachable server does not stop the account: the manager retries with a growing delay.
2. **One writer.** Every change to an account's database goes through `mailio_account_writer`, which serializes the multi-document work (threading, counters, flags, blob references) that would otherwise race. Raw messages are kept as blobs, in the database or as files (`mailio_blob`, [blobs.md](../apps/mailio_store/doc/blobs.md)).
3. **React.** `mailio_workflow_consumer` follows the changes feed and runs rule handlers and actions (`mailio_rules`, `mailio_actions`). Handlers run in their own process with a time limit, and a failed one is tried again up to three times, so a handler must be safe to run twice.
4. **Serve.** `mailio_agent` gives an AI agent search, threads and token-limited context, checked against its `mailio_grant`.

Supervision: `mailio_sup` starts the registry, the event bus and the accounts supervisor with `rest_for_one`, because the registry owns the name table. Each account has its own supervisor with the account process, the writer and a separate supervisor for sync, so a sync crash loop cannot take the writer down.

## Decisions

| Decision | Why | Where you see it |
|---|---|---|
| `mailio` is OTP only | It can be published and used alone, and it has no storage to keep in step with | `apps/mailio/src/mailio.app.src` |
| `mailio_mcp` and `mailio_store` are siblings | Different jobs (live and bounded, against durable and local); neither should force the other's dependencies | the dependency rule above |
| Reading never changes the mailbox | An agent must not mark mail as read by looking at it | `EXAMINE` and `BODY.PEEK` in `mailio_imap`, `mailio_mcp_imap` |
| A send is idempotent and never resent after an unknown outcome | Sending twice is worse than asking the user to check | `mailio_mcp_send`, [design notes](../apps/mailio_mcp/doc/design.md) |
| IMAP, POP3 and SMTP in the first version; JMAP, Gmail and Graph later | IMAP with XOAUTH2 already reaches those providers; the others add mostly OAuth work | the table in the design notes |
| Mail content is data | A message must never be able to instruct the system | `AGENTS.md` |

## Read this next

- You want to run it: [client setup](../apps/mailio_mcp/doc/client-setup.md).
- You want to use the library on its own: [usage guide](../apps/mailio/doc/usage.md).
- You want to change something: `CONTRIBUTING.md`, then the first table in `AGENTS.md`.
