#!/bin/bash
# A SmartRoom release image (PROGRAM decision 4): build-mac-image's release
# steps against a scratch root. The installed pacman.conf names only
# [smartroom-release]; the release repository holds exactly the package
# record, each archive with its publisher's signature; the build host signs
# the database, PACKAGES and RELEASE (release_signer, a throwaway key here);
# the image keeps that signed database. The repository part needs repo-add
# (pacman) and is skipped without it.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
builder=$here/../../image-builder
# shellcheck source=../../image-builder/bin/build-mac-image
source "$builder/bin/build-mac-image"
s=$(mktemp -d)
export GNUPGHOME=$s/gnupg
mkdir -m 0700 "$GNUPGHOME"
signer=""
trap '[[ -z $signer ]] || kill "$signer" 2>/dev/null; gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$s"' EXIT
bad() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

profile=smartroom lane=edge
smartroom_dir=$s/smartroom work=$s/work repos=$s/repos target=$s/target logs=$s/logs
release_root=$s/out/release package_cache=$s/cache
MAC_IMAGE_BUILDER_COMMIT=0123456789abcdef0123456789abcdef01234567 MAC_IMAGE_BUILDER_IMAGE=sha256:test
MAC_IMAGE_HOST_UID=$(id -u) MAC_IMAGE_HOST_GID=$(id -g) RELEASE_SIGN_TIMEOUT=30
mkdir -p "$smartroom_dir" "$work" "$repos/smartroom" "$target/etc/pacman.d" "$target/var/lib/pacman/sync" "$logs" "$package_cache" "$s/out"
printf 'omarchy_channel=stable\n' >"$s/inputs"
field() { sed -n "s/^$1=//p" "$s/inputs"; }

gpg --batch --quiet --passphrase '' --quick-gen-key 'release test <release-test@invalid>' ed25519 sign never 2>/dev/null
key=$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
gpg --batch --armor --export "$key" >"$smartroom_dir/key.asc"
printf '%s\n' "$key" >"$smartroom_dir/key.fpr"
printf 'version=2026.11.20-studio-edge\nurl=https://releases.example/releases/2026.11.20-studio-edge\nchannel=dev\n' >"$smartroom_dir/release"

smartroom_release || bad "a release file makes a release image"
[[ $(release_dir) == "$release_root/2026.11.20-studio-edge" ]] || bad "the release directory is OUT/release/VERSION"

# ── the installed pacman.conf ─────────────────────────────────────────────
templates=$target/usr/share/omarchy/default/pacman/aarch64-apple
mkdir -p "$templates"
cat >"$templates/pacman-stable.conf" <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = aarch64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[omarchy]
Server = https://pkgs.omarchy.org/stable/$arch

[core]
Include = /etc/pacman.d/mirrorlist
EOF
printf 'Server = https://arm-stable-mirror.omarchy.org/$arch/$repo\n' >"$templates/mirrorlist-stable"
write_installed_config
[[ $(pacman_repositories "$target/etc/pacman.conf" | paste -sd' ' -) == smartroom-release ]] ||
  bad "a release image's pacman.conf names only [smartroom-release]"
grep -qx 'SigLevel = Required DatabaseRequired' "$target/etc/pacman.conf" &&
  grep -qx 'LocalFileSigLevel = Required' "$target/etc/pacman.conf" || bad "a release image requires every signature"
! grep -qE 'Optional|TrustAll|Never' "$target/etc/pacman.conf" || bad "a release image accepts no unsigned package"
grep -qx 'Include = /etc/pacman.d/smartroom-release' "$target/etc/pacman.conf" || bad "the repository comes from the mirror file"
grep -qx '# release=2026.11.20-studio-edge' "$target/etc/pacman.d/smartroom-release" &&
  grep -qx 'Server = https://releases.example/releases/2026.11.20-studio-edge' "$target/etc/pacman.d/smartroom-release" ||
  bad "the mirror file names the release at its URL"
[[ -z $test_image_pin ]] || bad "a release image carries no test pin"
ok "a release image's pacman.conf names only its signed release repository"

grep -q 'release_version=${release_version:-$(date -u +%Y.%m.%d)-studio-${release_channel}}' "$here/../build-image" ||
  bad "build-image makes a release by default"
grep -q 'release_channel=dev' "$here/../build-image" || bad "the default release channel is dev"
grep -q 'omarchy_channel=$(sed' "$here/../build-image" || bad "the Omarchy lane stays in the inputs"
grep -q 'no release base: set SMARTROOM_RELEASE_BASE' "$here/../build-image" || bad "a release build errors when no release base is set"
grep -q 'SMARTROOM_PRODUCTION_HOST' "$here/../build-image" || bad "the release base can be derived from the production host"
grep -q -- '--dev) dev=true' "$here/../build-image" || bad "build-image has the --dev switch"
grep -q 'build_release_repository' <(declare -f configure_image) || bad "configure_image builds the release repository"
awk '/^  record_packages$/ { r = NR } /^  build_release_repository$/ { b = NR } /^  keep_installed_databases$/ { k = NR }
  END { exit !(r && b && k && r < b && b < k) }' "$builder/bin/build-mac-image" ||
  bad "the release repository is built from the final record, before the image's databases are kept"
ok "a release is the default build; --dev follows the channel"

# build-image's id check runs before it clones firmware or demands the other options.
cli_err() {
  SMARTROOM_RELEASE_BASE=https://releases.example/releases "$here/../build-image" "$@" "$s/cli-out" >"$s/cli.out" 2>"$s/cli.err"
}
refuse_build() {
  local want=$1
  shift
  if cli_err "$@"; then bad "build-image accepted: $*"; fi
  grep -q "$want" "$s/cli.err" || bad "build-image ($*): $(<"$s/cli.err")"
  [[ ! -e $s/cli-out ]] || bad "a refused build-image wrote an output directory"
}
refuse_build 'not YYYY.MM.DD' --release-version 2026.11.20-studio
refuse_build 'not a studio release' --release-version 2026.11.20-mini-dev
refuse_build 'the channel is production' --channel production --release-version 2026.11.27-studio-dev
refuse_build 'not YYYY.MM.DD' --release-version 2026.11.27-studio-dev-bb
refuse_build 'not YYYY.MM.DD' --release-version 2026.11.20-studio-edge
refuse_build 'channel must be dev or production' --channel edge --release-version 2026.11.27-studio-edge
refuse_build 'builds no release' --dev --channel dev
refuse_build 'builds no release' --dev --defer-channel-sign
grep -q -- '--defer-channel-sign) defer_sign=1' "$here/../build-image" || bad "build-image has --defer-channel-sign"
refuse_build 'builds no release' --dev --release-version 2026.11.27-studio-dev --legacy-id
if cli_err --legacy-id --release-version 2026.11.20-studio-edge; then bad "--legacy-id must still need the rest of the options"; fi
grep -q 'missing an option' "$s/cli.err" || bad "--legacy-id did not reach the option check: $(<"$s/cli.err")"
if cli_err --release-version 2026.11.27-studio-dev-b; then bad "a one-letter suffix must still need the rest of the options"; fi
grep -q 'missing an option' "$s/cli.err" || bad "a suffixed dev id did not reach the option check: $(<"$s/cli.err")"
if cli_err --channel production --release-version 2026.11.27-studio-production; then bad "a production id must still need the rest of the options"; fi
grep -q 'missing an option' "$s/cli.err" || bad "a production id did not reach the option check: $(<"$s/cli.err")"
if cli_err; then bad "the default id must still need the rest of the options"; fi
grep -q 'missing an option' "$s/cli.err" || bad "the default id did not reach the option check: $(<"$s/cli.err")"
if cli_err --dev; then bad "--dev must still need the rest of the options"; fi
grep -q 'missing an option' "$s/cli.err" || bad "--dev did not reach the option check: $(<"$s/cli.err")"
ok "build-image release ids follow the tool and --channel; --legacy-id keeps an old name"

if ! command -v repo-add >/dev/null || ! command -v bsdtar >/dev/null; then
  echo "skip - release repository (needs repo-add and bsdtar)"
  exit 0
fi

# ── the release repository ───────────────────────────────────────────────
mkpkg() {
  local dir=$1 name=$2 version=$3 d
  d=$(mktemp -d)
  printf 'pkgname = %s\npkgver = %s\narch = any\nsize = 1\n' "$name" "$version" >"$d/.PKGINFO"
  (cd "$d" && bsdtar -czf "$dir/$name-$version-any.pkg.tar.gz" .PKGINFO)
  rm -rf "$d"
  gpg --batch --yes --quiet --detach-sign --output "$dir/$name-$version-any.pkg.tar.gz.sig" "$dir/$name-$version-any.pkg.tar.gz"
  printf '%s|%s|%s|%s-%s-any.pkg.tar.gz|%s\n' "$name" "$version" "$4" "$name" "$version" \
    "$(sha256sum "$dir/$name-$version-any.pkg.tar.gz" | cut -d' ' -f1)"
}
{
  mkpkg "$package_cache" base 3-2 core
  mkpkg "$repos/smartroom" omarchy-mac-boot 20261120-1 smartroom
  mkpkg "$package_cache" mesa-aurora 26.3-1 omarchy
} >"$work/packages"
printf 'stale\n' >"$target/var/lib/pacman/sync/core.db"
printf 'stale\n' >"$target/var/lib/pacman/sync/omarchy-candidates.db"

release_signer "$s/out" "$key" &
signer=$!
build_release_repository
dir=$(release_dir)
"$here/../release-check" "$dir" "$key" "$smartroom_dir/key.asc" dev >/dev/null || bad "the release directory passes release-check"
(
  cd -- "$(dirname -- "$dir")"
  "$here/../release-check" "$(basename -- "$dir")" "$key" "$smartroom_dir/key.asc" dev >/dev/null
) || bad "release-check accepts a relative directory"
[[ $(cut -d'|' -f1 "$dir/PACKAGES" | paste -sd' ' -) == "base omarchy-mac-boot mesa-aurora" ]] || bad "PACKAGES is the record"
grep -qx "package_set_sha256=$(package_set_sha256)" "$dir/RELEASE" || bad "RELEASE carries the image's package-set digest"
grep -qx 'release=2026.11.20-studio-edge' "$dir/RELEASE" && grep -qx 'line=studio' "$dir/RELEASE" &&
  grep -qx 'channel=dev' "$dir/RELEASE" || bad "RELEASE names the release and its channel"
cmp -s "$dir/smartroom-release.db" "$target/var/lib/pacman/sync/smartroom-release.db" &&
  cmp -s "$dir/smartroom-release.db.sig" "$target/var/lib/pacman/sync/smartroom-release.db.sig" ||
  bad "the image's sync database is the signed release database"
[[ -f $target/usr/share/smartroom/release/PACKAGES.sig && -f $target/usr/share/smartroom/release/RELEASE ]] ||
  bad "the image keeps its signed release record"
ok "the release repository is the record, signed on the build host, and the image's sync database"

keep_installed_databases
[[ $(command ls "$target/var/lib/pacman/sync" | paste -sd' ' -) == "smartroom-release.db smartroom-release.db.sig" ]] ||
  bad "the image keeps only the release database and its signature: $(command ls "$target/var/lib/pacman/sync")"
ok "the image keeps only its release database and signature"

install_smartroom_keyring
[[ $(<"$target/usr/share/pacman/keyrings/smartroom-trusted") == "$key:4:" && -f $target/usr/share/pacman/keyrings/smartroom-revoked ]] ||
  bad "the image ships the SmartRoom keyring first boot populates"
! gpg --batch --show-keys --with-colons "$target/usr/share/pacman/keyrings/smartroom.gpg" 2>/dev/null | grep -q '^sec' ||
  bad "the image's SmartRoom keyring holds the public key only"
while IFS='|' read -r name version _; do
  mkdir -p "$target/var/lib/pacman/local/$name-$version"
  printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n' "$name" "$version" >"$target/var/lib/pacman/local/$name-$version/desc"
done <"$dir/PACKAGES"
"$here/../release-image-check" "$target" >"$s/image-check" || bad "a release image passes release-image-check: $(grep FAIL "$s/image-check")"
grep -qx 'release=2026.11.20-studio-edge' "$s/image-check" || bad "release-image-check names the release"
mkdir -p "$target/var/lib/pacman/local/extra-1-1"
printf '%%NAME%%\nextra\n\n%%VERSION%%\n1-1\n\n' >"$target/var/lib/pacman/local/extra-1-1/desc"
if "$here/../release-image-check" "$target" >"$s/image-check"; then bad "a package outside the release fails the image"; fi
grep -q 'FAIL the installed packages are the release' "$s/image-check" || bad "the extra package is the failure"
rm -rf "$target/var/lib/pacman/local/extra-1-1"
cp "$target/etc/pacman.conf" "$s/pacman.keep"
printf '\n[omarchy]\nSigLevel = Optional TrustAll\nServer = https://pkgs.omarchy.org/stable/$arch\n' >>"$target/etc/pacman.conf"
if "$here/../release-image-check" "$target" >"$s/image-check"; then bad "a live, untrusted repository fails the image"; fi
grep -q 'FAIL pacman.conf names only' "$s/image-check" && grep -q 'FAIL pacman.conf accepts no package' "$s/image-check" ||
  bad "the live repository and its TrustAll are the failures"
cp "$s/pacman.keep" "$target/etc/pacman.conf"
mv "$target/usr/share/pacman/keyrings/smartroom.gpg" "$s/smartroom.gpg"
if "$here/../release-image-check" "$target" >/dev/null; then bad "an image without the SmartRoom keyring fails"; fi
mv "$s/smartroom.gpg" "$target/usr/share/pacman/keyrings/smartroom.gpg"
dev=$s/dev-root
mkdir -p "$dev/etc" "$dev/usr/share/pacman"
cp -a "$target/usr/share/pacman/keyrings" "$dev/usr/share/pacman/"
printf '[options]\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Required\n\n[core]\nServer = https://x.invalid\n' >"$dev/etc/pacman.conf"
"$here/../release-image-check" "$dev" >"$s/image-check" && grep -qx 'release=dev (the image follows its channel)' "$s/image-check" ||
  bad "a dev image with signatures required passes"
ok "release-image-check passes the release image and fails an extra package, a live repository, or no keyring"

cp "$dir/base-3-2-any.pkg.tar.gz" "$s/base.keep"
printf 'x' >>"$dir/base-3-2-any.pkg.tar.gz"
if "$here/../release-check" "$dir" "$key" "$smartroom_dir/key.asc" dev >/dev/null 2>&1; then bad "release-check refuses another archive"; fi
cp "$s/base.keep" "$dir/base-3-2-any.pkg.tar.gz"
gpg --batch --quiet --passphrase '' --quick-gen-key 'other <other@invalid>' ed25519 sign never 2>/dev/null
other=$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { f = $10 } END { print f }')
gpg --batch --yes --quiet --local-user "$other" --detach-sign --output "$dir/smartroom-release.db.sig" "$dir/smartroom-release.db"
if "$here/../release-check" "$dir" "$key" "$smartroom_dir/key.asc" dev >/dev/null 2>&1; then bad "release-check refuses another key's signature"; fi
ok "release-check refuses another archive or another key's signature"

# The fixture key is a throwaway, so it may sign dev and must not pass as production.
prod_fpr=26436A50BDD17118770DE9185FDA1532DC448891
# Restore the database signature the previous case replaced, then check the channel rules.
sign_release "$dir" smartroom-release.db
if "$here/../release-check" "$dir" "$key" "$smartroom_dir/key.asc" production >/dev/null 2>"$s/ch.err"; then
  bad "release-check accepts a throwaway key as production"
fi
grep -q "production must be signed by $prod_fpr" "$s/ch.err" || bad "production names the production key: $(<"$s/ch.err")"
# defer skips the fingerprint rule and still rejects a channel mismatch.
if "$here/../release-check" "$dir" "$key" "$smartroom_dir/key.asc" production defer >/dev/null 2>"$s/ch.err"; then
  bad "defer accepts a RELEASE whose channel is not production"
fi
grep -q 'RELEASE channel is not production' "$s/ch.err" || bad "defer still checks the channel line: $(<"$s/ch.err")"
grep -q 'production must be signed' "$s/ch.err" && bad "defer still applied the fingerprint rule"
if "$here/../release-check" "$dir" "$prod_fpr" "$smartroom_dir/key.asc" dev >/dev/null 2>"$s/ch.err"; then
  bad "release-check accepts the production fingerprint on dev"
fi
grep -q 'dev must not be signed by the production key' "$s/ch.err" || bad "dev refuses the production key: $(<"$s/ch.err")"
sed -i 's/^channel=dev$/channel=production/' "$dir/RELEASE"
sign_release "$dir" RELEASE
"$here/../release-check" "$dir" "$key" "$smartroom_dir/key.asc" production defer >/dev/null \
  || bad "defer accepts the package key when the channel line is production"
if "$here/../release-check" "$dir" "$key" "$smartroom_dir/key.asc" dev >/dev/null 2>"$s/ch.err"; then
  bad "release-check accepts a RELEASE whose channel is production"
fi
grep -q 'RELEASE channel is not dev' "$s/ch.err" || bad "a channel mismatch is the failure: $(<"$s/ch.err")"
sed -i 's/^channel=production$/channel=dev/' "$dir/RELEASE"
sign_release "$dir" RELEASE
ok "release-check matches the channel and the production fingerprint"

mkdir -p "$release_root/v-bad"
: >"$release_root/v-bad/file"
if (sign_release "$release_root/v-bad" ../file) 2>/dev/null; then bad "the host signs only file names inside the release directory"; fi
[[ ! -e $release_root/file.sig ]] || bad "a refused request signs nothing"
(sign_release "$release_root/v-bad" file) || bad "a plain file name is signed"
ok "the host signer signs only plain file names inside the release directory"

# A second build of the same version never overwrites the first.
if (build_release_repository) 2>"$s/again"; then bad "a release version is built once"; fi
grep -q "already exists" "$s/again" || bad "a second build stops on the existing release: $(<"$s/again")"
ok "a release version is built once"
