# Design notes

This page records the decisions behind mailio_mcp, so you can judge a change against them. Read it before you change how accounts, search, deduplication or sending work.

## What it is

An MCP server over existing mail accounts. An agent finds mail, reads only the part it needs, and drafts or sends a reply. It works without an LLM and keeps every result small enough for a small local model. The mail protocols and MIME live in the `mailio` app; this app holds the tools, the permissions and the state.

## Protocols

IMAP and POP3 for receiving, authenticated SMTP submission for sending, with incoming and outgoing settings per account. IMAP opens mailboxes read-only and fetches with `BODY.PEEK`, so a search or read never changes the unread flag. The connection, TLS, authentication and response parsing come from the mailio library. For `mail_changes`, a server with QRESYNC reports only what changed since the checkpoint, so a poll does not list every message's flags; other servers get a comparison with the stored snapshot. With `wait_seconds` the call can hold an IDLE connection (at most 25 seconds, on every IMAP account at once) and return at the first change, instead of the agent polling. POP3 has no push. POP3 leaves mail on the server, uses UIDL and TOP when the server has them, and builds a local metadata index for search. Without TOP it fetches small messages whole and refuses large ones. Without UIDL it falls back to a hash of the headers and size. A server that repeats a UIDL for identical copies gets an ordinal suffix, so each copy keeps its own identity. Each account reports which filters it can do natively, which locally and which not at all.

## Which adapter belongs in V1

| | IMAP/POP3 + SMTP | JMAP | Gmail API | Microsoft Graph |
|---|---|---|---|---|
| Provider coverage | Every provider; Gmail and Outlook through XOAUTH2 | A few servers (Fastmail, Stalwart, Cyrus) | Gmail only | Microsoft 365 only |
| Search | Native criteria, day precision for dates | Server-side filters with exact `receivedAt` | Gmail query syntax | OData filter and search |
| Selective retrieval | Fetch one part, partial ranges | Fetch properties and parts | Fetch format and parts | Select fields, fetch MIME |
| Incremental sync | UID diff; CONDSTORE and QRESYNC when offered | `Email/changes` with a state string | History list, expires | Delta queries |
| Submission | SMTP | `EmailSubmission` | Send API | `sendMail` |
| Cost to add | Done | Medium: HTTP and JSON | High: OAuth app and review for mail scopes | High: app registration and consent |

V1 ships IMAP, POP3 and SMTP: they reach every account a user already has. JMAP is the first optional adapter to add, because it gives exact time filters and cheap change tracking behind the same tools. The Gmail and Graph APIs add mostly OAuth work for what IMAP with XOAUTH2 already reaches.

## One service, several accounts

One process holds all accounts, because one agent often needs a work and a personal inbox with the same tool definitions. Credentials, search scope and sending identities stay separate per account. There is no process-wide current account: every call carries `account_ids`, or a handle that names its account.

- `accounts_list` shows only the accounts the caller may use, with their role, sender addresses and capabilities.
- Search needs `account_ids` when the caller sees more than one account, or the string `all` for every authorized one.
- A handle names one message in one account and mailbox. Permissions are checked again on every read, resource fetch and write. Handles, cursors and checkpoints are signed and bound to the caller.
- A draft belongs to one account and one permitted From identity. A reply defaults to the account that received the message and to the address it was sent to. Changing the sender is explicit.

## Tools and the context budget

Search returns metadata only: account, mailbox, handle, sender, subject, time and an attachment count. A page is at most 20 hits and 8 KiB, enforced by one module that shortens long fields first and then drops hits, and reports the truncation with a continuation cursor. A thread is a compact timeline; the agent expands one message, pages through its text, or asks for quoted history. Attachments are listed with name, type and size first; opening one returns a resource link, or a small text or base64 result for parts up to 64 KiB. Results are plain JSON text, once, rather than text plus a structured copy.

## Time and search

Windows take RFC 3339 instants, or dates with an IANA zone, with an inclusive start and an exclusive end. IMAP date search has day precision, so the search asks for a day more on each side and the exact instants are applied locally. The zone rules come from the system zoneinfo, including the rule that covers dates after the last stored transition, so a 23-hour or 25-hour day is handled. When an account cannot filter by a time basis (POP3 has no `received_at`), the result says so for that account. Results from several accounts are merged in a stable order, and the coverage of an account that is offline or partly searched is reported.

## Deduplication, state and caching

Three separate problems:

- **Ingestion** is idempotent by adapter identity: mailbox, UIDVALIDITY and UID for IMAP, the maildrop and UIDL for POP3. A replay after a restart stores nothing twice.
- **Display** groups copies only when a content fingerprint confirms they are the same message. Message-ID is a hint, never evidence. Every authorized location stays listed, and no mail is ever deleted to deduplicate.
- **Sending** binds an idempotency key to the account, the draft revision and the content. A repeated or concurrent call returns the recorded status; a changed payload under the same key is refused; a fresh key cannot submit the same revision again. If the connection ends after the body was sent, the status is `outcome_unknown` and the message is never resent automatically. A record is written before the connection is opened, so a crash in between also ends as `outcome_unknown`. `accepted` means the server took the message for submission, not that it was delivered; some recipients may be refused.

Checkpoints, identity records, drafts and send records are kept in a durable store that is independent of the cache. The cache holds metadata first, fetches bodies and attachments on demand, is capped by size and age, and is invalidated when mail changes. Every result reports its freshness, and `refresh` forces a new look. Mail text is untrusted data, and neither credentials nor message content are logged.
