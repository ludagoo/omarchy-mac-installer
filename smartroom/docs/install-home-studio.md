# Installing onto the home Studio's existing stub (no new stub, no 1TR)

> Superseded for fresh installs (2026-11-17, later): a Mac goes back to plain
> macOS with `smartroom/mac/remove-firmware` and gets SmartRoom Firmware with
> `smartroom/mac/engine-install` (Omarchy's own engine, so Omarchy's own
> stage 1 for the board), as in [install-zoom-room.md](install-zoom-room.md).
> This page stays as the record of the stub-reuse path.

For the home test Studio (Mac14,13, macOS 14.5, 192.168.1.147). It already has
an Asahi-style stub from the old SmartRoomOS install whose 1TR step is done:

| | |
| --- | --- |
| `disk0s3` | APFS container of the stub volume "SmartRoomOS" (stage 1 m1n1 installed by 1TR) |
| `disk0s4` | ESP, 2 GiB FAT, PARTUUID `a702d68c-b4bb-407e-845c-a60060a5d22b` (stage 1 chainloads `<this>;m1n1/boot.bin`) |
| `disk0s5` | old Linux root, ~404 GB |

## Is reusing it safe?

Yes for the disk: stage 1 only reads the ESP by its PARTUUID, which a
reformat does not change; everything after stage 1 (m1n1 stage 2, U-Boot,
Limine, the UKI, `/boot`, the root) is rewritten from the payload, exactly as
the Engine writes it. macOS, its container and the stub are never touched,
and macOS stays the default boot volume (`bless --nextonly`).

One difference from a fresh Omarchy install remains: **stage 1 itself**. The
stub's stage 1 (sha256 `4ecdb756…`) is m1n1-aurora's raw stage 1, which
Omarchy installs only on the MacBook Neo (`esp/aurora/stage1-j700.bin`). For
every other Mac, the Studio included, Omarchy's Engine installs its own
`boot/m1n1.bin` (sha256 `51eb189f…`). Changing stage 1 needs 1TR. So:

- if the stock image sends DHCP on the reused stub, the Neo stage 1 is fine on
  the Studio and the old silent boot was in the old image;
- if it stays silent, stage 1 is the one non-Omarchy piece left, and the next
  step is a fresh Omarchy stub (Engine install + 1TR), not more debugging.

## Payloads (built 2026-11-17 on studio-build, staged on the Mini)

| | file (in `lucas@192.168.1.62:/home/lucas/smartroom-omarchy-fork/release/`) | sha256 |
| --- | --- | --- |
| stock Omarchy (baseline) | `baseline/omarchy-2026.11.17-aarch64-apple-silicon-mac-stable-os-package.zip` | `f1ba37b13a1c7d265171584f834a9f9b21336097fbb55b066721a942ae263d7c` |
| SmartRoom Firmware | `smartroom/smartroom-firmware-2026.11.17-aarch64-apple-silicon-mac-stable-os-package.zip` | `787e640cde745c47e9652f68a01e398246feeaded54186cec7c627547cdb9e84` |

## Steps (Claude, on macOS over SSH as the owner account)

```sh
# 0. power-loss restart (a power cycle then boots macOS, the default)
sudo pmset -a autorestart 1

# 1. look before touching anything; stop if this does not match the table above
diskutil list disk0
diskutil info disk0s4 | grep -E 'Partition UUID|Volume Name|Disk Size'
diskutil info disk0s5 | grep -E 'Partition Type|Disk Size'
diskutil apfs list | grep -B2 -A16 SmartRoomOS     # note the stub's System volume, e.g. diskNs1

# 2. fetch the script and the payload from the Mini
mkdir -p ~/smartroom-omarchy && cd ~/smartroom-omarchy
scp lucas@192.168.1.62:/home/lucas/smartroom-omarchy-fork/release/install-onto-existing-stub .
scp lucas@192.168.1.62:'/home/lucas/smartroom-omarchy-fork/release/baseline/*.zip' .
shasum -a 256 *.zip                                   # must print the sha256 below
chmod +x install-onto-existing-stub

# 3. dry run (checks only), then install
sudo ./install-onto-existing-stub --zip <ZIP> --sha256 <SHA256> \
  --esp disk0s4 --esp-partuuid a702d68c-b4bb-407e-845c-a60060a5d22b --linux disk0s5
sudo ./install-onto-existing-stub --zip <ZIP> --sha256 <SHA256> \
  --esp disk0s4 --esp-partuuid a702d68c-b4bb-407e-845c-a60060a5d22b --linux disk0s5 --full-readback --yes
# it prints "Boot diskNsB, Root diskNsC": keep them for the next install

# 4. next boot only into the stub (owner password on stdin, never in argv)
sudo bless --setBoot --nextonly --device /dev/<stub System volume> --user <owner> --stdinpass < <owner password file>
bless --getBoot
sudo shutdown -r now
```

Second install (the SmartRoom image after the stock one), on the layout step 3
made: `--boot diskNsB --root diskNsC` instead of `--linux disk0s5`, plus
`--firstboot-env <file>` (SMARTROOMOS_SERVER_URL, SMARTROOMOS_AGENT_INSTALL_SHA256,
optional SMARTROOMOS_UNIQUE_ID; https only, and `--production` for the production
server; the old ESP's `asahi/extras/firstboot.env` is
restored automatically if it was there). Then step 4 again.

## Watching from the Mini

```sh
ip -br link                                            # the wired interface, e.g. enp…
sudo tcpdump -lni <iface> 'ether host a4:fc:14:2d:d4:fc'
```

Expect ARP and DHCP (udp 67/68) from `a4:fc:14:2d:d4:fc` within about three
minutes of the reboot. The stock image also answers ping (ufw allows ICMP)
and has no SSH. The SmartRoom image has sshd with the admin key:
`ssh -i ~/.ssh/smartroomos_ed25519 root@<ip>`. Give it ten minutes before
calling it silent.

## Getting back to macOS

macOS stays the default: any restart after the Linux boot comes back to macOS.

- stock image (no SSH): power-cycle the Studio (pull the plug for ten seconds,
  or hold the rear power button ten seconds and press it again); with
  `autorestart 1` the plug alone is enough;
- SmartRoom image: `ssh root@<ip> systemctl reboot`.

The SmartRoom first boot ends in a reboot, which also lands in macOS while
the stub is blessed `--nextonly`. To make SmartRoom Firmware the default,
bless again without `--nextonly`.

The old ESP is kept in `/var/root/smartroom-esp-backup-<time>` on macOS.
