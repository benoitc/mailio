# Changelog

## Unreleased

### mailio_mcp

#### Changed

- A `count_only` search no longer fetches message fingerprints for copy grouping. It counts occurrences, and when two or more hits share a Message-ID the count is reported as approximate, because a grouped search may merge copies.

#### Fixed

- A failed IMAP metadata fetch no longer looks like an empty mailbox: the failure is reported and the account's coverage is marked partial instead of complete. The same applies to a POP3 index entry that cannot be read.
- A cached search result can no longer be returned for a different query. Search cache entries are keyed by a hash of the full query instead of a small hash bucket.
- Mail arriving in a mailbox now invalidates the cached search results that cover it, instead of waiting for the cache to expire. A search that started before the invalidation can no longer write its stale result back afterwards.
- Searching several accounts shares one overall time limit (`search_deadline_ms`), so a slow account no longer multiplies the total wait.
- With `excerpt`, the excerpt now centers on the searched text when the server can supply the body, instead of always starting at the beginning of the message. Punctuation, addresses and non-ASCII search terms are matched literally.

## 0.2.0 - 2026-11-26

This release covers three applications: `mailio` (the library, published on Hex), `mailio_store` and `mailio_mcp` (not published on Hex). Each has its own section, with breaking changes first. All three move to 0.2.0.

### mailio

#### Breaking

- An IMAP connection now defaults to STARTTLS, like POP3 and SMTP. Before, leaving out the TLS setting sent the password in plain text. Plain text needs the TLS setting turned off explicitly. A server that greets as already logged in is refused on a connection that has to be protected. IMAP, POP3 and SMTP all refuse a TLS setting they do not know, instead of using plain text.
- If you use the IMAP protocol module directly: a list of vanished messages is now reported as ranges, not as every number, and the function that expanded a set of UIDs is gone. A short replacement parses a set into ranges and another expands ranges up to a limit you choose. The reader of responses takes a start marker and a returned state, not a byte offset. [The library overview](apps/mailio/doc/overview.md) shows what to use.
- If you write a sync adapter: the adapter can report one more kind of change (read the whole mailbox again), every added message carries the mailbox identity it was listed under, and fetching a message may be asked to check that identity. Four optional callbacks are new: listing with a limit, the size and identity of a mailbox, the identity of a saved position, and fetching under an identity.
- Deleting a message needs a server that can remove by UID. Without that, deleting and moving by copy stop with an error before anything changes. Before, they could remove other messages that were marked as deleted.
- A supervised IMAP connection takes a credential by name (see New) and refuses a password, a token or anything else that could be a secret.

#### New

- Several processes can share one IMAP handle safely: a call that selects a mailbox and acts on it takes turns with the others. [Design decisions of the IMAP adapter](apps/mailio/doc/design-decisions.md) records why.
- Supervised connections: a child specification for a supervisor, and credentials kept under a name that you register and forget, so no secret appears in a supervisor report.
- A credential can be looked up by name, from a provider or from a function. The whole chain runs in one worker with one time limit and one depth limit, and the worker stops when the caller does.
- IMAP commands have a deadline. An IMAP listing can be limited, and the adapter says how many messages a mailbox holds and under which identity.
- Messages built by the library carry a Date header unless you give one.
- A page of design decisions for the IMAP adapter, and a section on shared and supervised connections in the overview.

#### Fixed

- Sockets: a POP3 or SMTP connection that fails while it is set up is closed, and so is a finished SMTP submission. An IMAP connection that drops, or is greeted with something that is not a greeting, closes its socket.
- A server can no longer make the library use unlimited memory. Oversized IMAP lines, messages and answers to one command, oversized POP3 and SMTP replies, and messages with thousands of parts are refused at a limit that you can change. A large list of vanished messages is not expanded in memory, and a line that arrives in small pieces is not re-read from the start each time.
- An IMAP command that is never answered ends with a timeout, a call that waited behind it is not sent late, and a lost IDLE answer or a disconnect during IDLE no longer leaves the caller waiting. A credential provider that loops, hangs or crashes can no longer freeze a connection or its caller.
- After a lost IMAP connection is made again: QRESYNC is enabled again on it, only when the server confirms it, the server's current capabilities are used, and a lost STARTTLS session starts again in plain text and upgrades, instead of trying TLS on the plain port.
- Wrong answers are errors, not an empty mailbox: a listing the server refuses, a search answer that is not valid, a mailbox size or next UID that is zero, has a leading zero or contradicts the number of messages, and a highest UID of zero. None of them leads to local mail being deleted.
- Listing a large mailbox is done in windows and a mailbox whose numbers are far apart is refused after a bound on the work.
- Deleting several messages no longer sends a wrong list of numbers, and only the body that belongs to the requested message is accepted.
- Reading mail opens mailboxes read-only. Reading a message over POP3 returns exactly what the server stored, and the IMAP connection reports what the server supports even when it does not announce it at login.
- SMTP: when every recipient answers with a temporary failure, sending reports a temporary failure, not a refusal. A permanent answer at the greeting or to EHLO, and a call with no recipient, are not reported as retryable. An unexpected answer is an error, not an exception.
- Generated mail follows the format rules: encoded words are at most 75 characters, lines of quoted-printable at most 76, long subjects and addresses are folded and keep their spaces, a body with a line over 998 characters is encoded, and text that is not valid UTF-8 no longer loops. Encoding a long line takes time in proportion to its length.
- The registry and event tables can only be written by their owners. Removing a registration and registering the same name again no longer lets the old process remove the new one. Unsubscribing from events no longer leaks a monitor.
- Errors of POP3 and SMTP credential providers no longer copy the provider's details into what is returned to callers.

### mailio_store

#### Breaking

- The sync adapter contract changed as described under `mailio` (new kinds of change, mailbox identity on added messages, optional callbacks). A store adapter written for the earlier form still works for mailboxes it can read in one piece, but must implement the identity check to be trusted with a recreated mailbox.
- Messages whose identifiers are the number 1 and the text "1" are now two messages. Mappings saved earlier are still found for their own identifier and move to the new form when the message is read again.

#### New

- A mailbox is read in pages, with bounds on the work and the memory a read may use. A mailbox found to have been recreated is written down, so a failed read or a restart still replaces what the store holds.
- The counters of a mailbox are kept up to date as mail arrives, changes and leaves. A change that fails part way leaves a mark, and the next change to any marked mailbox counts it again from the emails.

#### Fixed

- The store reads again, and brings its copy in line, when the server reports too many changes to list or the mailbox is recreated, before it keeps the new position. It checks the number of messages and the identity of the mailbox before it removes anything it did not list, and a read that does not agree is made again and then stops with an error that keeps local mail.
- The position never moves past mail that could not be fetched. A message is stored only whole: one that arrives shorter than the adapter said is refused. Errors while reading again, listing local mail, updating flags, removing or storing stop the update before the position is kept. A removal the database refuses is an error, not a crash.
- Listing the mail the store holds reaches the last one, not only the first thousand. A removal or a flag update on a later page of a full read is applied.
- When two copies of the same mail are in a mailbox and one is deleted on the server, the mail and its count stay while the other exists. A mail that is in two mailboxes and is delivered again to one no longer leaves a stale copy.
- Counters: a removal, an ingest, a flag update or a move that fails half way is repaired by the next change, for every mailbox it touched. A shared email that is read is not counted as unread in the second mailbox. Drafts are not counted as unread. A mailbox that cannot be read during a repair is an error that keeps the mark.
- After the server sent a response larger than the limit, every later sync of the account failed. The connection is now replaced. A sync started by an IDLE notification replaces a dead connection and keeps watching.
- An account whose mail server is unreachable stays up and reconnects later, and a crashing sync no longer takes the account and its writer down. If the registry restarts, the accounts restart with it.
- Rules and actions run in their own process with a time limit; a rule that fails is retried up to three times, so a rule action may run more than once for the same message.

### mailio_mcp

#### New

- The MCP server can run in a container: a Dockerfile, an example config, a Compose file and a page that explains how to run it over HTTP or stdio. CI publishes the image to the GitHub container registry after every change to the main branch.
- The HTTP settings can name the address as text and read the token secret from an environment variable or a file, so a config file does not have to hold a secret. The server stops at start with a clear message when its config file cannot be read.

#### Fixed

- The mail changes tool no longer reports every message as removed when the server refuses to list flags, does not report old messages as removed, or old messages coming back into view as new, when its snapshot covers only the newest ones, and its saved snapshot never grows past the configured size. A report of vanished messages that is malformed is not acted on in part: the whole mailbox is compared instead. It no longer reports the newest message again when nothing changed.
- Sending a message runs in a supervised process with a time limit and a cap on how many sends run at once. A send that crashes or times out is reported as "outcome unknown" and is never sent again on its own. When too many sends run, a new one is refused before anything is recorded.
