# ADR 0001: Project identity and initial distribution

- **Status:** Accepted
- **Date:** 2026-08-21

## Decision

- Product and repository working name: **Copyloom**.
- GitHub owner: `imrajyavardhan12`.
- Bundle identifier: `io.github.imrajyavardhan12.copyloom`.
- Minimum deployment target: macOS 14.
- Development and the first vertical slice do not depend on paid Apple Developer Program membership.
- Initial public posture is source-first: reproducible build instructions and unsigned CI validation.
- When funding permits, ship a sandboxed Developer ID-signed and notarized direct download first while retaining Mac App Store compatibility.
- Do not present unsigned/ad-hoc downloads that require Gatekeeper bypass as the normal end-user release.
- CloudKit and other paid-team capabilities remain deferred.

## Context

A paid Apple Developer Program membership is not currently available. Xcode 26.6 is installed and its first-launch setup is complete. Local development, local signing/ad-hoc execution, tests, benchmarks and unsigned CI do not require the paid program. Developer ID signing, notarization and Mac App Store distribution do.

The shell currently selects `/Library/Developer/CommandLineTools`; project commands can set:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Changing the machine-wide selection is optional:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## Consequences

- Keep the bundle identifier stable so local data paths and TCC permissions are not repeatedly reset.
- CI must never claim an unsigned artifact is a production release.
- Signing/notarization workflows can be added later without changing storage or application architecture.
- Features requiring paid-team entitlements must not enter the first vertical slice.
- Perform a fuller trademark/App Store name check before final public branding; the current name is an accepted working identity, not legal clearance.
