# Security

This page says what to report privately and what to report as a normal bug.

## Report privately

Contact the maintainer directly, not in a public issue, when you find:

- a password, token or message reaching someone it should not (a log, an error
  message, another account, another caller);
- a server accepted without the certificate or host name check the configuration
  asks for, or a credential sent before TLS was up when TLS was required;
- TLS used at a lower level than the configuration allows;
- a way to run code, or to make mailio read or write a file it should not.

Give the version, what you did, and what happened. A short report is enough.

## Report as a normal bug

When the fix is to make mailio do what a specification it implements says, it is
a bug, not a security issue. That includes input handled differently from the
spec, a wrong error or state, and a missing bound, even when it can be used to
exhaust memory or crash a connection. File it in public with the section number;
see [CONTRIBUTING.md](CONTRIBUTING.md#security-issues-and-specification-bugs).

If you are not sure which it is, ask the maintainer privately.
