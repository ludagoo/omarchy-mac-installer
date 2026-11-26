#!/bin/bash
# run-install.sh plans and installs with a stubbed diskutil, scutil, and engine.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
src=$here/../run-install.sh
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }

mkdir -p "$t/bin" "$t/image" "$t/engine"
sha=$(printf 'a%.0s' {1..64})
printf '%s\n' "$sha" >"$t/image/SHA256"
printf 'zip\n' >"$t/image/smartroom-firmware-test-os-package.zip"
printf '{}\n' >"$t/image/installer_data.json"
printf '#!/bin/bash\nexit 0\n' >"$t/engine/engine-install"
chmod +x "$t/engine/engine-install"

cat >"$t/bin/diskutil" <<'EOF'
#!/bin/bash
if [ "$1" = "info" ] && [ "$2" = "/" ]; then
  echo "   APFS Physical Store: disk0s2"
  exit 0
fi
echo "unexpected diskutil $*" >&2
exit 1
EOF
cat >"$t/bin/scutil" <<'EOF'
#!/bin/bash
echo "    kCGSSessionUserNameKey : consoleuser"
EOF
cat >"$t/bin/engine-install" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$t/engine-args"
exit 0
EOF
chmod +x "$t/bin/diskutil" "$t/bin/scutil" "$t/bin/engine-install"

export PATH="$t/bin:$PATH"
export SMARTROOM_RUN_INSTALL_NOSUDO=1

bash "$src" --help >/dev/null || fail "help"

out=$(bash "$src" plan --image-dir "$t/image" --engine "$t/bin/engine-install" --dry-run)
printf '%s\n' "$out" | grep -q 'dry-run: owner=consoleuser' || fail "dry-run owner"
printf '%s\n' "$out" | grep -q 'dry-run: source=disk0s2' || fail "dry-run source"
printf '%s\n' "$out" | grep -q 'dry-run: mode=plan' || fail "dry-run mode"
printf '%s\n' "$out" | grep -q -- '--yes' && fail "plan dry-run passed --yes" || true
printf '%s\n' "$out" | grep -q 'dry-run: no changes' || fail "dry-run trailer"
[ ! -f "$t/engine-args" ] || fail "dry-run ran the engine"

bash "$src" plan --image-dir "$t/image" --engine "$t/bin/engine-install"
grep -q -- '--owner' "$t/engine-args" || fail "plan missing owner"
grep -q -- '--source' "$t/engine-args" || fail "plan missing source"
grep -q 'consoleuser' "$t/engine-args" || fail "plan owner"
grep -q 'disk0s2' "$t/engine-args" || fail "plan source"
grep -q -- '--yes' "$t/engine-args" && fail "plan passed --yes" || true

: >"$t/engine-args"
bash "$src" install --image-dir "$t/image" --engine "$t/bin/engine-install" --owner room-owner
grep -q 'room-owner' "$t/engine-args" || fail "install owner argument"
grep -q 'consoleuser' "$t/engine-args" && fail "install kept the console user" || true
grep -q -- '--yes' "$t/engine-args" || fail "install missing --yes"

if bash "$src" plan --owner 'room owner' --image-dir "$t/image" --engine "$t/bin/engine-install" >/dev/null 2>"$t/err"; then
  fail "spaced owner was accepted"
fi
grep -q 'spaces' "$t/err" || fail "spaced owner message"

if grep -E -q 'zoomclassroom|goossen|moody' "$src"; then
  fail "launcher contains a site value"
fi

echo "ok - run-install"
