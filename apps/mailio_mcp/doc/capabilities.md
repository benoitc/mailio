# What is implemented, tested and deferred

This page lists what mailio_mcp does today and how much of it a test covers. You need it before you rely on a feature, and before you plan work on a missing one. "Tested" means a test in this repository runs the feature; the end-to-end tests run against GreenMail, and the protocol libraries are tested against fake servers.

## Tools

7 tools, 6,593 bytes of tool catalog: `accounts_list`, `mailboxes_list`, `mail_search`, `mail_read`, `mail_changes`, `draft_save`, `draft_send`.

## Measured cost

Measured on 2026-11-24, after mailboxes were opened with EXAMINE for every read, by the end-to-end suite against GreenMail, one account, one local day, text filter and attachment filter:

| Call | Response | IMAP commands | Wire bytes to and from the server |
|---|---|---|---|
| Cold search | 395 bytes | 4 | 1,878 |
| Warm search (cache) | 455 bytes | 0 | 0 |
| Unchanged poll (`mail_changes`) | 83 bytes | 3 | 697 |

IMAP commands are the ones the adapter sends; the login and logout around them are not counted, and neither is a connection attempt that never reached a server. GreenMail has no CONDSTORE, so the unchanged poll compares the flags of every message. With QRESYNC the server reports only what changed, so an unchanged poll lists no flags at all.

## Features

| Feature | Implemented | Tested | Notes |
|---|---|---|---|
| IMAP search, read, thread, mailboxes | yes | yes | Read-only open and `BODY.PEEK`; the unread flag is checked after searching and reading |
| IMAP changes (added, updated, removed) | yes | yes | Without QRESYNC, a comparison of every message's flags with the snapshot, tested against GreenMail |
| IMAP changes with QRESYNC | yes | yes | The server reports only what changed since the checkpoint and the mailbox stays read-only. Tested against a real Dovecot (baseline, unchanged, flag change, new message, expunge, a chain of checkpoints) and a fake server, including the fallback to the full comparison. The adapter enables CONDSTORE first, because a server reports the mod-sequence only to a client that asked for it |
| Wait for the next change (`wait_seconds`) | yes | yes | `mail_changes` holds the server in IDLE for up to 25 seconds and returns at the first change, so an agent does not have to poll. The checkpoint is compared before IDLE starts, so a change made just before the wait is not missed. Tested against Dovecot and GreenMail. POP3 has no push and reports `unsupported` |
| IMAP implicit TLS and STARTTLS | yes | yes | The adapter uses the mailio IMAP connection. Certificates and host names are verified by default; a wrong CA, a wrong host name and a server that refuses STARTTLS are all refused, and the password is never sent before TLS. Tested against Dovecot in both modes, and against scripted servers for the refusals |
| IMAP search with non-ASCII text, UTF-7 mailbox names | yes | yes | Non-ASCII search text is sent as a literal; folder names are encoded as modified UTF-7. Tested against Dovecot |
| POP3 with UIDL and TOP, local index | yes | yes | Mail stays on the server; no `DELE` is ever sent |
| POP3 without UIDL or TOP | yes | partly | The library fallbacks are tested; the adapter's header-hash identity is not |
| POP3 filters it cannot do (`unread`, `received_at`) | yes | yes | Reported as `unsupported` per account, not ignored |
| SMTP submission, per-recipient acceptance | yes | yes | Fake server for the failure cases; a real Mailpit server checks what arrives: headers, UTF-8, dot-stuffing, a 300 KB attachment, Bcc |
| SMTP implicit TLS, STARTTLS, verified certificates | yes | yes | Implicit TLS and STARTTLS against a fake server with generated certificates; STARTTLS also against Mailpit with a private CA. A wrong CA and a wrong host name are refused |
| AUTH PLAIN, LOGIN, XOAUTH2 | yes | yes | SMTP, POP3 and IMAP. A server that refuses the credentials is not retried. Tokens come from a `{cmd, ...}`, `{env, ...}` or `{file, ...}` reference; no refresh |
| Idempotent send, concurrent retry, `outcome_unknown` | yes | yes | Survives a restart |
| Drafts, reply headers, sender identity | yes | yes | Drafts are kept locally; they are not written to the server Drafts folder |
| Sent copy in the Sent folder | no | no | Deferred; most SMTP servers do not save one |
| Time windows with an IANA zone (DST days) | yes | yes | Start inclusive, end exclusive; `received_at`, `sent_at`, `first_seen_at` |
| `first_seen_at` time basis | yes | no | |
| Several accounts, per-account permissions | yes | yes | Handles, cursors and attachment links are bound to the caller |
| Copy grouping across accounts | yes | yes | Only when a content fingerprint confirms it; Message-ID is a hint |
| Cursor paging, count only, freshness, forced refresh | yes | yes | |
| Partial coverage when a candidate cap is reached | yes | no | Reported as `partial`. A failed IMAP metadata fetch or an unreadable POP3 index entry also marks the account partial instead of looking empty |
| Query-centered excerpts | yes | no | With `excerpt`, the IMAP excerpt is centered on the searched text when the body can be fetched read-only; otherwise it starts at the beginning |
| Attachments: list, open one part, resource link | yes | yes | Text parts are paged; binary parts up to 64 KiB with `include_content`, larger ones through the resource |
| stdio transport | yes | yes | |
| Streamable HTTP with bearer auth | yes | yes | Tested with a verifier function |
| JMAP adapter | no | no | Deferred; the first optional adapter to add |
| Gmail API, Microsoft Graph adapters | no | no | Deferred; Gmail and Outlook work today through IMAP and SMTP with XOAUTH2 |

## Next

- Write drafts to the server Drafts folder.
- A JMAP adapter.
