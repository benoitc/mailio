# Design decisions of the IMAP adapter

This page records five decisions about how `mailio_imap` and the credential code behave, why they were made, and which test fails if one of them is undone. You need it when you change one of these behaviours, or when you wonder why a call is refused or waits. Each decision has what it is, why, how to change it, and where it is tested.

## 1. One session at a time on a shared connection

**What.** A call of `mailio_imap` that selects a mailbox and then acts on it (fetch, flags, move, expunge, list, watch) holds the connection until it is done. Other callers of the same handle wait, in the order they asked, up to two minutes.

**Why.** An IMAP connection has one selected mailbox, and a command such as `UID STORE` acts on whatever is selected when it arrives. Two callers that each select and then send can otherwise land a command on the other one's mailbox, and flag or expunge the wrong message.

**To change it.** The turns are kept by `mailio_imap_lock`, an internal module. Every public function that selects goes through `session/2` in `mailio_imap`; a new function that selects must too.

**Tests.** `mailio_imap_session_tests` (`concurrent_fetches_each_see_their_own_mailbox_test_`, `concurrent_changes_go_to_their_own_mailbox_test_`, `a_caller_that_dies_gives_up_its_turn_test`) and `mailio_imap_lock_tests`.

## 2. QRESYNC is negotiated on every login and used only when confirmed

**What.** After every login (and after a greeting that is already logged in) the connection asks for the server's capabilities again and, if it offers QRESYNC, sends `ENABLE QRESYNC`. It reports QRESYNC as available only when the server answered `* ENABLED QRESYNC`. The adapter reads the capabilities of the connection it is using at each read.

**Why.** QRESYNC must be enabled on each connection (RFC 7162, section 3.2.3). A connection that was lost and made again is a new one, possibly to a server that offers less, and an empty `* ENABLED` is not an enablement. A handle that remembered the first connection's capabilities sent commands the new session refused, or did not know.

**To change it.** `negotiate` in `mailio_imap_conn` and `do_fetch_changes` in `mailio_imap`. The `qresync => false` option turns it off.

**Tests.** `mailio_imap_SUITE`: `qresync_is_enabled_again_after_a_reconnect`, `qresync_is_negotiated_after_a_preauth_greeting`, `an_empty_enabled_answer_leaves_qresync_unused`, `a_server_that_lost_its_extensions_is_read_without_them`.

## 3. A full read checks the mailbox before it removes anything

**What.** The store reads a mailbox again in full when a cursor cannot be trusted. Before it removes a message it did not list, it asks the adapter (`mailbox_info/2`) how many messages the mailbox holds and under which UIDVALIDITY, and compares both with what the read listed. A mismatch means the mailbox changed during the read: it is read again, a few times, then the call is an error and local mail is kept. A listing for reconcile (`list_uids`) is held to the same count.

**Why.** A UID means a message only under one UIDVALIDITY (RFC 3501, section 2.3.1.1). A listing that missed messages, or one taken from a mailbox that was recreated, looks like "these messages are gone", and acting on it deletes mail that is still there.

**To change it.** `inventory_matches` in `mailio_sync_mgr` and `list_uids` in `mailio_imap`. An adapter that cannot report its size leaves `mailbox_info/2` out and its reads are not checked.

**Tests.** `mailio_sync_SUITE`: `a_full_read_that_misses_messages_removes_nothing`, `a_full_read_of_a_recreated_mailbox_is_not_accepted`, `an_empty_read_of_another_generation_is_not_accepted`; `mailio_imap_SUITE`: `a_listing_that_misses_messages_is_an_error`, `a_cursor_needs_a_valid_uidvalidity`.

## 4. Expunge removes the messages you name, or nothing

**What.** `expunge/3` sends `UID EXPUNGE` for the UIDs it was given. A server without UIDPLUS has only `EXPUNGE`, which also removes every message another client has flagged `\Deleted`; there the call returns `imap_operation_unsupported` before it flags anything. A move uses `UID MOVE` when the server has MOVE, and copy then `UID EXPUNGE` when it has UIDPLUS, and is refused with neither. The check uses the capabilities of the current connection, after the mailbox is selected and before the first change.

**Why.** Another client can flag a message at any moment, so checking beforehand does not make a mailbox-wide `EXPUNGE` safe (RFC 4315, section 2.1). Refusing is better than deleting mail nobody named. The check is on the current connection because a handle can outlive the connection it was opened on.

**To change it.** `do_expunge_set` and `do_move` in `mailio_imap`.

**Tests.** `mailio_imap_session_tests` (`expunge_removes_only_the_named_messages_test`, `expunge_sends_the_uids_it_was_given_test`, `expunge_without_uidplus_is_refused_before_anything_is_changed_test`, `move_without_move_or_uidplus_is_refused_before_copying_test`); `mailio_imap_SUITE`: `expunge_after_a_reconnect_checks_the_session_not_the_handle`, `move_after_a_reconnect_checks_the_session_not_the_handle`; and `imap_expunge_removes_only_the_named_message` in `mailio_interop_SUITE` against Dovecot, GreenMail and Stalwart.

## 5. A supervised connection holds a name, never a secret

**What.** `mailio_imap_conn:child_spec/1` accepts `credentials => {ref, Name}` or a zero-argument `{token_fun, Fun}`, and refuses everything else. The credential is kept with `mailio_credentials:register_ref/2` and looked up inside the connection's own worker at each login. Looking up, calling a provider and following what it returns happen in one worker with one time limit and one depth limit, and the worker stops with its caller.

**Why.** A supervisor writes the start arguments of its children in its reports, and the status redaction of the connection cannot reach those. A password, a token, or the arguments of a provider (the bundled static one keeps passwords there) would be printed. The worker rule keeps a provider that hangs from outliving the connection that asked.

**To change it.** `secret_in/1` and `child_spec/1` in `mailio_imap_conn`; `resolve/2` in `mailio_credentials`.

**Tests.** `mailio_tables_tests` (`child_spec_refuses_a_secret_test`, `child_spec_error_does_not_echo_the_value_test`); `mailio_resource_tests` (`the_deadline_covers_the_whole_chain_test`, `a_timed_out_provider_leaves_nothing_running_test`, `a_caller_that_dies_cancels_the_lookup_test`, `an_infinite_timeout_resolves_test`).
