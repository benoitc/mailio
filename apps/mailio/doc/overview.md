# mailio

mailio is an Erlang/OTP library that speaks the mail protocols and reads and writes messages: IMAP, POP3 and SMTP clients, RFC 5322 headers, MIME parsing and rendering, character sets and HTML to text. It needs OTP 28 or later and nothing else: no database, no other packages. You use it when you want to read or send mail from your own Erlang or Elixir code. If you want a ready-made service on top of it, see the sibling applications in the [repository](https://github.com/benoitc/mailio) (`mailio_mcp` and `mailio_store`); they are not part of this package.

Start with the [usage guide](usage.md). This page tells you which modules you can rely on and what the library does to protect itself from a misbehaving server.

## Public API

Everything in the first table is the supported API. Its functions and types follow the version number: a breaking change means a new major version.

| You want to | Use |
|---|---|
| Send a message | `mailio_smtp` |
| Read a POP3 mailbox (list, headers, whole message; mail stays on the server) | `mailio_pop3` |
| Run commands on an IMAP server over one connection (TLS, STARTTLS, login, IDLE) | `mailio_imap_conn`, with `mailio_imap_proto` to build commands and parse replies |
| Parse a message into parts | `mailio_mime` |
| Build a message | `mailio_mime_render` |
| Decode transfer encodings, charsets and encoded words | `mailio_mime_decode` |
| Read headers, addresses, dates, Message-IDs | `mailio_rfc5322` |
| Turn HTML into text | `mailio_html_text` |
| Describe credentials (password or OAuth 2 token, fixed or refreshed on demand) | `mailio_credentials` (types) |
| Inspect an error | `mailio_error` |

These modules exist for the `mailio_store` application and are public only because Erlang has no package-private modules. They are not covered by the version promise and can change in any release; you normally do not need them.

| Module | What it is for |
|---|---|
| `mailio_adapter`, `mailio_imap`, `mailio_imap_map` | The sync contract the store uses, and its IMAP implementation. Sharing one `mailio_imap` handle between processes is supported; the rest of its functions follow the store |
| `mailio_events`, `mailio_registry` | Process registry and event bus. Internal support for `mailio_store`; they stay here for this release and may move before `mailio_store` is published |
| `mailio_id`, `mailio_ascii`, `mailio_credentials_static` | Helpers |

## What the library does about a hostile server

Every size a server controls is bounded, so a broken or hostile server cannot make the client use unlimited memory. When a limit is hit the connection is closed and you get an error, not a truncated result. Pass the option in the config map of the call, except where noted.

| What | Default | Option | Result when exceeded |
|---|---|---|---|
| IMAP literal (one message body or part) | 64 MiB | `max_literal` | `{error, response_too_large}`, connection closed for good |
| IMAP line outside a literal | 64 KiB | `max_line` | same |
| IMAP whole response | 96 MiB | `max_response` | same |
| IMAP responses one command collects | 100,000 of them and 96 MiB | `max_untagged`, `max_untagged_bytes` | same |
| IMAP UIDs one sync adapter command lists | 10,000, cut to half of `max_untagged` for FETCH and to what fits in `max_line` for SEARCH | `listing_window` | not a limit that fails: a larger mailbox is listed in several windows, and the adapter answers `more` until it is all read |
| IMAP listing commands for one mailbox read | 100,000 | `max_list_commands` | `imap_listing_too_sparse`, nothing is changed: UIDs that are far apart cost windows, not messages. It counts the windows of data; the EXAMINE of each call and the query for the highest UID are not in it |
| IMAP `VANISHED` report the sync adapter lists one by one | 100,000 UIDs | `max_vanished`, which can only lower it | the adapter returns `resync`: read the mailbox again and keep the new state only when that worked |
| POP3 listing reply (LIST, UIDL, CAPA) | 32 MiB | `max_list_bytes` | `pop3_response_too_large`, connection closed |
| POP3 TOP reply | 1 MiB | `max_top_bytes` | same |
| POP3 RETR reply | the `MaxBytes` you pass, plus 64 KiB | argument | same |
| POP3 message accepted when TOP is missing | 2 MiB | `max_retr` (option of `headers/4`) | `pop3_too_large` |
| POP3 one line | 64 KiB | `max_line_bytes` | disconnect |
| SMTP reply | 64 KiB, 100 lines, 4 KiB per line | fixed | before the body: `smtp_transient`; after the body: `smtp_outcome_unknown` |
| MIME parts per message | 1000 | application env `max_mime_parts` of `mailio` | the rest are dropped, the part gets a `too_many_parts` defect |
| MIME nesting depth | 50 | fixed | the part is kept whole with a `max_depth_exceeded` defect |

Timeouts are 30 seconds for connecting, for each POP3 and SMTP reply and for the IMAP greeting, STARTTLS and login (`command_timeout`). An IMAP command has the deadline you give `run/3`, 30 seconds by default; when the server has not answered by then you get `{error, imap_timeout}` and the connection is dropped, because a late answer could no longer be matched to its command. Credential providers have 10 seconds (`credentials_timeout`). TLS certificates and host names are verified unless you set `verify => verify_none`.

## Changes that break callers

These affect code that calls `mailio_imap_proto` directly, which is public API.

| Before | Now |
|---|---|
| `parse_uid_set/1` returned every UID of a set as a list | `parse_uid_ranges/1` returns sorted, merged `{Lo, Hi}` ranges (either end may come first). `expand_uid_ranges(Ranges, Max)` returns `{ok, List}` or `{error, too_many}`, and `uid_count/1` counts them |
| `{vanished, Earlier, [Uid]}` | `{vanished, Earlier, [{Lo, Hi}]}` |
| `read_response/3` took a byte offset | it takes `start`, then the state it returned in `{more, State}` |
| An IMAP connection without a `tls` option used plain text | the default is `starttls`, as for POP3 and SMTP. Plain text needs `tls => false`. A server that greets with PREAUTH on a connection that has to be protected is refused with `tls_failed` |
| POP3 and SMTP took any `tls` value they did not know as plain text | an unknown value is refused (`pop3_tls_failed`, `smtp_tls_failed`) before a socket is opened |
| `build/1` left out the Date header | it adds one (now, or the `date` you give in seconds since the epoch) unless you pass a `Date` header |

The sync adapter (`mailio_adapter`) reports more than before:

- It can return `resync` among its changes, next to `reset`.
- Every `added` change carries the `uidvalidity` it was listed under.
- `fetch_message/5` takes `#{uidvalidity => V}` and refuses (`imap_uidvalidity_changed`) when the mailbox has another one. It is optional in `mailio_adapter`, but an adapter whose `added` changes carry `uidvalidity` must implement it: the store refuses to fetch such a message through `fetch_message/4`.
- A mailbox is listed in windows of `listing_window` UIDs, and a read that does not fit in one call answers `more` with a state to continue from. The state carries where the listing stopped, so it may be kept between calls.
- A listing or flag fetch the server refuses is now an error, and so is a UID search that does not answer in full: a tagged OK with no `* SEARCH` line, or one with something other than numbers in it, is not a mailbox with no mail (an explicit, empty `* SEARCH` is). It used to be an empty answer with a new state.

- `list_uids/3` takes `#{max => N}` and stops with an error as soon as the mailbox holds more than N messages. `mailbox_info/2` says how many it holds and under which UIDVALIDITY. Both are optional; the store uses them to check a listing against the mailbox before it removes anything.
- `list_uids` answers only when the UIDs it found are as many as the messages the server reported, and it reads again a few times when they are not. A mailbox that never agrees is an error.

The rest of this section is about `reset` and `resync`. `reset` means the UIDs the caller holds mean other messages now; `resync` means there were too many changes to list. In both cases read the whole mailbox again and keep the new state only when that worked.

## Sharing one connection

If several processes need the same IMAP server, use `mailio_imap` and share its handle. A call that selects a mailbox and then acts on it (reading a message, changing flags, moving, expunging, listing, starting IDLE) holds the connection for the whole call, so it never acts on a mailbox somebody else selected in between. Callers wait for their turn in the order they asked, for up to two minutes, and a caller that dies gives its turn up. How the turns are kept is an internal detail (`mailio_imap_lock`): do not call it yourself.

A raw `mailio_imap_conn` has one owner. It sends whatever you give it, and the selected mailbox is part of its state, so give each connection to one process. [Design decisions of the IMAP adapter](design-decisions.md) explains why.

## Supervised connections

A connection started with `start_link/1` is linked to the process that started it and goes down with it. To keep one for a long time, start it under your own supervisor with `mailio_imap_conn:child_spec/1`. The connection reconnects on its own; the supervisor restarts it only when it crashes.

A supervisor writes the start arguments of its children in its reports, so they must not hold a secret. Keep the credential under a name and give the name:

```erlang
ok = mailio_credentials:register_ref(my_account, {password, <<"me">>, <<"secret">>}),
Spec = mailio_imap_conn:child_spec(#{
    host => <<"imap.example.org">>, port => 993, tls => true,
    credentials => {ref, my_account}
}).
```

- The connection looks the credential up in its own worker each time it logs in.
- To replace it (a password change), call `register_ref/2` again with the same name: the next login uses the new one.
- To remove it, call `forget_ref/1`. A connection that logs in after that fails with `credentials_failed`.
- `credentials` may also be a `{token_fun, Fun}` with a zero-argument fun. Any other value, and a `password`, `token` or `secret` in the config, is refused with `secret_in_child_spec`; the error does not repeat the value.

`expunge/3` removes the UIDs you name and no other message, with `UID EXPUNGE`. A server without UIDPLUS has only `EXPUNGE`, which would also take every message another client flagged `\\Deleted` at that moment, so the call returns `imap_operation_unsupported` before it changes anything. Moving a message uses `UID MOVE` when the server has MOVE, and copy then `UID EXPUNGE` when it has UIDPLUS; with neither it is refused the same way.

## Errors

Calls return `{error, Map}` where the map has a `code` such as `smtp_transient`, a `retryable` flag and a `detail`. Use `mailio_error:code/1` and `is_retryable/1`. The IMAP connection returns bare atoms for connection-level failures (`authentication_failed`, `tls_failed`, `response_too_large`, `not_connected`), which stay terminal: a connection in one of the first three states answers every later call the same way and you start a new one.

For SMTP the code decides whether a retry is safe: `smtp_transient` means nothing was submitted, `smtp_rejected` means the server said no, `smtp_outcome_unknown` means the body was sent and the answer was lost, so you must not resend on your own.

## Where the code is

| Area | Modules | Tests |
|---|---|---|
| IMAP | `mailio_imap_conn`, `mailio_imap_proto` | `mailio_imap_proto_tests`, `mailio_imap_limits_tests`, `mailio_imap_conn_auth_tests` |
| POP3 | `mailio_pop3` | `mailio_pop3_tests` |
| SMTP | `mailio_smtp` | `mailio_smtp_tests`, `mailio_smtp_mailpit_SUITE` (real server) |
| Messages | `mailio_mime*`, `mailio_rfc5322`, `mailio_html_text` | `mailio_mime_*_tests`, the corpus and property suites |

If you want to change the library, read [CONTRIBUTING.md](https://github.com/benoitc/mailio/blob/main/CONTRIBUTING.md) and [AGENTS.md](https://github.com/benoitc/mailio/blob/main/AGENTS.md) in the repository first. [The architecture page](https://github.com/benoitc/mailio/blob/main/docs/architecture.md) explains how this library relates to the other applications.
