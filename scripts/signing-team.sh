#!/usr/bin/env bash
# Prints the team of the keychain's "Apple Development" identity, when there is exactly one valid one, for the
# installed copy's stable signature (ADR 0008). Prints nothing otherwise: anyone else, and CI, build ad-hoc.
set -euo pipefail

identities=$(security find-identity -v -p codesigning | grep '"Apple Development:' || true)
[ "$(printf '%s' "$identities" | grep -c .)" = 1 ] || exit 0
hash=$(printf '%s' "$identities" | awk '{print $2}')

# The certificate of that identity: an expired one may share its name.
security find-certificate -a -Z -p -c "Apple Development" |
	awk -v hash="$hash" '/^SHA-1 hash:/ { wanted = ($3 == hash); next } wanted { print }' |
	openssl x509 -noout -subject |
	sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p'
