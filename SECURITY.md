# Security Policy

## Supported Versions

Security fixes are applied to the latest minor release on the `main` branch.

| Version | Supported |
| ------- | --------- |
| 0.2.x   | yes       |
| < 0.2   | no        |

## What is a security issue

Private reports are for problems that are not a deviation from a
specification barrel_xet implements:

- code execution;
- a request served without the authentication or scope the configuration
  asks for (bearer tokens and their read, write and admin scopes, the admin
  endpoints, signed data URL signatures and expiry);
- secrets reaching someone else: tokens, the URL signing secret, S3
  credentials, or anything else from the configuration, including through
  logs, metrics or error responses;
- files or blobs outside the configured data directory or bucket being read,
  written or deleted, for example through a namespace or hash in a path;
- one tenant's data reaching another, once per-namespace access control is
  configured.

## What is a bug

When the fix is to make barrel_xet follow a specification it implements
(draft-denis-xet, the xet-core protocol extensions, and the HTTP semantics,
ranges and caching rules it cites), it is a bug, even when described as
denial of service, resource exhaustion or a remote crash. That includes a
wire format accepted or rejected differently from the draft, a missing size
limit the draft defines, or a hash the server should verify and does not.
Report it as a public bug and cite the specification section; see
[Security issues and specification bugs](CONTRIBUTING.md#security-issues-and-specification-bugs).
We don't publish advisories or request CVEs for these, and advisories filed
for them are closed as bugs with a link to the fix.

Write the report in plain English, with a minimal reproduction, as described
in [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it).

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through GitHub's
[Private Vulnerability Reporting](https://github.com/barrel-db/barrel_xet/security/advisories/new).

Do not open public issues or pull requests for security problems.

When reporting, include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- Affected versions and platform details (OTP version, storage backend).
- Any suggested fix or mitigation.

You can expect an initial acknowledgement within 7 days. We will work with
you on a fix and coordinate disclosure once a patched release is available.
Credit will be given in the advisory unless you prefer to remain anonymous.
