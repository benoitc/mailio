# Contributing

This page is for people changing mailio itself. For what each app is, read the
[README](README.md). Agents read [AGENTS.md](AGENTS.md) as well.

## Write for the person who reads it

Every issue, pull request and comment is read by a person. Make it easy for
them.

- Read what you send before you send it. You are responsible for every line,
  whether you wrote it or a tool did.
- Use plain English and short sentences. Say what happens, what you expected,
  and how to reproduce it. Explain any term a reader may not know.
- Don't inflate it. No buzzwords, no severity scores, CVSS or CWE labels, no
  "critical" for a bug, no long generated write-ups.
- A bug report gives: the OTP version, the app, the server (and its version, if
  you know it), the account settings that matter (TLS mode, authentication
  mechanism), a minimal reproduction, what you got and what you expected. For a
  protocol problem, the conversation with the server helps most, with the
  password removed.
- A pull request says what was wrong and why it matters, the fix in a few lines,
  and any breaking change. Link the issue. Don't walk through the diff file by
  file; the reviewer reads the code.
- A fix comes with a test that fails without it.

AI tools are fine to use. Before you open anything, you must have read the
change, run the tests, and be able to answer questions about it yourself.

## Security issues and specification bugs

mailio implements the mail protocols and formats listed in
[AGENTS.md](AGENTS.md#specifications). When the fix is to make mailio do what one
of them says, it is a bug, not a security issue, even when it is described as a
denial of service or a crash. That includes:

- input accepted, rejected or framed differently from the specification;
- a wrong reply handling, error, or state transition;
- a missing bound that the specification or an option defines.

Report these as a normal bug, in public, and cite the section. The fix goes in a
public pull request and in the CHANGELOG under Fixed. No advisory and no CVE.

Only problems that are not a specification deviation go through
[SECURITY.md](SECURITY.md): a credential or message reaching someone it should
not, a server accepted without the certificate or host name check the
configuration asks for, TLS weakened below what was asked for, or code
execution.

## Keeping the specifications current

The specifications mailio follows, and the version of each, are listed in
[AGENTS.md](AGENTS.md#specifications), with the newer versions not yet followed
under Pending updates. The list is checked before every release and when a
module it names changes. Moving to a new RFC or revision is its own pull
request. If you notice a spec has a newer version, open an issue naming it.

## Set up

You need Erlang/OTP 28 or later and rebar3.

```bash
git clone <the repository>
cd mailio
rebar3 compile
```

The store tests build RocksDB through `barrel_docdb`, which needs CMake and a C++
compiler; the first build takes a while.

The tests that talk to a real mail server need Docker. Start the ones you need:

| Server | What it is for | Start it |
|---|---|---|
| GreenMail | IMAP, POP3 and SMTP for the end-to-end MCP tests | `(cd apps/mailio_mcp/test && docker compose up -d)` |
| Mailpit | the SMTP client against a real server | `apps/mailio/test/mailpit/gen-certs.sh`, then `(cd apps/mailio/test/mailpit && docker compose up -d)` |
| Dovecot | the IMAP adapter: QRESYNC, IDLE, STARTTLS, implicit TLS | `(cd apps/mailio_mcp/test/dovecot && docker compose up -d --build)` |

A suite that needs a server skips itself when the server is not running, so a
missing server looks like a skip, not a failure. Look at the totals.

## Before you commit

There is no CI yet: run the checks yourself.

```bash
rebar3 fmt          # format first (run it twice if it changed a file)
rebar3 compile
rebar3 eunit
rebar3 fmt --check
rebar3 lint
rebar3 xref
rebar3 dialyzer     # 5 known warnings in older code; add none
rebar3 ct --dir apps/mailio/test
rebar3 ct --dir apps/mailio_store/test
```

Then the suites against real servers that your change touches (see AGENTS.md).

## Tests

- `apps/*/test/*_tests.erl` are EUnit tests, run by `rebar3 eunit`.
- `apps/*/test/*_SUITE.erl` are Common Test suites; run one with
  `rebar3 ct --suite apps/mailio/test/mailio_smtp_mailpit_SUITE`.
- `test_support/` holds scripted servers (`mailio_fake_imap`, `mailio_fake_pop3`,
  `mailio_fake_smtp`) that every app's tests can use. A scripted server proves
  what its author assumed; the real servers above prove what the world does.
  Several bugs in this repository were found only by the real servers.
- A test that talks to a local port must use a port nothing else uses. Port 1025
  is the default of several mail bridges, so Mailpit listens on 11025.
- A test must fail for one reason. A test that also passes when the call crashes,
  or that asserts a value it computed itself, is worse than no test.

## Interoperability tests

`apps/mailio/test/mailio_interop_SUITE.erl` runs the library's IMAP, POP3 and SMTP clients and the MIME code against real servers, with no MCP server or store involved. You run it when you change anything that reads or writes bytes for a server, or the MIME code. A server that is not running is skipped with one message.

| Server | Gives you | Start it |
|---|---|---|
| Dovecot | IMAP and POP3, STARTTLS and implicit TLS, QRESYNC | `apps/mailio/test/mailpit/gen-certs.sh`, then `(cd apps/mailio_mcp/test/dovecot && docker compose up -d --build)` |
| GreenMail | IMAP, POP3 and SMTP that delivers to the mailbox, implicit TLS | `(cd apps/mailio_mcp/test && docker compose up -d)` |
| Stalwart | A server written independently of the other two: IMAP4rev2 and rev1 that refuses a login before STARTTLS, POP3 with STLS, SMTP submission | `apps/mailio/test/stalwart/setup.sh` (recreates and provisions it) |

```bash
rebar3 ct --suite apps/mailio/test/mailio_interop_SUITE
rebar3 ct --suite apps/mailio_store/test/mailio_store_interop_SUITE
```

The second suite is the store syncing from the same servers: backfill of real messages (UTF-8 subject, an attachment), a second pass that must report nothing, flag changes, removals (by QRESYNC and by a reconcile pass), and an IDLE push. The server profiles live in `test_support/mailio_servers.erl`.

Each case takes a server profile (ports, user, how its certificate is verified), so a new server is one more profile and one more group, not new cases. The suite covers: a message surviving render, SMTP, delivery, IMAP or POP3 and parse unchanged (UTF-8, a 300 KB attachment, a line that starts with a dot); reading never marking mail as seen; wrong passwords not being retried; IDLE waking for new mail; TLS being verified and an untrusted certificate refused; the size limits holding against a server that is not ours; and the sync adapter reporting new mail, changed flags and expunges the way each server's extensions allow.

## Documentation

Write guides in the task-oriented style the existing ones use: one paragraph
saying what the page is and when you need it, then the steps with short notes
between code blocks. Keep `apps/mailio_mcp/doc/capabilities.md` in step with the
code: a feature is "tested" only when a test in the repository runs it.

## Pull requests

Branch from `main` using the prefix that fits: `fix/`, `feat/`, `perf/`,
`refactor/`, `docs/`, `test/` or `chore/`.

Write the commit subject in the imperative, describing what the code now does
rather than what it used to do. Keep the body to short bullets. Do not add
generated-by or co-authored-by trailers.

A change to protocol code passes the three checks in
[AGENTS.md](AGENTS.md#first-principle-compliance-latest-spec-safety) before it is
opened.

Say what the change is for and how it works. Skip the test inventory and the test
plan. If the change touches the public API, show it in a short code block.

Sync a branch that has fallen behind by merging `main` into it, not by rebasing.

## Releases

A release is the maintainer's decision. Before one, check the specification list
and run a documentation review of the current `main`; the release waits for the
maintainer to say which findings must be fixed first.
