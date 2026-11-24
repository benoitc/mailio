# mailio

mailio is an Erlang/OTP library that speaks the mail protocols and reads and writes messages: IMAP, POP3 and SMTP clients, RFC 5322 headers, MIME parsing and rendering, character sets and HTML to text. It needs OTP 28 or later and nothing else: no database, no other packages. You use it when you want to read or send mail from your own Erlang or Elixir code. If you want a ready-made service on top of it, see the sibling applications in the repository (`mailio_mcp` and `mailio_store`); they are not part of this package.

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
| `mailio_adapter`, `mailio_imap`, `mailio_imap_map` | The sync contract the store uses, and its IMAP implementation |
| `mailio_events`, `mailio_registry` | Process registry and event bus used by the store |
| `mailio_id`, `mailio_ascii`, `mailio_credentials_static` | Helpers |

## What the library does about a hostile server

Every size a server controls is bounded, so a broken or hostile server cannot make the client use unlimited memory. When a limit is hit the connection is closed and you get an error, not a truncated result. Pass the option in the config map of the call, except where noted.

| What | Default | Option | Result when exceeded |
|---|---|---|---|
| IMAP literal (one message body or part) | 64 MiB | `max_literal` | `{error, response_too_large}`, connection closed for good |
| IMAP line outside a literal | 64 KiB | `max_line` | same |
| IMAP whole response | 96 MiB | `max_response` | same |
| POP3 listing reply (LIST, UIDL, CAPA) | 32 MiB | `max_list_bytes` | `pop3_response_too_large`, connection closed |
| POP3 TOP reply | 1 MiB | `max_top_bytes` | same |
| POP3 RETR reply | the `MaxBytes` you pass, plus 64 KiB | argument | same |
| POP3 message accepted when TOP is missing | 2 MiB | `max_retr` (option of `headers/4`) | `pop3_too_large` |
| POP3 one line | 64 KiB | `max_line_bytes` | disconnect |
| SMTP reply | 64 KiB, 100 lines, 4 KiB per line | fixed | before the body: `smtp_transient`; after the body: `smtp_outcome_unknown` |
| MIME parts per message | 1000 | application env `max_mime_parts` of `mailio` | the rest are dropped, the part gets a `too_many_parts` defect |
| MIME nesting depth | 50 | fixed | the part is kept whole with a `max_depth_exceeded` defect |

Timeouts are 30 seconds for connecting, for each IMAP command and for each POP3 and SMTP reply. TLS certificates and host names are verified unless you set `verify => verify_none`.

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

If you want to change the library, read `AGENTS.md` and `CONTRIBUTING.md` in the repository first.
