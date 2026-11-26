#!/bin/bash
# grant-access.sh with a stub ssh. It must not contact a real host.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
src=$here/../grant-access.sh
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }

printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyNotReal smartroom-test' >"$t/key.pub"
cat >"$t/ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$t/ssh-args"
exit 0
EOF
chmod +x "$t/ssh"

bash "$src" --help >/dev/null || fail "help"

out=$(bash "$src" --host room-101.example --key-file "$t/key.pub" --sudoers-name zz-example --dry-run)
printf '%s\n' "$out" | grep -q 'dry-run: action=grant' || fail "dry-run grant"
printf '%s\n' "$out" | grep -q 'dry-run: host=room-101.example' || fail "dry-run host"
printf '%s\n' "$out" | grep -q 'dry-run: sudoers=zz-example' || fail "dry-run sudoers"
printf '%s\n' "$out" | grep -q 'dry-run: no changes' || fail "dry-run trailer"
[ ! -f "$t/ssh-args" ] || fail "dry-run ran ssh"

bash "$src" --host room-101.example --key-file "$t/key.pub" --sudoers-name zz-example --ssh "$t/ssh" </dev/null
grep -q 'zz-example' "$t/ssh-args" || fail "grant script names the sudoers file"
grep -q 'authorized_keys' "$t/ssh-args" || fail "grant script edits authorized_keys"
grep -q 'NOPASSWD' "$t/ssh-args" || fail "grant script writes NOPASSWD"
grep -q 'TestKeyOnlyNotReal' "$t/ssh-args" || fail "grant script includes the public key"
grep -q 'visudo' "$t/ssh-args" || fail "grant script checks sudoers"
grep -q 'room-101.example' "$t/ssh-args" || fail "ssh host"

: >"$t/ssh-args"
out=$(bash "$src" --revoke --host room-101.example --key-file "$t/key.pub" --sudoers-name zz-example --dry-run)
printf '%s\n' "$out" | grep -q 'dry-run: action=revoke' || fail "dry-run revoke"

bash "$src" --revoke --host room-101.example --key-file "$t/key.pub" --sudoers-name zz-example --ssh "$t/ssh" </dev/null
grep -q 'rm -f' "$t/ssh-args" || fail "revoke removes the sudoers file"
grep -q 'grep -v' "$t/ssh-args" || fail "revoke removes the key line"
grep -q 'NOPASSWD' "$t/ssh-args" && fail "revoke still writes NOPASSWD" || true
grep -q 'zz-example' "$t/ssh-args" || fail "revoke names the sudoers file"

if grep -q 'KpWU9xg' "$src"; then
  fail "grant script embeds the site public key"
fi

echo "ok - grant-access"
