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

### Fixed

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
