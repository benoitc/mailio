---
name: rfc-compliance
description: Check a change, commit or pull request in mailio against the RFCs it claims to follow (IMAP RFC 3501 and 7162, POP3 RFC 1939, SMTP RFC 5321 and 6409, RFC 5322, MIME RFC 2045 to 2047 and 2231, JMAP RFC 8620 and 8621). Use when reviewing a PR, before merging a protocol fix, or when asked whether code complies with the spec.
---

# RFC compliance check

Use this to decide whether a change does what the spec says, no more and no
less. It applies to one commit at a time; a PR with several commits gets one
verdict per commit. The spec list is in [AGENTS.md](../../../AGENTS.md#specifications).

## 1. Get the spec text

Never quote an RFC from memory. Fetch the plain text once and grep it:

```bash
mkdir -p "$SCRATCH/rfc" && cd "$SCRATCH/rfc"
for r in 3501 7162 2177 1939 2449 2595 5321 6409 4954 3207 8314 5322 2045 2047 2231; do
  [ -f rfc$r.txt ] || curl -sfL https://www.rfc-editor.org/rfc/rfc$r.txt -o rfc$r.txt
done
grep -n "MUST NOT.*literal" rfc3501.txt
```

XOAUTH2 is not an RFC: it is defined in the Google and Microsoft documentation.
Name the page and the date you read it.

## 2. Check the claim

For each commit:

1. Find every RFC sentence the commit message or PR body quotes. Confirm it is
   verbatim and in the section cited.
2. Read the whole section around it, not only the sentence: exceptions,
   "unless", and the rule for the other side (client or server) are usually a
   paragraph away.
3. Note the requirement level: MUST and MUST NOT is a fix; SHOULD needs a reason
   not to; MAY is a choice, so the change must say why it is worth it.
4. Check the reply the code expects and the action it takes match the text:
   the status (`OK`, `NO`, `BAD`, `+OK`, `-ERR`, the SMTP code), the response
   code in brackets, and what happens next (retry, abort, carry on).
5. Check the code does what the text says on every path that reaches it:
   implicit TLS and STARTTLS and plain, each authentication mechanism, a
   server that does not advertise the extension, a reply split across lines or
   carrying a literal, and each state of the connection.
6. Check it does not go further than the spec. A new refusal where the RFC says
   "MAY" or "SHOULD" breaks real servers that are allowed to do it. Real mail is
   messy: a parser is lenient in what it accepts and strict in what it sends.

## 3. Check the test

- The test fails without the fix and passes with it. Run it both ways.
- It asserts the outcome the spec names (the error, the command sent, what was
  skipped), and cannot also pass on a crash or a missing result.
- Where a scripted server was used, say whether the behaviour was also seen on a
  real one (GreenMail, Dovecot, Mailpit). A scripted server only proves what its
  author assumed.

## 4. Report

One line per commit:

```
<sha> <subject>
  spec: RFC 7162 §3.2.5 MUST, quote verified | quote not found | paraphrased
  verdict: compliant | partial (<what is missing>) | wrong (<why>) | not a spec item (<what it is>)
  test: fails before, passes after | does not discriminate | missing
```

Then list anything that needs the maintainer's decision (a SHOULD left out, a
deliberate deviation).
