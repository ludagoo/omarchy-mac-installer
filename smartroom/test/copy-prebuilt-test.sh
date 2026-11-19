#!/bin/bash
# smartroom/copy-prebuilt: copies and signs only what the pin file names, and
# only when every pin matches. Offline, a throwaway gpg home.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=$here/../copy-prebuilt
t=$(mktemp -d)
trap 'gpgconf --homedir "$t/gnupg" --kill all 2>/dev/null || true; rm -rf "$t"' EXIT
export GNUPGHOME=$t/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'copy-prebuilt test <test@invalid>' ed25519 sign never 2>/dev/null
key=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
fail=0
ok() { echo "ok - $*"; }
bad() { echo "not ok - $*"; fail=1; }
mkdir "$t/src" "$t/dest"
printf 'browser\n' >"$t/src/browser-1-1-aarch64.pkg.tar.xz"
printf 'other\n' >"$t/src/other-1-1-aarch64.pkg.tar.xz"
sum=$(sha256sum "$t/src/browser-1-1-aarch64.pkg.tar.xz" | cut -d' ' -f1)
printf '# comment\n\n%s  browser-1-1-aarch64.pkg.tar.xz\n' "$sum" >"$t/pins"

if "$tool" "$t/pins" "$t/src" "$t/dest" "$key" >/dev/null 2>&1 &&
  cmp -s "$t/src/browser-1-1-aarch64.pkg.tar.xz" "$t/dest/browser-1-1-aarch64.pkg.tar.xz" &&
  gpg --batch --verify "$t/dest/browser-1-1-aarch64.pkg.tar.xz.sig" "$t/dest/browser-1-1-aarch64.pkg.tar.xz" 2>/dev/null; then
  ok "a matching pin is copied and signed"
else
  bad "a matching pin is copied and signed"
fi
[[ ! -e $t/dest/other-1-1-aarch64.pkg.tar.xz ]] && ok "an unpinned file is not copied" || bad "an unpinned file is not copied"

rm -rf "$t/dest"/*
printf 'tampered\n' >"$t/src/browser-1-1-aarch64.pkg.tar.xz"
if ! "$tool" "$t/pins" "$t/src" "$t/dest" "$key" >/dev/null 2>&1 && [[ -z $(ls -A "$t/dest") ]]; then
  ok "a file that does not match its pin stops the copy"
else
  bad "a file that does not match its pin stops the copy"
fi

rm -f "$t/src/browser-1-1-aarch64.pkg.tar.xz"
if ! "$tool" "$t/pins" "$t/src" "$t/dest" "$key" >/dev/null 2>&1; then
  ok "a missing pinned file stops the copy"
else
  bad "a missing pinned file stops the copy"
fi

printf '%s  ../browser-1-1-aarch64.pkg.tar.xz\n' "$sum" >"$t/pins-path"
if ! "$tool" "$t/pins-path" "$t/src" "$t/dest" "$key" >/dev/null 2>&1; then
  ok "a pin naming a path is refused"
else
  bad "a pin naming a path is refused"
fi

printf '# nothing pinned\n' >"$t/pins-empty"
if "$tool" "$t/pins-empty" "$t/src" "$t/dest" "$key" >/dev/null 2>&1 && [[ -z $(ls -A "$t/dest") ]]; then
  ok "an empty pin file copies nothing"
else
  bad "an empty pin file copies nothing"
fi
exit $fail
