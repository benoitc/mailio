---
name: protocol-change-review
description: Run the three required checks (compliance, latest specification, safety) on a mailio change, commit or pull request that touches how an IMAP, POP3 or SMTP server is spoken to, how messages, headers or MIME are parsed or built, TLS and authentication, or how a send or a change check is recorded. Use before committing, before opening or merging a PR, when reviewing a contributor PR, and when asked whether code follows a spec or is safe against a hostile server.
---

# Protocol change review

mailio reads bytes from servers and senders it does not control. A change is
done when it matches the spec, the spec is the current one, and a hostile server
or sender cannot use it. Run the three checks below on each commit; a PR with
several commits gets one verdict per commit. The spec list is in
[AGENTS.md](../../../AGENTS.md#specifications).

## 1. Compliance

Follow the [rfc-compliance](../rfc-compliance/SKILL.md) skill: fetch the spec
text, check every quoted sentence and the section around it, the requirement
level, the reply and the action, and every path that reaches the code.

Then check the test fails without the change. Use a worktree at the merge base,
not `git stash`:

```bash
git worktree add ../mailio_base main
cp apps/mailio/test/mailio_x_tests.erl ../mailio_base/apps/mailio/test/
cd ../mailio_base && rebar3 eunit --module=mailio_x_tests
```

Suites to run (commands in [AGENTS.md](../../../AGENTS.md#required-checks)):
`rebar3 eunit`, both Common Test directories, and the suites against real
servers that the change touches: GreenMail (`mailio_mcp_e2e_SUITE`), Mailpit
(`mailio_smtp_mailpit_SUITE`) and Dovecot (`mailio_mcp_imap_dovecot_SUITE`).
A change to the IMAP client needs the Dovecot suite; one to the SMTP client needs
Mailpit.

## 2. Latest specification

1. Name the governing document and confirm it is current on
   https://www.rfc-editor.org/rfc/rfcNNNN.json (`obsoleted_by`, `updated_by`).
   Known replacements: RFC 3501 to RFC 9051 (IMAP4rev2, not yet followed, see
   Pending updates), RFC 8446 to RFC 9846, RFC 6125 to RFC 9525.
2. Check for errata on https://www.rfc-editor.org/errata/rfcNNNN.
3. Write the version and the date checked in the PR description.
4. If the latest text disagrees with the code, fix it in the change or say it is
   out of scope and add it under "Pending updates" in AGENTS.md. Moving to a new
   version follows "Keeping the specifications current" there.

## 3. Safety

Walk the classes that apply and state which you checked.

- **Resource exhaustion by a server**: every size a server controls is bounded
  while it is read, not after: an IMAP literal and a response line, the lines of
  a POP3 or SMTP reply, the size of a retrieved message against the size the
  server announced, the nesting and the number of MIME parts, the size of a
  decoded attachment, and anything held in a cache or an index. A server must
  not be able to grow any of them without a bound set by the spec or an option.
- **Trusting the server's claims**: a size, a count or a UID taken from a reply
  is checked before it is used. A UIDVALIDITY change drops what depended on the
  old one.
- **Downgrade and interception**: certificates and host names are verified by
  default; STARTTLS is required when asked for and never silently skipped; no
  credential is sent before TLS is up; a refused upgrade is an error, not a
  fall back to clear text.
- **Credential and content leaks**: no password, token or message content in a
  log line or an error term. Secrets stay references.
- **Hostile mail**: a header, an address or a filename never reaches a file path,
  a command or a log unchecked; a filename is a label, not a path. Decoders are
  total on random bytes (property tests).
- **Retry and duplication**: a retry never repeats something that may already
  have happened. A send whose reply was lost is `outcome_unknown`; a failure
  before the body was sent is retryable.
- **Reading must not change the mailbox**: read-only open and `BODY.PEEK`.

Never weaken a limit to let a legitimate server pass; exclude that case
precisely. A regression test for an attack drives a scripted server (see
`mailio_fake_imap`, `mailio_fake_pop3`, `mailio_fake_smtp`) or the decoder, and
asserts the bound or the error.

A finding from this check is a bug when its fix is to follow the spec or to add
a missing bound, even if it is a memory or crash vector: public PR, CHANGELOG
under Fixed, no advisory, no CVE, no attack description. Credential handling and
certificate checks stay security issues. See "Specification issues are bugs, not
security issues" in AGENTS.md, and "Known gaps in the safety check" for what is
already known to be open.

## Report

One block per commit, in the PR description or the hand-off:

```
<sha> <subject>
  spec: RFC 5321 §4.5.2 MUST, quote verified | not found | paraphrased
  latest: RFC 5321 current (checked 2026-11-24)
  verdict: compliant | partial (<missing>) | wrong (<why>) | not a spec item
  test: fails before, passes after | does not discriminate | missing
  servers: suites run against GreenMail, Mailpit, Dovecot, and the result
  safety: <classes checked>, <bounds>, no new unbounded state
```

Then list what needs the maintainer's decision: a SHOULD left out, a deliberate
deviation, a spec update that is out of scope.
