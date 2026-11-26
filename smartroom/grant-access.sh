#!/bin/bash
# Add one SSH public key and a temporary NOPASSWD sudoers file on a Mac,
# or remove both. The operator types the Mac password at the ssh prompt.
# Does not store passwords. Does not contain a key of its own.
set -euo pipefail

host=
key_file=
sudoers_name=zz-smartroom-install
revoke=0
dry=0
ssh_bin=${SMARTROOM_SSH:-ssh}

help() {
  cat <<'EOF'
Usage: smartroom/grant-access.sh --host ALIAS --key-file PATH [options]

Add the public key in PATH to that account's authorized_keys, and write a
temporary NOPASSWD sudoers drop-in. Remove both with --revoke.

  --host ALIAS           ssh destination (a host alias or user@host)
  --key-file PATH        one-line OpenSSH public key
  --sudoers-name NAME    file in /etc/sudoers.d (default zz-smartroom-install)
  --revoke               remove the key line and the sudoers file
  --dry-run              print the action and do not run ssh
  --ssh PATH             ssh binary (default ssh, or SMARTROOM_SSH)

The sudoers file is temporary. Run --revoke when the work is done.
This script never reads a private key and never talks to a host in --dry-run.
EOF
}

die() { echo "grant-access: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) help; exit 0 ;;
    --dry-run) dry=1; shift ;;
    --revoke) revoke=1; shift ;;
    --host) host=${2:?}; shift 2 ;;
    --key-file) key_file=${2:?}; shift 2 ;;
    --sudoers-name) sudoers_name=${2:?}; shift 2 ;;
    --ssh) ssh_bin=${2:?}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$host" ] || die "--host is required"
[ -n "$key_file" ] || die "--key-file is required"
[ -f "$key_file" ] || die "key file not found: $key_file"
case "$sudoers_name" in
  *[!A-Za-z0-9._-]*) die "--sudoers-name must be a single file name" ;;
esac
[ -n "$sudoers_name" ] || die "--sudoers-name is empty"

key=$(awk 'NF && $0 !~ /^#/ { print; exit }' "$key_file")
[ -n "$key" ] || die "key file has no public key"
case "$key" in
  *$'\n'*) die "public key must be one line" ;;
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|sk-ssh-ed25519@openssh.com\ *) ;;
  *) die "key file is not an OpenSSH public key line" ;;
esac

if [ "$dry" = 1 ]; then
  if [ "$revoke" = 1 ]; then
    echo "dry-run: action=revoke"
  else
    echo "dry-run: action=grant"
  fi
  echo "dry-run: host=$host"
  echo "dry-run: sudoers=$sudoers_name"
  echo "dry-run: key-file=$key_file"
  echo "dry-run: no changes"
  exit 0
fi

quoted_key=$(printf '%q' "$key")
quoted_name=$(printf '%q' "$sudoers_name")

if [ "$revoke" = 1 ]; then
  remote=$(cat <<EOF
set -euo pipefail
KEY=$quoted_key
NAME=$quoted_name
if [ -f "\$HOME/.ssh/authorized_keys" ]; then
  tmp=\$(mktemp)
  grep -v -F -x -- "\$KEY" "\$HOME/.ssh/authorized_keys" >"\$tmp" || true
  mv "\$tmp" "\$HOME/.ssh/authorized_keys"
  chmod 600 "\$HOME/.ssh/authorized_keys"
fi
sudo rm -f "/etc/sudoers.d/\$NAME"
echo "revoked \$(hostname -s) user \$(id -un) sudoers \$NAME"
EOF
)
else
  remote=$(cat <<EOF
set -euo pipefail
umask 077
KEY=$quoted_key
NAME=$quoted_name
mkdir -p "\$HOME/.ssh"
chmod 700 "\$HOME/.ssh"
touch "\$HOME/.ssh/authorized_keys"
grep -q -F -x -- "\$KEY" "\$HOME/.ssh/authorized_keys" || printf '%s\n' "\$KEY" >> "\$HOME/.ssh/authorized_keys"
chmod 600 "\$HOME/.ssh/authorized_keys"
printf '%s\n' "#\$(id -u) ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/\$NAME" >/dev/null
sudo chmod 440 "/etc/sudoers.d/\$NAME"
sudo visudo -cf "/etc/sudoers.d/\$NAME" >/dev/null
echo "granted \$(hostname -s) user \$(id -un) sudoers \$NAME"
EOF
)
fi

ssh_args=(-o PreferredAuthentications=publickey,keyboard-interactive,password)
if [ -t 0 ] || [ -t 1 ]; then
  ssh_args+=(-t)
fi
exec "$ssh_bin" "${ssh_args[@]}" "$host" "$remote"
