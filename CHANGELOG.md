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
- The store now reads a large mailbox in pages. A reading that makes no
  progress, or never ends, is stopped with an error instead of keeping the
  process busy, and the pages are put together without copying them over and
  over. If the mailbox is recreated while it is being read, the pages read so
  far are discarded and the reading starts again.
- The IMAP adapter lists a mailbox in windows, so a mailbox with more messages
  than one command may collect no longer ends the connection. This also applies
  to listing UIDs.
- A message the store cannot fetch no longer lets the position move past it: the
  position stays and the next update tries again. This includes an adapter that
  cannot check the mailbox identity when it fetches.
- When the same mail is in two mailboxes and is delivered again to one, the
  mailbox no longer keeps a stale copy and a count of one after its last copy is
  gone.
- Replaying a page after a failed fetch no longer stops the account writer: a
  message that was already stored under the same number is simply recognised.
- A server that leaves out the next UID when a mailbox is opened no longer makes
  a mailbox look empty. The highest UID is asked for instead, and if that fails
  the update stops with the mail and the position unchanged.
- When a mailbox is recreated during a read, the store replaces what it holds
  even when the adapter does not say which identity a message was listed under.
- A flag update that the server volunteers for a message that was not asked for
  is no longer taken for new mail.
- A listing window is cut to what the connection allows for one command, and a
  mailbox whose numbers are far apart is refused after a bound on the work
  instead of being searched for ever.
- The store's first read of a mailbox now also brings in line what an earlier
  read that failed halfway had stored: mail removed on the server meanwhile is
  removed, a recreated mailbox replaces the messages, and flags are corrected,
  before the position is kept. A full read no longer keeps all the pages in
  memory, only the numbers it has seen, and stops with an error past a limit.
- A search for the UIDs of a mailbox that is not answered in full is now an
  error, and so is a mailbox whose size the server does not give: neither is
  taken for an empty mailbox, and local mail is not removed on their account.
- Listing the mail the store holds for a mailbox now reaches the last one.
  Before, it stopped after the first thousand, so a full read or a clean-up of
  a larger mailbox left mail behind and still kept the new position. This also
  corrects every other place that listed a collection by its identifier.
- A reply to a UID search that is not valid, for example one with a closing
  bracket or a number outside the range asked for, is now an error. The form a
  server uses with change tracking, with the modification number after the
  numbers, is accepted. A "next UID" of zero is not trusted.
- The store now applies flag updates that arrive on later pages of a full read,
  and counts distinct numbers when it limits how many it keeps, in whatever
  order they come.
- When a mailbox is found to have been recreated, the store writes that down.
  If the read that follows fails, or the process restarts, the next read still
  replaces what it holds, even for an adapter that does not say which identity a
  message was listed under.
- A reply to a UID search that holds only the change-tracking suffix is no longer
  taken for an empty result: a server leaves the suffix out when nothing
  matched, so such a reply is malformed and the listing stops with an error.
- A "next UID" or a mailbox identity written with a leading zero or a sign is no
  longer read as the number it looks like, which made a mailbox with mail look
  empty. The highest UID is asked for instead.
- A provider whose message identifiers are not numbers can be read by the store
  again: two different identifiers are two messages, in a first read, in a later
  one and when the store reconciles with the server.
- A report of vanished messages without a list of numbers, or with one that is
  not well formed, is no longer acted on in part. Both the store and the MCP
  server compare the whole mailbox instead.
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
- A server answer of "highest UID 0", a search answer with a malformed or zero
  mod-sequence, or a mailbox with no valid UIDVALIDITY could make a mailbox
  look empty or let an old position cross into a new copy of the mailbox, so
  local mail was deleted or skipped. These answers are now errors, and a
  position saved without a known UIDVALIDITY makes the mailbox read again in
  full.
- Messages whose ids are the number 1 and the text "1" were stored as one
  message. They are now kept apart. Mappings saved by an earlier version are
  still found for their own id only, and move to the new form when the message
  is read again.
- A mailbox whose answers contradict each other (for example two messages and
  a next UID of 1, or an invalid highest UID next to an update for another
  message) is no longer listed. The read stops with an error and local mail is
  kept. A saved position that knows nothing about the mailbox now makes it be
  read again in full.
- Reconcile no longer deletes local mail when the server's list of UIDs does
  not match the number of messages it reports. The list is read again a few
  times, and then the sync stops with an error and keeps local mail.
- A full read now applies a removal that arrives on a later page, instead of
  keeping the message and saving a position that hides it.
- A message that the adapter hands over in several pieces is stored whole, and
  one that arrives shorter than the adapter said is refused instead of stored
  with a missing body.
- A removal that stops half way is finished by the next one and no longer
  leaves an email counted in an empty mailbox. A shared email that is already
  read is no longer counted as unread in the second mailbox.
- After the server sent a response larger than the limit, every later sync of
  that account failed. The connection is now replaced and the next sync runs.
- The list of UIDs that reconcile reads stops at the configured limit as it is
  read, instead of after the whole list is held.
- The mail changes tool no longer reports every message as removed when the
  server refuses to list flags, and its saved snapshot never grows past the
  configured size.
- Mappings written by the intermediate build of this branch are still found.
- A full read now checks the number of messages it listed against the number
  the server holds before it removes anything it did not list. A read that
  missed messages is made again, and after a few tries the sync stops with an
  error and keeps local mail.
- The mail changes tool no longer reports old messages as removed, or old
  messages coming back into view as new, when its snapshot only covers the
  newest ones.
- Several callers can now share one IMAP connection safely. Before, a call
  that selects a mailbox and then reads or changes a message could act on
  the mailbox another caller had just selected. Callers now take turns.
- Deleting or moving a message on an IMAP server no longer removes other
  messages that were marked as deleted. Removing several messages at once also
  sent a wrong list of numbers and could remove a message nobody named. A
  server that cannot remove by UID is no longer used for deleting or for
  moving by copy: the call stops with an error before it changes anything.
- A full read also checks that the mailbox was not recreated while it was
  being read, and a removal the store refuses is now an error that keeps the
  saved position, not a crash of the sync.
- A message is stored only from the body the server sent for that message. A
  body for another message, or one with no message number, is an error.
- A removal that fails between updating the email and updating the counter is
  repaired by the next change to that mailbox.
- A sync started by an IDLE notification replaces a dead connection and keeps
  watching on the new one. The message sink handed to adapters always answers
  ok, as documented, and a message over the size limit is refused afterwards.
- Reading mail now opens mailboxes read-only. Only changing flags, moving and
  deleting open them for writing.
- Unsubscribing from events no longer leaks a monitor.
- POP3 and SMTP credential-provider failures no longer copy provider details
  into errors returned to callers.
- The Dovecot test suite waits once for the server and then skips with one
  clear message, instead of failing or skipping each case.
