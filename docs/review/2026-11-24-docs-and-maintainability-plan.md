# Documentation and maintainability plan

Review of `main` at `f32c280`, 2026-11-24. This page is the plan only: no source code was changed. Read it to decide what must be fixed before a release and what can wait. The release waits until you have said which findings go first.

## What the review found, in short

- The docs are good where they exist (1,049 lines in 16 Markdown files, second person, task oriented) but there is **no page that takes a newcomer from "what is this" to "where do I change X"**. The README is a build page, `AGENTS.md` is for agents, and the best architecture text (`apps/mailio_mcp/doc/design.md`) covers only one of three apps.
- The biggest finding is architectural, not about size: **`mailio_store` and `mailio_mcp` are two parallel stacks that never meet.** Both have their own IMAP adapter, search, permission model, change tracking and durable state. The docs never say which one is the product and which one is the future. This needs your answer (question 1).
- The code is smaller and more regular than the project's history suggests: 16.6k lines of source in 3 apps, every module but one has a module doc. Only one module is clearly oversized for what it does (`mailio_mcp_imap`, 1,160 lines).
- Several things sit in the wrong app or have a misleading name (`mailio_events` and `mailio_registry` live in the "OTP only" library but serve only the store; two different things are called "adapter").

## Measurements

Source lines per app: `mailio` 5,556 (19 modules), `mailio_store` 5,267 (29), `mailio_mcp` 5,827 (28). Tests and fakes: 9,262 lines.

| Module | Lines | Functions | Exports | Longest function | Verdict |
|---|---|---|---|---|---|
| `mailio_mcp_imap` | 1,160 | 64 | 13 | `full_changes` 74 | several responsibilities, see M1 |
| `mailio_imap_proto` | 691 | 70 | 31 | `read_response` 29 | large but coherent (wire format) |
| `mailio_mcp_pop3` | 642 | 36 | 9 | `changes` 53 | same shape as `mailio_mcp_imap`, see M1 |
| `mailio_account_writer` | 642 | 59 | 15 | `full_ingest` 95 | one role, one long function, see M2 |
| `mailio_imap_conn` | 604 | 42 | 21 | `auth` 39 | coherent state machine |
| `mailio_rfc5322` | 583 | 49 | 13 | `collect_ids` 33 | coherent |
| `mailio_imap` | 581 | 49 | 13 | `fetch_updated` 40 | coherent adapter |
| `mailio_mcp_search` | 567 | 33 | 1 | `run` 72 | one entry point, long pipeline, see M3 |
| `mailio_sync_mgr` | 499 | 36 | 11 | `apply_change` 49 | coherent |
| `mailio_mcp_time` | 479 | 32 | 9 | `parse_header_date` 36 | coherent but hides a second job, see M4 |
| `mailio_mcp_tools` | 361 | 19 | 9 | `catalog` 162 | the long function is data |
| `mailio_mcp_changes` | 305 | 15 | 1 | `build` 78 | long function, see M3 |
| `mailio_smtp` | 431 | 26 | 1 | `session` 68 | long function, protocol script |

Function counts are clause groups by name. Longest functions are measured from clause start to the next function.

## Where a newcomer gets lost today

| Question | Today |
|---|---|
| What is this project? | README says "which app to use", not what the whole thing is for |
| Which app is the product? | Not stated. The MCP server is the only runnable entry point (`mailio_mcp_main`); the store has no entry point and nothing depends on it |
| What is the main flow? | Only for the MCP server, in `design.md` prose, with no picture |
| Where do I add a protocol? | Two different "adapter" behaviours exist (`mailio_adapter` in the library, `mailio_mcp_adapter` in the MCP app); nothing explains why |
| What does `mailio_store` give me? | Only `blobs.md`, which covers one feature of it |
| Where do the library's limits and options live? | Spread across module docs; the new size limits are listed only in `AGENTS.md` |
| What is public API? | No statement; no `ex_doc` pages are built |

## Recommended structure

A path from orientation to implementation. Keep the per-app `doc/` folders for task pages; add one top-level reading path.

```
README.md                         start here: what, who for, the three apps, 5-minute run
docs/
  concepts.md                     vocabulary and the one-picture overview
  architecture.md                 how the pieces fit and why, with the decisions
  map.md                          concept to directory, module and test
  guides/
    add-a-protocol.md
    change-a-behaviour.md
    add-an-mcp-tool.md
    debug-a-request.md
    run-the-real-server-tests.md
  review/                         dated plans like this one
apps/mailio/doc/overview.md       what the library is, how to use it without the other apps
apps/mailio_store/doc/overview.md what the store is, who uses it, state of its integration
apps/mailio_mcp/doc/ (existing)   design.md, capabilities.md, client-setup.md
```

## Main starting point

`README.md`, rewritten as the front door: two paragraphs on what mailio is for, a three-row table of apps with "you use this if...", the quick start to run the MCP server against one account, and "Read this next" links to `docs/concepts.md`, `docs/map.md` and `CONTRIBUTING.md`. Everything about running the real-server test suites moves out to a guide.

## Existing documents: what to do

| Document | Lines | Action | Reason |
|---|---|---|---|
| `README.md` | 50 | **Rewrite** | Build and test page today; move test-server instructions to `docs/guides/run-the-real-server-tests.md` and keep a link |
| `AGENTS.md` | 218 | **Keep, trim** | Right content for agents. The "where to start" table duplicates what `docs/map.md` will hold: replace it with a link. The specification table is useful for humans too: link it from `CONTRIBUTING.md` |
| `apps/mailio_mcp/AGENTS.md` | 52 | **Keep** | Short and specific |
| `CLAUDE.md` (both) | 3 | **Keep** | Pointers |
| `CONTRIBUTING.md` | 143 | **Keep, add** | Good; add "If you want to..." links to the new guides. The first section is about writing style; move it after "Set up" so the first thing a contributor reads is how to build |
| `SECURITY.md` | 26 | **Keep** | |
| `CHANGELOG.md` | 31 | **Keep** | Already follows the user's rules |
| `mailio_mcp/doc/design.md` | 51 | **Keep, split once** | Dense but good. The adapter comparison table (JMAP, Gmail, Graph) is a decision record: move it to `docs/architecture.md` under "Decisions". The rest stays |
| `mailio_mcp/doc/capabilities.md` | 55 | **Keep, refresh** | The cost numbers predate the read-only `EXAMINE` and IDLE changes: re-measure (open item from the fix branch) |
| `mailio_mcp/doc/client-setup.md` | 127 | **Keep** | Task oriented and the right size |
| `mailio_store/doc/blobs.md` | 76 | **Keep** | Good task page |
| `.agents/skills/*` | 172 | **Keep** | Agent workflow, not reader docs |
| `apps/mailio/test/VENDORED_TESTS.md` | 42 | **Keep, move link** | Link it from the test section of the map |

## New documents

Each states its intent, reader, what they understand afterwards, where it points next and its depth.

| Document | Reader | After reading, you can... | Next | Depth |
|---|---|---|---|---|
| `docs/concepts.md` | Anyone new | explain account, mailbox, handle, cursor, checkpoint, draft, revision, idempotency key, blob, outcome unknown, adapter | `architecture.md` | 1 page, glossary plus one overview diagram |
| `docs/architecture.md` | Contributor | say why the library is OTP-only, what the store is for, why the MCP app holds its own state, how a search and a send flow through | `map.md` | 2 pages, decisions with reasons, two sequence diagrams |
| `docs/map.md` | Contributor | find the module and the test for any concept in under a minute | the guides | 1 table, no prose beyond the intro |
| `guides/add-a-protocol.md` | Contributor | add a transport or provider (JMAP is the stated next one) and know which behaviour to implement | `protocol-change-review` skill | short, steps and files |
| `guides/change-a-behaviour.md` | Contributor | pick the right layer for a change, run the three checks, and know which tests fail first | `CONTRIBUTING.md` | short |
| `guides/add-an-mcp-tool.md` | Contributor | add a tool, keep it inside the 8 KiB budget, and update the catalog size in `capabilities.md` | `design.md` | short |
| `guides/debug-a-request.md` | Contributor | follow one `mail_search` or `draft_send` call through the modules, with the log and stats switches | `map.md` | short, one worked trace |
| `guides/run-the-real-server-tests.md` | Contributor | start GreenMail, Mailpit and Dovecot and run each suite, including the one-time skip behaviour | `CONTRIBUTING.md` | short, moved from README |
| `apps/mailio/doc/overview.md` | Library user | use the IMAP, POP3 and SMTP clients and the MIME parser without the other apps, and set the size limits | module docs | 1 page with limits table |
| `apps/mailio_store/doc/overview.md` | Store user | know what the store offers, what uses it today, and its status (question 1) | `blobs.md` | 1 page |
| `docs/limits.md` (or a section of `overview.md`) | Operator and contributor | see every configurable limit and timeout in one table (IMAP, POP3, MIME, send, workflow) | | 1 table |

## Concepts that need their own explanation

The terms below are used in code and docs without a definition in one place: **account** (a mail account in the MCP app versus an account database in the store), **handle**, **cursor and checkpoint** (signed and bound to the caller), **blob** (store) versus **part** (MIME), **outcome unknown**, **idempotency key**, **adapter** (two meanings), **budget**, **grant** (store) versus **role and identity** (MCP), **QRESYNC, CONDSTORE, IDLE** (why a contributor needs them: they decide how much a poll costs).

## Navigation map (seed for `docs/map.md`)

| You want to change... | Look at | Tests |
|---|---|---|
| IMAP wire behaviour | `apps/mailio/src/mailio_imap_conn.erl`, `mailio_imap_proto.erl` | `mailio_imap_proto_tests`, `mailio_imap_limits_tests`, `mailio_imap_conn_auth_tests`, `mailio_imap_SUITE`, Dovecot suite |
| POP3 or SMTP wire behaviour | `mailio_pop3.erl`, `mailio_smtp.erl` | `mailio_pop3_tests`, `mailio_smtp_tests`, `mailio_smtp_mailpit_SUITE` |
| Parsing or building a message | `mailio_mime*.erl`, `mailio_rfc5322.erl` | `mailio_mime_*tests`, `mailio_mime_corpus_SUITE`, `mailio_mime_prop_SUITE` |
| An MCP tool | `mailio_mcp_tools.erl`, then `mailio_mcp_search`, `_read`, `_changes`, `_draft`, `_send` | `mailio_mcp_unit_tests`, `mailio_mcp_e2e_SUITE` |
| Output size or truncation | `mailio_mcp_budget.erl`, `mailio_mcp_view.erl` | `mailio_mcp_unit_tests` |
| Permissions | `mailio_mcp_authz.erl`, `mailio_mcp_config.erl` | `mailio_mcp_unit_tests` (authz) |
| Sending and its safety | `mailio_mcp_draft.erl`, `mailio_mcp_send.erl`, `mailio_mcp_send_workers.erl` | `mailio_mcp_send_tests`, e2e |
| Time zones in search | `mailio_mcp_time.erl` | `mailio_mcp_unit_tests` |
| What is stored and how | `mailio_account_writer.erl`, `mailio_blob*.erl`, `mailio_db.erl` | `mailio_ingest_SUITE`, `mailio_blob_SUITE`, `mailio_durability_SUITE` |
| Sync from a server | `mailio_sync_mgr.erl`, `mailio_sync_sup.erl` | `mailio_sync_SUITE`, `mailio_supervision_SUITE` |
| Rules, actions, agents | `mailio_rules`, `mailio_actions`, `mailio_workflow_consumer`, `mailio_agent`, `mailio_grant` | `mailio_workflow_SUITE`, `mailio_agent_SUITE` |
| Process lifecycle | `mailio_sup`, `mailio_accounts_sup`, `mailio_account_sup`, `mailio_registry` | `mailio_supervision_SUITE`, `mailio_registry_tests` |

## Modules and subsystems that need better documentation

Role classification and what each needs:

| Module or area | Role | Needs |
|---|---|---|
| `mailio_mcp_tools`, `mailio_mcp_budget`, `mailio_mcp_handle`, `mailio_mcp_authz` | core of the MCP product | a short page each in `architecture.md`, not separate files |
| `mailio_mcp_store`, `mailio_mcp_cache` | core state | one paragraph on what is durable and what is cache (the design page has it; the modules do not link to it) |
| `mailio_mcp_imap_io` | internal helper | module doc says it is a thin connection wrapper; nothing more |
| `mailio_mcp_smtp`, `mailio_mcp_mime` | bridges to the library | one line each saying "use the library module directly if you are writing new code" |
| `mailio_store` as a whole | core, status unclear | `overview.md` (question 1) |
| `mailio_adapter` and `mailio_mcp_adapter` | two behaviours with the same name | a comparison in `architecture.md` and a rename (see N1) |
| `mailio_mcp_sup` | supervisor | has no module doc; add the restart rules (store, cache, send, workers in `rest_for_one`) |
| `mailio_events`, `mailio_registry` | infrastructure | say who uses them (only the store) |

## Maintainability findings

Primary problem in brackets.

**A1. Two parallel stacks (architecture).** `mailio_mcp` does not use `mailio_imap` (the adapter the store uses); it speaks IMAP through `mailio_imap_conn` and `mailio_imap_proto` with its own `mailio_mcp_imap` (1,160 lines) and `mailio_mcp_imap_io`. It also has its own permission model (`mailio_mcp_authz`: roles and identities) beside the store's (`mailio_grant`: scopes and mailbox rules), its own search (`mailio_mcp_search`, 567 lines) beside `mailio_search` and `mailio_email:query`, its own change tracking and durable state (dets) beside docdb. Nothing in `mailio_store` is used by the runnable product. This is either a deliberate split (MCP is stateless against the server, the store is a local index) or a leftover from building the store first. The docs cannot be written honestly until you say which. A future refactor, if you want one, would touch `mailio_mcp_imap`, `mailio_mcp_search`, `mailio_mcp_changes`, `mailio_store` and both agent suites.

**M1. `mailio_mcp_imap` and `mailio_mcp_pop3` mix several jobs (module organisation).** `mailio_mcp_imap` holds mailbox listing and name encoding, search translation and execution, message fetch and part extraction, thread building, change tracking (`full_changes`, QRESYNC, snapshot diff), IDLE waiting and account health, all in one adapter module of 64 functions. The boundaries are visible and already named in the code by section. Document them first; a split into search, read, changes and wait modules behind the same `mailio_mcp_adapter` behaviour would likely help, and would affect `mailio_mcp_imap_changes_tests`, the Dovecot suite and the e2e suite. `mailio_mcp_pop3` has the same shape at smaller scale; split it only if IMAP is.

**M2. `mailio_account_writer:full_ingest` is 95 lines (code complexity).** It is the one writer for an account, so a large ingest is natural, but one 95-line function that threads, indexes and stores blobs is hard to review. Look at it before touching ingest; extracting named steps would help. Tests: `mailio_ingest_SUITE`, `mailio_durability_SUITE`.

**M3. Long pipelines in `mailio_mcp_search:run` (72) and `mailio_mcp_changes:build` (78) (code complexity).** Both are many sequential steps in one function. Check whether each step can be named; no module split needed. Tests: e2e and unit suites.

**M4. `mailio_mcp_time` holds two jobs (module organisation).** Time zone rules and window arithmetic (the reason the module exists) plus RFC 5322 date parsing (`parse_header_date`, month tables). Date header parsing belongs near `mailio_rfc5322`. Low priority.

**N1. Two things called "adapter" (naming).** `mailio_adapter` is the store-facing sync contract (connect, fetch changes since, set keywords); `mailio_mcp_adapter` is the tool-facing contract (search, read, thread, changes). They solve different problems. Rename or at least document the difference before JMAP is added, or a contributor will implement the wrong one.

**N2. `mailio_events` and `mailio_registry` sit in the "OTP only" library (module organisation).** They are process infrastructure used only by `mailio_store` (five modules). A reader of the library docs will not expect them. Moving them is a small change, but only worth doing if the library is published separately; otherwise document them as store infrastructure.

**N3. `mailio_barrel_spike_SUITE` is a spike left in the test tree (navigation).** Its own header says it pins down docdb behaviour "before those layers are built". Decide whether it is still a guard (then rename and keep) or a record (then delete).

**N4. `mailio_mcp_tools:catalog` is 162 lines (architecture, acceptable).** It is the tool catalog as data and must stay in one place for the byte count. No action beyond a comment saying so.

**N5. `data/` in the repository root is ignored but present (navigation).** Runtime state from tests and local runs; harmless, but say in `CONTRIBUTING.md` that it is safe to delete.

Not findings: `mailio_imap_proto` (691 lines, 31 exports) is large but is one thing, the IMAP wire format, with the longest function at 29 lines. `mailio_imap_conn`, `mailio_rfc5322`, `mailio_sync_mgr` are coherent.

## Contributor workflows ("If you want to...")

Each becomes a short guide pointing at real files.

- **Add a protocol or provider (JMAP).** Decide which contract: the store side is `mailio_adapter` (see `mailio_imap.erl` as the model, tests in `mailio_imap_SUITE`); the tool side is `mailio_mcp_adapter` (see `mailio_mcp_imap.erl`). Add a fake server in `test_support/`, then a real-server suite. Run the `protocol-change-review` skill.
- **Change a behaviour.** Find the layer in `map.md`, write the failing test first, run the three checks in `AGENTS.md`, then the commands in `CONTRIBUTING.md`.
- **Add an MCP tool.** Add it to the catalog in `mailio_mcp_tools`, call into a focused module, keep results through `mailio_mcp_budget`, check the catalog byte count, add a unit and an e2e test, update `capabilities.md`.
- **Add a send or draft rule.** Start at `mailio_mcp_send` and read the idempotency rules in `design.md` first; never turn `outcome_unknown` into a retry.
- **Add a limit.** Pick the name with the existing prefix, default in the module, list it in `docs/limits.md`, test that a hostile peer hits it.
- **Debug a request.** Start from `mailio_mcp_tools`, follow to the adapter, use `mailio_mcp_stats` counters and the `io_hook` byte counts; the guide holds one worked trace.
- **Replace the blob backend.** `mailio_blob` behaviour switch, `blobs.md`, `mailio_blob_SUITE`.

## Diagrams and examples that would help

1. One overview diagram: three apps, who depends on whom, and the (missing) arrow between store and MCP.
2. Sequence of a `mail_search` call: tool, authz, adapter, budget, handle signing.
3. Sequence of a `draft_send`: record written, worker started, three outcomes.
4. Supervision tree of `mailio_store` and `mailio_mcp` (both changed recently and are not written down anywhere).
5. A worked example of a handle and a cursor (what is inside, what binds it to a caller).

## Decisions from the maintainer (2026-11-24)

1. `mailio_store` is a separate product, a sibling of `mailio_mcp`, not its future backend and not a leftover. Any convergence is a later, separate decision. Recorded in `docs/architecture.md`.
2. Only `mailio` is published on Hex for this release; `mailio_mcp` and `mailio_store` are not. Before publishing it needs: a defined public API, public module docs, a limits table, ExDoc and package metadata, and a standalone usage guide.
3. None of M1 to M4 and N1 to N4 blocks the release. Required before it: re-measure `capabilities.md`, write the architecture page, finish the library overview and limits table, document and configure a persistent `request_state_key`, and run the release validation matrix.

Status of the required items:

| Item | Status |
|---|---|
| Re-measure `capabilities.md` | done (numbers unchanged within a few bytes) |
| `docs/architecture.md` | done |
| Library overview, limits table, usage guide, public API tiers | done: `apps/mailio/doc/overview.md`, `usage.md` |
| ExDoc and package metadata | done: `apps/mailio/rebar.config`, `mailio.app.src`; `rebar3 hex build` builds package and docs |
| Persistent `request_state_key` | done: `request_state_key` secret reference in the `mailio_mcp` config, documented in `client-setup.md` |
| Validation matrix | done, see below |

Validation matrix on this branch: erlfmt clean; compile with no warnings; eunit 265 pass; elvis clean; xref clean; Dialyzer 4 warnings, all in old code (`mailio_imap` twice, `mailio_rfc5322`, `mailio_account_writer`) and accepted; library CT 27 pass (includes Mailpit); store CT 70 pass; mcp CT 23 pass (9 GreenMail end-to-end, 14 Dovecot); `rebar3 tree` shows `mailio_mcp` and `mailio` free of `mailio_store` and `barrel_docdb`; `rebar3 hex build` builds the package and docs for `mailio`.

Still open before publishing `mailio`:

- There is no `LICENSE` file in the repository, and `mailio.app.src` declares Apache-2.0. Hex needs the text; add it.
- `{links, []}` in `mailio.app.src` is empty: give the repository URL.
- The version is still `0.1.0`. Bumping it and writing the release section of the CHANGELOG is the release step and was not done.
- Maintainers are not listed in the package metadata.

Remaining questions, not blocking:

1. Should the two permission models (`mailio_grant` and `mailio_mcp_authz`) converge? Not now, per decision 1.
2. Should `mailio_events` and `mailio_registry` move to the store? They are now documented as store support.
3. Is `mailio_barrel_spike_SUITE` a guard or a record?
4. Is JMAP still the next adapter, and on which contract (store or MCP)?

## Suggested order

1. Answer questions 1, 5 and 7.
2. Rewrite `README.md` and write `docs/concepts.md` (the front door and the vocabulary).
3. Write `docs/architecture.md` and `docs/map.md` (needs question 1).
4. Add `apps/mailio/doc/overview.md`, `apps/mailio_store/doc/overview.md` and `docs/limits.md`.
5. Add the five guides.
6. Small fixes: module doc for `mailio_mcp_sup`, cross links, comment on `catalog`, N3 and N5, re-measure `capabilities.md`.
7. Only then consider M1 to M4 and N1, N2 as separate code changes, one pull request each, after the documentation says what the boundaries are.

## Where this plan lives

This file, on branch `docs-review-2026-11-24`. The next run of the review should update it instead of starting over.

## Update after the second review of `mailio` (November 2026)

A second review of the library found problems in resource use, IMAP liveness, sync correctness and generated mail. They were fixed in one pull request, in six steps; the CHANGELOG lists what changed for users. What it means for this plan:

- Dialyzer is at zero warnings, so the "accepted warnings" in the validation matrix above no longer apply, and `AGENTS.md` says a change must not add one.
- The overview now has a section on sharing one IMAP connection and a table of the limits and timeouts, and `usage.md` and the overview say that `tls` defaults to `starttls`.
- The registry and event tables are written only by their owners, and a long-lived IMAP connection has a child specification for a supervisor.
- The release items above are unchanged: license text, repository link, maintainers and the version bump are still the maintainer's step, and the release waits for the documentation review of the merged `main`.

## Update for `main` at `22e5dea`, 2026-11-26

This is the plan for the release that follows the second review of `mailio` (pull requests 1 and 2). No source code was changed. The release (version bumps, CHANGELOG release sections, Hex publish) waits until you have said which of the findings below must be fixed first.

### What changed since the plan above

Source is now 19,541 lines (was 16,650), tests and fakes 15,675 (was 9,262). Most of the growth is correctness and hardening work in three modules. The CHANGELOG `Unreleased` section is 302 lines and mixes the first and second review, which is too long to be release notes as it stands.

Done since the first plan: the library overview, limits table, usage guide, `docs/architecture.md`, ExDoc setup, the license and the repository link. Package metadata is not complete: maintainers are still missing. Dialyzer is at zero warnings and CI enforces it. Still open: the top-level reading path, `docs/map.md`, the guides, and the release items (maintainers, version bumps).

### Measurements

| Module | Lines | Clause heads | What it holds now |
|---|---|---|---|
| `mailio_mcp_imap` | 1,218 | ~85 | unchanged shape: IMAP access, change detection and snapshot for the MCP tools |
| `mailio_imap` | 1,023 | ~89 | adapter: listing windows, QRESYNC and plain reads, mutations, expunge rules, mailbox sessions |
| `mailio_sync_mgr` | 963 | ~88 | account process: connection, incremental sync, full resync, reconcile, cursor and reset marker, IDLE watch |
| `mailio_account_writer` | 960 | ~82 | ingest, flags, patch, removal, UID mappings, counters, repair marks |
| `mailio_imap_conn` | 932 | ~108 | connection state machine: handshake, negotiation, commands, IDLE, reconnect |
| `mailio_imap_proto` | 892 | | wire format |

New small modules with one job each: `mailio_imap_lock` (turns on one connection), `mailio_uid_set` (UIDs as ranges), `mailio_sync_pages` (walking paged reads), `mailio_credentials` (resolving a credential chain).

### Findings

| # | Module | Primary problem | Why it is hard to read | What would help |
|---|---|---|---|---|
| D1 | `mailio_account_writer` | module organisation | Four jobs in one file: storing mail, UID mappings with a legacy namespace, counters, and the repair-mark protocol. The repair protocol (marks, the tracked set, recount) is a design that is explained nowhere except in comments | Document the counter protocol first. A split into a counters module is likely to help; it touches `mailio_sync_SUITE`, `mailio_fsck` and `mailio_account_writer` only |
| D2 | `mailio_sync_mgr` | module organisation | The process, the full resync, the reconcile and the cursor handling share one file. A reader has to hold five concepts (cursor, reset marker, resync, replace, inventory check) to change one | Document the sync states as a table in `apps/mailio_store/doc/sync.md`. A split of the full resync is possible but is not urgent |
| D3 | `mailio_imap` | code complexity | Listing windows, the two read paths and the mutations are interleaved; `list_windows` has a cost model that is only in comments | A diagram of one read and a "change the listing" guide |
| D4 | `mailio_mcp_imap` | architecture | The module is large because the MCP product keeps its own bounded snapshot of a mailbox. The duplication with the store's IMAP code is deliberate: the two products have different storage and boundedness requirements (the store keeps every message durably, the MCP server keeps a capped snapshot and reads on demand) | Document why the two exist side by side in `docs/architecture.md`; no merge is planned |
| D5 | docs | documentation | Decisions that were made in the review are only in commit messages and the CHANGELOG: sessions on a shared connection, QRESYNC enabled on every login, UIDVALIDITY checked on full reads, expunge refused without UIDPLUS, credentials kept by name for supervised connections | One page, "Design decisions of the IMAP adapter", with the reason for each and the test that holds it |
| D6 | CHANGELOG | documentation | The `Unreleased` section lists every fix of the two reviews as separate entries (302 lines) | Group by what a user sees before the release section is written; this is the maintainer's release step |
| D7 | tests | navigation | 48 test modules, no map from a behaviour to the test that holds it. The scripted servers in `test_support` and in `mailio_imap_session_tests` are the real specification of several rules | Add the behaviour to test table to `docs/map.md` |

### New concepts that need a page

The counter repair marks; the mailbox generation (UIDVALIDITY) as part of every full read; the UID mapping namespaces and the old form; credentials by name for a supervised connection; the connection lock and when a caller waits. Each is one short page in task style: what it is, when you meet it, how to change it, which test holds it.

### Decisions recorded by the maintainer

- **Release gates.** D5 and D6 must be done before the release. D1 to D4 and D7 can wait; document before refactoring D1 to D4. D5 carries its own behaviour to test mappings, the complete map (D7) can wait. Maintainers, version bumps and the package build remain gates. Only `mailio` is published to Hex for this release.
- **Counters.** Keep incrementally maintained counters with durable repair marks. Deriving them on read would make a mailbox read scan the emails. D1 documents these invariants first: mark every mailbox before changing an email or counter that affects it; clear the mark only after the counter is consistent; keep and reload marks across writer restarts; repair all outstanding marks before the next mutation; a failed repair read or write is an error. A split of the writer waits for that document.
- **`mailio_imap_lock`** is an internal detail. The supported feature is safe shared use through `mailio_imap`. A raw `mailio_imap_conn` has one owner.
- **Supervised connections** (`child_spec/1`, `register_ref/2`, `forget_ref/1`) are a documented, supported feature. Child arguments hold only a reference or a zero-argument token function.
- **Products.** `mailio_store` and `mailio_mcp` are sibling products with separate permission models. This settles the first plan's question 1.
- **Location of `mailio_events` and `mailio_registry`.** They stay in `mailio` for this release, documented as internal store support. Their location is reconsidered before `mailio_store` is published.
- **`mailio_barrel_spike_SUITE`** stays as a dependency-contract test; rename it later to something like `mailio_docdb_contract_SUITE`.
- **JMAP** is the next optional MCP adapter. Reusable JMAP protocol code goes in `mailio`, the tool-facing integration through `mailio_mcp_adapter`. A store-facing JMAP sync adapter is separate, later work.

### Suggested order

1. Done with this update: D5 (`apps/mailio/doc/design-decisions.md`) and D6 (grouped release notes in the CHANGELOG), with maintainers, version bumps and the package build.
2. Then D1 (the counter protocol page), D2, D3, D7 and the reading path (`README.md`, `docs/concepts.md`, `docs/map.md`).
3. Refactors of D1 to D3 only after their pages exist.
