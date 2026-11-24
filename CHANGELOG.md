# Changelog

## Unreleased

### Fixed

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
- The Dovecot test suite waits once for the server and then skips with one
  clear message, instead of failing or skipping each case.
