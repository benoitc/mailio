# Changelog

## Unreleased

### Added

- The MCP server can run in a container. A Dockerfile, an example config and a
  Compose file are in the repository, with a page that explains how to run it
  over HTTP or stdio. CI publishes the image to the GitHub container registry
  after every change to the main branch.
- The HTTP settings of the MCP server can now name the address as text and read
  the token secret from an environment variable or a file, so a config file
  does not have to hold a secret.
- The MCP server stops at start with a clear message when its config file
  cannot be read.

### Changed

- Breaking, for code that uses the IMAP protocol module directly: a list of
  vanished messages is now reported as ranges instead of a list of every
  number, and the function that expanded a set of UIDs into a list is gone. A
  short replacement parses a set into ranges and another expands ranges up to a
  limit you choose. [The library overview](apps/mailio/doc/overview.md) shows
  what to use.
- The sync adapter reports one more kind of change, telling the caller to read
  the whole mailbox again, for a server report that is too long to list.

### Fixed

- A POP3 or SMTP connection that fails while it is being set up is now closed.
  A finished SMTP submission is closed too. Before, each left a socket open for
  as long as the caller lived.
- A credential provider that loops, hangs or crashes can no longer freeze a
  connection or the caller. Each provider call has a depth and a time limit.
- An IMAP command that the server never answers now ends with a timeout
  instead of waiting for ever, and a call that waited behind it is not sent
  late. A lost IDLE answer or a disconnect during IDLE no longer leaves the
  caller waiting.
- An IMAP connection no longer holds on to what a failed command had
  collected, and one command can no longer collect without a limit.
- A list of vanished messages that is very large is no longer expanded in
  memory, and a range written from the larger number to the smaller one is read
  correctly instead of crashing the reader.
- When the server reports too many changes to list, or the mailbox is
  recreated with a new identity, the store now reads the mailbox again and
  brings its copy in line before it keeps the new position. Before, the new
  position was kept and the missed changes were never applied.
- A line that arrives in many small pieces is no longer re-read from the start
  each time.
- A listing that the IMAP server refuses is now an error. Before, it counted as
  an empty mailbox, and the store could delete local mail and keep the new
  position.
- A mailbox recreated while the store was reading it again no longer leaves
  old messages under reused numbers: a message is only trusted under the
  identity it was listed with.
- When two copies of the same mail are in a mailbox and one is deleted on the
  server, the store keeps the mail and its count while the other copy exists.
- Errors while the store reads a mailbox again, lists its local mail, updates
  flags or stores a message now stop the update before the new position is
  kept.
- A server report about vanished messages that is malformed, or has a marker
  other than the one defined, is no longer taken as a list of removals. The
  limit on how long such a report may be can only be lowered, not raised.
- The limit on one whole response now also applies while the end of a line is
  still awaited.
- An IMAP connection that drops, or is greeted with something that is not a
  greeting, closes its socket and releases what the interrupted command had
  collected.
- Checking a mailbox for new mail no longer reports the newest message again
  when nothing changed. Real servers return the last message for any range that
  starts past the end.
- Reading a message over POP3 now returns exactly what the server stored. The
  last line used to lose its line ending.
- The IMAP connection now reports what the server supports even when the server
  does not announce it at login. It used to report nothing.
- A mail server can no longer make mailio use unlimited memory. Oversized IMAP
  lines and messages, oversized POP3 and SMTP replies, and messages with
  thousands of parts are refused or cut off at a limit. The limits can be
  changed in the configuration.
- Sending a message now runs in a supervised process with a time limit and a
  cap on how many sends run at once. A send that crashes or times out is
  reported as "outcome unknown" and is never sent again on its own. When too
  many sends are running, a new one is refused before anything is recorded.
- An account whose mail server is unreachable now stays up and reconnects
  later, instead of being stopped after a few failed attempts. A crashing sync
  no longer takes the account and its writer down with it.
- If the registry restarts, the accounts restart with it, so no account is left
  running but unreachable.
- Removing a registration and registering the same name again no longer lets
  the old process remove the new one when it exits.
- Rules and actions now run in their own process with a time limit. A rule that
  fails is retried up to three times instead of being skipped for good, so a
  rule action may run more than once for the same message.
- Reading mail now opens mailboxes read-only. Only changing flags, moving and
  deleting open them for writing.
- Unsubscribing from events no longer leaks a monitor.
- POP3 and SMTP credential-provider failures no longer copy provider details
  into errors returned to callers.
- The Dovecot test suite waits once for the server and then skips with one
  clear message, instead of failing or skipping each case.
