# How the store reads a mailbox

This page explains how `mailio_store` brings a mailbox in line with the server, and what stops it from keeping a wrong copy. You need it when a sync stops with an error and you want to know why, or when you set one of its limits.

## The position it keeps

For each mailbox the store keeps a position (a cursor). A sync asks the adapter for what changed since it. The position moves forward only after the changes it leads to have been applied, so a sync that fails is repeated, never skipped. A message that cannot be fetched stops the update with an error; once it can be fetched, the next update stores it.

## When it reads the whole mailbox

The store reads the whole mailbox, and brings its own copy in line, in three cases:

- there is no position yet (the first read, or one that failed halfway earlier);
- the server says the mailbox was recreated (UIDVALIDITY changed), after which every UID held means another message;
- the server reports more changes than the adapter will list.

A full read applies each page as it comes, so only the UIDs it has seen are kept in memory. When it reaches the last page, it removes what it holds and the server did not list, and only then saves the position. If the mailbox is recreated while it is being read, the read starts again, and from then on every UID held is replaced. That decision is written to the database, so it survives a failed attempt and a restart.

## Limits

Set them in the `mailio_store` application environment.

| Key | Default | What happens past it |
|---|---|---|
| `sync_max_pages` | 100,000 | The read stops with `too_many_pages`. A reading that answers "more" with a position it gave before stops with `repeated_cursor`. |
| `sync_max_listed_uids` | 10,000,000 | A full read stops with `mailbox_too_large_to_resync`. |

In both cases nothing is changed and the position stays where it was.

## Where to look

| You want to | Look at |
|---|---|
| Change how pages are walked | `src/mailio_sync_pages.erl` |
| Change what a full read does | `full_resync/6` and `finish_resync/5` in `src/mailio_sync_mgr.erl` |
| Change how UIDs are kept as ranges | `src/mailio_uid_set.erl` |
| See the tests | `test/mailio_sync_SUITE.erl`, `test/mailio_sync_pages_tests.erl`, `test/mailio_uid_set_tests.erl` |
