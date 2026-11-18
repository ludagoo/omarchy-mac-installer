# SmartRoom Firmware on a production Zoom-room Mac

How to put SmartRoom Firmware beside macOS on an Apple Silicon Zoom-room Mac
(macOS keeps running Zoom Rooms), switch the room between the two, and take
SmartRoom Firmware off again. Everything is done over SSH except one step at
the Mac (Apple's 1TR step, with a USB keyboard; a display is optional).

The tools are in this repository (ludagoo/omarchy-mac-installer, branch
`smartroom/main`):

| Tool | Runs on | Does |
| --- | --- | --- |
| `smartroom/mac/engine-install` | macOS, sudo | Fresh install: drives Omarchy's own pinned installer engine headless with our image ([engine-headless.md](engine-headless.md)) |
| `smartroom/mac/remove-firmware` | macOS, sudo | Back to plain macOS: removes the stub, ESP and Linux partitions and gives the space back to macOS (mirrors Omarchy's Remove Omarchy) |
| `smartroom/mac/smartroom-boot-os` | macOS, sudo | Start SmartRoom Firmware (or macOS) next / from now on; needs an owner credential |
| `smartroom-boot-os` (package) | SmartRoom Firmware, root | Start macOS (or SmartRoom Firmware) next / from now on; no credential |

None of the macOS tools calls `python3`, `git`, `clang`, `xcrun` or `strings`
(they would open the Command Line Tools dialog on the room's screen).
`engine-install` runs the engine's own bundled Python, as Omarchy's app does.

Status (2026-11-17): every step below is tested on Linux against simulated
macOS tools only. The first real run is the home Studio (M2 Max, j475c). See
[What is not proven yet](#what-is-not-proven-yet).

## 1. Before you start (Jamf and the Mac)

On the Mac (or through Jamf):

1. **Supported Mac and macOS.** Apple Silicon. Tested hardware: Mac Studio
   M2 Max (Mac14,13, j475c). The image's `installer_data.json` lists the
   macOS system firmware versions the stub can use (`supported_fw`); the
   engine refuses a Mac it cannot serve, before changing anything.
2. **Recovery Lock cleared.** A Recovery Lock password blocks the 1TR step.
   In Jamf: the computer's inventory, Security, Recovery Lock; clear it
   (Jamf's Recovery Lock management, or the `SetRecoveryLock` MDM command
   with an empty password). Set it again afterwards if policy wants it.
3. **An owner account.** A local **administrator** that is also a **volume
   owner** (has a secure token): Apple Silicon only lets an owner change the
   startup disk or approve the 1TR step. Check over SSH:

   ```sh
   sysadminctl -secureTokenStatus <admin>          # ... ENABLED
   sudo diskutil apfs listUsers / | grep -B1 -A3 '<admin>'   # Volume Owner: Yes
   ```

   If the admin has no token, grant it from an existing owner
   (`sudo sysadminctl -secureTokenOn <admin> -password - -adminUser <owner> -adminPassword -`)
   or with Jamf's bootstrap token, then `sudo diskutil apfs updatePreboot /`.
4. **Remote Login** (SSH) on for that admin (Jamf: a Remote Login policy or
   configuration profile).
5. **That admin logged in at the console** while the engine runs. Omarchy's
   engine (upstream asahi-installer) refuses to run unless a machine owner is
   logged in at the Mac's screen ("Perhaps you are running this installer over
   SSH?"); a Zoom Rooms auto-login account that is not an owner does not
   count. Either log the admin in with Screen Sharing and leave the session
   open, or switch automatic login to the admin for the install and back
   afterwards (needs FileVault off; Zoom Rooms Macs usually have it off):
   `scutil <<<'show State:/Users/ConsoleUser' | grep kCGSSessionUserNameKey`
   must show the admin.
6. **Network.** The Mac reaches Apple's CDN (the engine fetches the macOS
   firmware parts it needs from Apple's IPSW) and `gs.apple.com` (bless can
   ask Apple to sign the new boot policy); the room's Ethernet reaches the
   SmartRoom server (first boot registers there).
7. **No Jamf restarts or macOS updates scheduled** during the install, and
   leave macOS updates deferred until the room has finished its first boot.
8. **At the Mac for step 4 (1TR):** a USB keyboard. A display is optional:
   VoiceOver reads the screens.

## 2. How much to give SmartRoom Firmware

`engine-install` takes the space from macOS (`--source <macOS container>
--size N`) or from free space. N is the whole SmartRoom Firmware install: the
stub (2.5 GB), the ESP (500 MiB), Boot (2 GiB) and Root (the rest).

Lucas's rule (2026-11-07, restated 2026-11-17): **macOS keeps only what it needs; SmartRoom
Firmware gets the rest of the disk.** macOS stays only for the Zoom Rooms transition.

- The dry run lists the macOS container with `minimum_container_bytes` (what macOS itself needs;
  about 77.5 GB on the M2 Max Studio with macOS 14.5).
- `engine-install` applies the rule itself: with `--source <macOS container>` and no `--size`,
  macOS keeps that minimum plus 20 GiB for its own updates and SmartRoom Firmware gets the rest
  (it prints the split). On a 500 GB Studio that is about 100 GB for macOS and about 390 GB for
  SmartRoom Firmware. `--size N` overrides it; don't use it for room installs.
- The engine's floor is ~38.5 GB (Root's 32 GiB minimum from `installer_data.json`); never go near it.

If a Mac was installed with a smaller Root, it can be grown later without a reinstall or 1TR:
shrink macOS from macOS (`diskutil apfs resizeContainer disk0s2 100g`), add a Linux partition in
the freed space (`diskutil addPartition disk0s2 %Linux% %noformat% <bytes>B`), then from SmartRoom
Firmware `btrfs device add -f /dev/<new partition> /` (done on the home Studio 2026-11-17; the
two-device root boots normally).

## 3. Install

From the Mini, copy the tools and the release to the Mac (`MAC` is the Mac's
address, `ADMIN` the owner account):

```sh
REL=~/smartroom-omarchy-fork/release/smartroom-3
REPO=~/smartroom-omarchy-fork/work/omarchy-mac-installer
ssh ADMIN@MAC 'mkdir -p smartroom/smartroom/mac smartroom/Engine smartroom/Packaging smartroom/image'
scp $REPO/smartroom/mac/engine-install $REPO/smartroom/mac/remove-firmware $REPO/smartroom/mac/smartroom-boot-os ADMIN@MAC:smartroom/smartroom/mac/
scp $REPO/Engine/source-lock.json ADMIN@MAC:smartroom/Engine/
scp $REPO/Packaging/identity.conf ADMIN@MAC:smartroom/Packaging/
scp $REL/smartroom-firmware-*-os-package.zip $REL/installer_data.json $REL/SHA256 ADMIN@MAC:smartroom/image/
scp <the room's firstboot.env> ADMIN@MAC:smartroom/image/firstboot.env
```

`firstboot.env` (smartroomcontrollerfirmware `builder/image/firstboot.env.template`):

```
SMARTROOMOS_SERVER_URL=https://<server>
SMARTROOMOS_AGENT_INSTALL_SHA256=<curl -fsS https://<server>/api/agent/install.sh | sha256sum>
SMARTROOMOS_UNIQUE_ID=<optional pre-minted uuid>
```

On the Mac, get Omarchy's signed restore-image helper (the engine requires
it, even where it never runs it), from the app's DMG
([engine-headless.md, The restore-image helper](engine-headless.md#the-restore-image-helper)):

```sh
curl -fLo /tmp/oi.dmg https://mac.omarchy.org/v1/installer/2.3.16/Omarchy-Mac-Installer-2.3.16.dmg
echo "0b70717b0bfa3277f41159b5de4a0cab9f75dda9ba64f13d4b4a02a7860dd027  /tmp/oi.dmg" | shasum -a 256 -c
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint /tmp/omarchy-dmg /tmp/oi.dmg
```

Then a dry run, which runs the engine's inspection and plan and changes
nothing; it prints the disk's candidates (free space, and macOS's container
with how far it can shrink):

```sh
cd ~/smartroom
(cd image && shasum -a 256 -c SHA256)
Z=$(ls image/smartroom-firmware-*-os-package.zip); S=$(cut -d' ' -f1 image/SHA256)
args=(--payload "$Z" --sha256 "$S" --installer-data image/installer_data.json --owner ADMIN
  --firstboot-env image/firstboot.env --source disk0s2
  --restore-image "/tmp/omarchy-dmg/Omarchy Installer.app/Contents/Helpers/omarchy-restore-image")
sudo smartroom/mac/engine-install "${args[@]}"            # password on the prompt (or stdin)
```

Use the macOS container the dry run lists as `resize` for `--source`
(usually `disk0s2`); the dry run prints how much macOS keeps. Leave `--source` out only when
the Mac already has free space. Then install (tens of minutes; most is writing Root):

```sh
sudo smartroom/mac/engine-install "${args[@]}" --yes
```

It ignores a dropped SSH session; the log is
`/var/root/omarchy-engine-install/run-*/engine-install.log`
(`sudo tail -f` it after reconnecting). It ends with the journal at
`awaiting_recovery`, `omarchy/install.conf` (`encrypt=0`) and
`asahi/extras/firstboot.env` on the new ESP, SmartRoom Firmware as the
**default** startup disk (checked, re-blessed if not), and the 1TR steps.
If it stops at "could not authorize it as the startup disk" (a wrong
password), rerun only that step:
`sudo smartroom/mac/engine-install --retry <run dir> --yes`.
Anything else after the engine started writing: do not start a fresh
install; read the log, then remove what it made with
`smartroom/mac/remove-firmware` (section 8).

## 4. 1TR (at the Mac)

`engine-install` prints these; they are Apple's step and need the person at
the Mac:

1. `sudo shutdown -h now` (over SSH is fine). Wait until the Mac is off.
2. Press and **hold** the power button (Mac Studio and mini: on the back)
   about 10 seconds, until "Loading startup options".
3. No display: press **Cmd+F5** for VoiceOver; it reads the startup options.
   Arrow keys to "SmartRoom Firmware", Tab to Continue, Control+Option+Space.
4. If Recovery asks for a user or volume to recover: macOS, then the owner,
   and the owner's password.
5. SmartRoom Firmware Installer opens on "Finish setup" (the SmartRoom
   Firmware banner; screenshots in [recovery-app.md](recovery-app.md)). It
   asks for the owner's password, then Install, then Restart. (VoiceOver:
   Control+Option+arrows to move, Control+Option+Space to press.)
6. The Mac starts SmartRoom Firmware. First boot sets up the room and
   restarts once by itself.

Because the stub was the default before 1TR, step 2 finishes in one pass.

## 5. Verify (from the Mini)

```sh
sudo tcpdump -lni <wired iface> 'ether host <the Mac's Ethernet MAC>'   # DHCP within ~3 min
ssh -i ~/.ssh/smartroomos_ed25519 root@<ip> '
  cat /usr/share/smartroomos/build-info
  systemctl is-system-running; systemctl is-active sshd NetworkManager smartroom-agent
  nmcli -t -f NAME,DEVICE connection show --active      # SmartRoom wired on the 10GbE port (Studio)
  stat -c "%U:%G %a %n" /etc/sudoers.d/smartroomcontroller /etc/NetworkManager/system-connections/*
  sudo -l -U smartroomcontroller | tail -2               # the Room Controller has its sudo rule
  find /etc /usr /opt -xdev ! -uid 0 | head              # nothing
  smartroom-boot-os status                               # default: SmartRoom Firmware
  hostname                                               # smartroom-<uuid> until adopted'
```

The wired profile matches the Studio's 10GbE (AQC113, `atlantic`), which
drops replies unless it accepts all MAC addresses (omacom/omarchy-mac-pkgs#137).
Other Ethernet chips use NetworkManager's default connection.

## 6. Adopt

First boot registers the machine with the server in `firstboot.env` as
`smartroom-<uuid>` with its MAC and IP addresses, and keeps registering
until ops adopts it (smartroomcontrollerfirmware `docs/install.md`). Adopt it
in the SmartRoom server; its hostname then becomes the room id.

## 7. Switching between SmartRoom Firmware and macOS (Zoom Rooms)

**From SmartRoom Firmware to macOS** needs no password: Linux writes the
Mac's startup choice in NVRAM with Omarchy's `aurora-bless` (Omarchy's fork
of Asahi's `asahi-bless`, in every Omarchy Mac image), through our package:

```sh
sudo smartroom-boot-os macos --once --reboot   # macOS for one start, then back to the default
sudo smartroom-boot-os macos --reboot          # macOS from now on
sudo smartroom-boot-os firmware                # SmartRoom Firmware from now on (clears a pending --once)
```

**From macOS to SmartRoom Firmware** is the hard direction. On Apple Silicon
macOS's `bless` only changes the startup disk with a volume owner's name and
password (`--user`/`--stdinpass`), even as root (without them:
`BYErrorDomain Code=103 "Owner authentication is required"`). Nothing else
can: there is no MDM command or declaration for the startup disk, the
bootstrap token does not authorize `bless`, `nvram boot-volume` is not
writable from macOS (XNU allows it only to Apple-entitled processes), and
`systemsetup -setstartupdisk` does not work on Apple Silicon. Research with
sources: [research-bless-unattended.md](research-bless-unattended.md) (2026-11-17).

The options, for Lucas to choose:

| | How a room goes macOS → SmartRoom Firmware | Credential on the Mac | Security cost | Caveats |
| --- | --- | --- | --- | --- |
| **A. SmartRoom Firmware is the default** | Restart macOS (Jamf policy, MDM RestartDevice, `sudo shutdown -r now`). macOS runs only when Linux sends it there with `smartroom-boot-os macos --once` | None | None added | Every macOS restart (updates, power cuts) lands in SmartRoom Firmware; a room meant to stay on Zoom Rooms needs SmartRoom Firmware to send it back (`macos --once` at boot when the room's mode is macOS: ~1 min extra per macOS restart). macOS updates are reported to reset the default to macOS: watch it (a Jamf extension attribute reading `nvram boot-volume`, readable as root) and fix with B once |
| **B. Stored owner credential** (`smartroom/mac/smartroom-boot-os firmware [--once] --credential-file /var/root/.smartroom-boot-owner`, run by Jamf or a LaunchDaemon) | One command, any time | A dedicated owner account's password, root-only file (or System keychain) | Anyone with root or admin on that Mac can read it. That account can change the startup disk, authorize macOS updates, start Erase All Content and Settings, unlock FileVault at boot and log in (hide it, no shell). If it is a **standard** user (not admin) it cannot lower boot security in 1TR or hand out secure tokens: whether `bless --user` accepts a non-admin owner is untested | Rotate the password from Jamf (`sysadminctl -resetPasswordFor` with the old one keeps the token) |
| **C. Jamf policy with the password as a script parameter** (`smartroom/mac/smartroom-boot-os firmware --owner "$4" <<<"$5"` style) | Run the policy | Only while the policy runs | Parameters show in `ps` during the run and are readable by Jamf admins; "encrypted parameters" only obscure them. Same account power as B | Jamf's built-in "Startup Disk" restart option has no way to pass owner credentials on Apple Silicon |
| D. The Jamf management account / LAPS | As C, fetching the LAPS password at run time | Jamf API credentials on the Mac | Worse than B: an API secret on every Mac, and the management account often has no secure token | Not recommended |

**Recommendation:** A, the only option with no credential on the Mac and the
least to maintain, provided rooms are allowed to boot SmartRoom Firmware
first after every macOS restart. Keep B (a dedicated hidden **standard**
owner account, if the lab test shows `bless` accepts it) as the repair path
for a Mac whose default drifted to macOS. C is acceptable for occasional
manual switches. For testing, B and C are implemented by
`smartroom/mac/smartroom-boot-os` (password on stdin or a root-only 0600
file; it never puts the password in argv or a log).

Tests to run on one lab Mac before choosing (from the research): `bless
--nextonly` needs the same owner credential; a standard (non-admin) owner
works with `bless --user`; after `smartroom-boot-os macos --once` and a
macOS restart the Mac returns to SmartRoom Firmware; a macOS minor update
keeps (or resets) the default; `nvram alt-boot-volume` is readable as root
after `bless --nextonly`. Also reported: from macOS 27 on, Asahi-style
volumes disappear from Startup Disk and startup options unless their APFS
"bootable" flag is set; check before any room moves to macOS 27.

## 8. Back to plain macOS (remove SmartRoom Firmware)

`smartroom/mac/remove-firmware` returns the Mac to plain macOS: it finds the
stub APFS container (whatever its name: "SmartRoom Firmware", "SmartRoomOS",
"Omarchy"), its ESP, Boot and Root (or an older single Linux partition)
between macOS and Apple's Recovery, confirms them by the ESP's files (m1n1,
the stub record), sets macOS as the startup disk if it is not, deletes them
and grows the macOS container back. It mirrors Omarchy's own Remove Omarchy
(`Development/Removal.md`) and refuses to touch the macOS container, Apple's
Recovery and the iBoot system container, or any layout it does not
recognize. Dry run first:

```sh
sudo ~/smartroom/smartroom/mac/remove-firmware                       # shows what it found and would do
sudo ~/smartroom/smartroom/mac/remove-firmware --owner ADMIN --yes   # password on stdin if the startup disk must change
```

The owner password is needed only when SmartRoom Firmware is the startup
disk (macOS's `bless` needs it). Afterwards `diskutil list` shows the ISC,
the macOS container (back to its full size) and Recovery only.

## What is not proven yet

Tested only on Linux against simulated macOS tools (each tool's
`smartroom/test/*-test.sh`); never on a Mac:

- The engine run itself on macOS: console-user and owner checks, the bundled
  Python under `env -i`, the restore-image helper's signature, the engine's
  inspection and plan on a real disk, `cp -c`, the payload preflight of our
  image ([engine-headless.md, What is unverified](engine-headless.md#what-is-unverified)).
- `bless --getBoot` and `diskutil info` output after the engine's bless; the
  re-bless path; writing `firstboot.env` and `install.conf` on the new ESP
  from macOS.
- 1TR with VoiceOver on a fresh Engine install (done once on the home Studio
  on 2026-11-17 with the earlier stub), and the native Recovery app with
  VoiceOver.
- `remove-firmware` on real `diskutil` (`apfs deleteContainer` also removing
  the physical store, `eraseVolume free none`, `apfs resizeContainer ... 0`
  and its `limits -plist` `MaximumSize`, BSD numbers after a deletion,
  `mount readOnly nobrowse` of the FAT ESP) and `bless --mount / --setBoot`
  there; the plist key names it reads (`Internal`, `WholeDisk`, `Content`
  values such as `Linux Filesystem`, `PartitionMapPartitionOffset`, `DiskUUID`,
  `APFSVolumeGroupID`, `apfs list` containers and volumes); `plutil -extract
  KEY raw` printing plain values; `nvram -p` printing `boot-volume` and
  `alt-boot-volume` tab-separated as `GUID:PARTUUID:VGUUID`; and its speed (a
  few hundred `plutil` calls per disk read).
- Both `smartroom-boot-os` tools on a Mac: `aurora-bless` on j475c NVRAM from
  linux-aurora (the `/dev/mtd/by-name/nvram` device), `bless --nextonly` with
  an owner, `nvram alt-boot-volume` read-back, and the switching behaviour
  above.
- The Mac mini (not the Studio): its Ethernet and the image's device tree.
- Apple's `/bin/bash` 3.2: the macOS scripts' tests pass under GNU bash
  3.2.57 built on Linux (`TEST_BASH=<bash-3.2> bash smartroom/test/<tool>-test.sh`),
  not under Apple's build.
