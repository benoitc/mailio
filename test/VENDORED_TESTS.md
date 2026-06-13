# Test corpus provenance

Mailio's MIME/RFC 5322 stack is verified three ways:

1. **Unit tests** (`*_tests.erl`) — focused assertions per module.
2. **Property / fuzz tests** (`mailio_mime_prop_SUITE`) — seeded-PRNG round-trip
   (`render |> parse`), decoder inverses, and totality on random bytes and on
   mutated real messages. These caught two real non-UTF-8 crash bugs during M2.
3. **Corpus tests** (`mailio_mime_corpus_SUITE`) — real `.eml` fixtures under
   `mailio_mime_corpus_SUITE_data/` exercising the hard scenarios the
   established implementations regression test.

## Authored fixtures (current)

The fixtures in `mailio_mime_corpus_SUITE_data/` are **Mailio-original**, written
to reproduce the specific failure modes the reference libraries are known to
cover. They are not copied from those projects.

| Fixture | Scenario | Modeled on |
|---|---|---|
| `rfc2047_subject.eml` | adjacent multi-charset encoded-words, encoded display name | RFC 2047 §8 examples |
| `nested_torture.eml` | multipart/mixed > {alternative, message/rfc822, base64 attachment} | MimeKit / Mark Crispin torture test structure |
| `cp1252_qp.eml` | windows-1252 + quoted-printable, smart quotes / euro / en-dash | CPython `email` charset regressions |
| `rfc2231_filename.eml` | RFC 2231 split + extended (charset'') filename | gen_smtp `mimemail` + CPython `test_email` |
| `base64_wrapped.eml` | 76-column-wrapped base64 body | RFC 2045 §6.8 |

## External corpora to vendor (when network access is available)

These are spec-correct reference suites whose vectors should be imported to
broaden coverage. Each is license-compatible for inclusion with attribution.
Drop the data files under `mailio_mime_corpus_SUITE_data/<source>/` and add
cases that assert against them; keep this table updated.

| Source | License | What to take | Where |
|---|---|---|---|
| gen_smtp | BSD-2-Clause | `test/` `mimemail` encode/decode vectors; SMTP dialogue transcripts (for M9) | github.com/gen-smtp/gen_smtp |
| CPython `email` | PSF | `Lib/test/test_email/data/msg_*.eml` malformed-mail regression set | github.com/python/cpython |
| MimeKit | MIT | `UnitTests/TestData/` incl. the Mark Crispin "torture test" messages | github.com/jstedfast/MimeKit |
| RFC 8621 examples | IETF (RFC text) | Email/Mailbox/Thread JSON examples (for the JMAP layer, M11) | rfc-editor.org/rfc/rfc8621 |

When importing, preserve each project's copyright/license header in a sibling
`LICENSE` file within its subdirectory.
