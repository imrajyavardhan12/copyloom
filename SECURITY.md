# Security Policy

Clipboard history can contain passwords, tokens, private keys, recovery codes and confidential material. Please do not disclose a suspected vulnerability in a public issue.

## Reporting

Use GitHub's private vulnerability reporting for this repository:

<https://github.com/imrajyavardhan12/copyloom/security/advisories/new>

Include only the minimum reproduction data. Never attach real secrets or a real clipboard database; use synthetic fixtures.

If private reporting is temporarily unavailable, open a public issue containing only the words “Security contact requested” and no vulnerability details. A maintainer will establish a private channel.

## Response goals

We aim to acknowledge a report within 7 days, assess severity and affected versions, coordinate a fix and credit the reporter if desired. These are goals for a volunteer project, not a paid SLA.

## Supported versions

Copyloom has not published a stable release. Security fixes currently target the `main` branch. This section will list supported release lines before the first public binary.

## Scope priorities

High-priority reports include:

- sensitive content persisted despite a deny policy;
- clipboard content sent over a network without explicit invocation;
- database/FTS/Vault boundary leakage;
- attachment path traversal or archive extraction traversal;
- unauthorized local MCP access when MCP exists;
- permission bypass, wrong-target paste or unsafe migration/data loss;
- supply-chain compromise in release artifacts.

General feature requests and ordinary crashes belong in public issues unless they expose private content.

See [THREAT_MODEL.md](THREAT_MODEL.md) for explicit non-goals and residual risks.
