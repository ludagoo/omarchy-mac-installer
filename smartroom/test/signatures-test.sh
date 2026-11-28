#!/bin/bash
# Signatures required everywhere: no pacman
# configuration the builder or the SmartRoom tools write accepts a package
# without a trusted signature. Only databases may be unsigned where their
# publisher signs none (DatabaseOptional); the build pins those by sha256.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
builder=$repo/image-builder/bin/build-mac-image
bad() { echo "FAIL signatures: $*" >&2; exit 1; }
found=$(cd "$repo" && grep -rnE '(SigLevel|LocalFileSigLevel|RemoteFileSigLevel) = [^\\]*' image-builder/bin image-builder/builder smartroom \
  --exclude-dir=test --exclude-dir=docs 2>/dev/null |
  grep -E '(Never|TrustAll|[^e]Optional|PackageOptional|PackageNever|PackageTrustAll)' || true)
[[ -z $found ]] || bad "a configuration accepts packages without a trusted signature:"$'\n'"$found"
! grep -q 'LocalFileSigLevel = Never' "$builder" || bad "the build installs no local file unsigned"
toolchain=$(sed -n '/^prepare_toolchain()/,/^}/p' "$builder")
grep -q '"$(field asahi_alarm_server)/$ASAHI_KEYRING_FILE.sig"' <<<"$toolchain" || bad "the Asahi keyring's signature is fetched"
grep -q 'trust_key "$work/asahi-alarm.gpg" "$ASAHI_KEY"' <<<"$toolchain" || bad "the Asahi key is trusted by fingerprint"
grep -q '\[\[ $(sha256_of "$work/$ASAHI_KEYRING_FILE") == "$ASAHI_KEYRING_SHA256" \]\]' <<<"$toolchain" || bad "the Asahi keyring stays pinned"
installed=$(sed -n '/^write_installed_config()/,/^}/p' "$builder")
grep -q 'release_repo.py" require-signatures' <<<"$installed" || bad "a SmartRoom dev image requires every package signature"
echo "ok - no builder or SmartRoom pacman configuration accepts an unsigned or untrusted package"
