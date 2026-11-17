#!/bin/bash
# smartroom/recovery-branding (CARRY.md patch 4): the Recovery sources show
# SmartRoom Firmware, and the app check passes a SmartRoom build and refuses an
# Omarchy one, as a directory and inside an OS package ZIP. Linux, no Swift.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
src=$(cd -- "$here/../.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
tool=$src/smartroom/recovery-branding
contract=$(sed -n 's/^INSTALLER_RECOVERY_APP_NAME="\(.*\)"$/\1/p' "$src/Packaging/identity.conf")
[[ -n $contract ]] || fail "no INSTALLER_RECOVERY_APP_NAME in identity.conf"

out=$(python3 "$tool" source "$src") || fail "the Recovery sources: $out"
echo "ok - $out"

# A copy of the sources with one new user-visible literal fails, naming it.
mkdir -p "$t/repo/smartroom" "$t/repo/Packaging"
cp -R "$src/Recovery" "$t/repo/Recovery"
cp "$src/Packaging/identity.conf" "$t/repo/Packaging/"
cp "$tool" "$t/repo/smartroom/"
rm -rf "$t/repo/Recovery/.build"
printf '%s\n' 'let smartroomBrandingProbe = "Welcome to Omarchy"' >>"$t/repo/Recovery/Sources/InstallConfiguration.swift"
if out=$(python3 "$t/repo/smartroom/recovery-branding" source "$t/repo"); then fail "a new Omarchy literal passed"; fi
grep -q 'InstallConfiguration.swift:.*"Welcome to Omarchy"' <<<"$out" || fail "the finding does not name the literal: $out"
echo "ok - a new \"Omarchy\" literal in Recovery/Sources fails the source check"

# Built apps: a SmartRoom build passes; each Omarchy leftover fails.
make_app() { # DIR CFBundleName STRINGS-CFBundleName EXTRA-RUN...
  local dir=$1 name=$2 sname=$3; shift 3
  python3 - "$dir/$contract.app" "$contract" "$name" "$sname" "$@" <<'PY'
import plistlib, sys
from pathlib import Path
app, contract, name, sname, *extra = sys.argv[1:]
contents = Path(app, "Contents")
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources/en.lproj").mkdir(parents=True)
(contents / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "OmarchyRecovery", "CFBundleIdentifier": "org.aurorasilicon.omarchy.recovery.recovery",
    "OmarchyRecoveryBuildMode": "recovery", "OmarchyRecoveryDataLayout": "external-install-data-v1",
    "CFBundleName": name, "CFBundleDisplayName": contract}))
(contents / "Resources/en.lproj/InfoPlist.strings").write_text(
    f'"CFBundleDisplayName" = "{contract}";\n"CFBundleName" = "{sname}";\n')
runs = ["SmartRoom Firmware Installer", "Setting up SmartRoom Firmware", contract + ".app",
        "Aurora/Recovery/State", "\n# Aurora Recovery command\nexport PATH=\"$HOME/bin:$PATH\"\n",
        "_TtC15OmarchyRecovery15OmarchyWordmark", "$s15OmarchyRecovery12OmarchyThemeO",
        "private/var/db/omarchy-recovery-account/state.json", "_omarchy_account_command"] + extra
(contents / "MacOS/OmarchyRecovery").write_bytes(b"\xcf\xfa\xed\xfe\0\0" + b"\0\x01".join(r.encode() for r in runs) + b"\0")
(contents / "Resources/LICENSE").write_text("Copyright (c) David Heinemeier Hansson\n")
PY
}
B="SmartRoom Firmware Installer"
make_app "$t/good" "$B" "$B"
out=$(python3 "$tool" app "$t/good") || fail "a SmartRoom build: $out"
echo "ok - a SmartRoom build passes: $out"
(cd "$t/good" && mkdir -p esp/aurora/recovery && mv "$contract.app" esp/aurora/recovery/ &&
  python3 -c 'import shutil; shutil.make_archive("pkg", "zip", ".", "esp")')
out=$(python3 "$tool" app "$t/good/pkg.zip") || fail "a SmartRoom build in an OS package: $out"
echo "ok - the same build inside an OS package ZIP passes"

expect_fail() { # WHAT PATTERN DIR
  local out
  if out=$(python3 "$tool" app "$3"); then fail "$1 passed"; fi
  grep -q -- "$2" <<<"$out" || fail "$1: the finding does not say $2: $out"
  echo "ok - $1 fails"
}
make_app "$t/prompt" "$B" "$B" "Use your existing macOS owner’s password to set up Omarchy."
expect_fail "a prompt that sets up Omarchy" "set up Omarchy" "$t/prompt"
make_app "$t/menu" "$B" "$B" "Quit $contract"
expect_fail "a menu item that names the Omarchy app" "Quit $contract" "$t/menu"
make_app "$t/aurora" "$B" "$B" "Open Aurora Installer in Recovery"
expect_fail "an Aurora Installer sheet" "Aurora Installer" "$t/aurora"
make_app "$t/name" "$contract" "$B"
expect_fail "CFBundleName $contract" "CFBundleName is '$contract'" "$t/name"
make_app "$t/strings" "$B" "$contract"
expect_fail "a localized CFBundleName $contract" "InfoPlist.strings CFBundleName" "$t/strings"
make_app "$t/stock" "$B" "$B"
python3 - "$t/stock/$contract.app/Contents/MacOS/OmarchyRecovery" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); p.write_bytes(p.read_bytes().replace(b"SmartRoom Firmware Installer", b"x"))
PY
expect_fail "an executable without the SmartRoom names" "not the SmartRoom build" "$t/stock"
