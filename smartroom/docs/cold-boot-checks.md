# Building an edge image and checking it on a Studio

This is the recipe behind the image the runbook tells you to install
([install-zoom-room.md](install-zoom-room.md), "2b. Which image to install"),
the three cold-boot checks that were run on the home Studio, and the power-cut
test that only a person at the plug can run.

## Build

ARM builds happen only on studio-build. Pin three commits and run:

```
smartroom/hardware/build-edge-image INSTALLER_SHA PKGS_SHA FIRMWARE_SHA
```

It builds `aura`, `linux-aurora` and `mesa-aurora` (with `vulkan-aurora`),
makes the SmartRoom package repo (`smartroom/build-packages`), makes the image
(`smartroom/build-image`) and runs `smartroom/desk-check` on it. It stops at the
first failed check. The desk-check is the gate: it has to pass, including the
line "Mesa opens the kernel's GPU driver (aurora)" (a Mesa that does not match
the kernel's driver gives a room with no picture), and the line from
`smartroom/ac-power-check` that says the power-on-after-power-loss unit is in
the image.

The image of 2026-11-20 (`smartroom-edge-2026.11.20`): installer `ddc216c`,
packages `7809f7c`, firmware `af9323e`, aura `13fb868`, kernel `d77dde4`,
`mesa-aurora` `23791c1`, 455 packages, sha256
`269054f8a90cb5cbed6d54d155187edf202333735a43a5551f63f0668767372a`.
It took about ten minutes with the earlier builds cached. The release folder
keeps the image, its `SHA256`, `build-info.txt` and the desk-check logs.

## Cold-boot checks on a Studio

These were run on the home Studio (the one under `STUDIO-LOCK`) on 2026-11-20.
The Studio already ran the image's boot set (same versions of the kernel, aura
and Mesa; `libgallium` is byte-identical to the image's), so nothing had to be
installed. If a Studio's packages differ, put the image's packages on it with
`pacman -U` (never by extracting archives, never by reinstalling from macOS),
after `cp -a` of the ESP files you are about to replace (the Linux `.efi` and
`boot.bin`) to a folder outside `/boot/efi`. Never `objcopy` or `strip` a file
on `/boot/efi`.

Rules for every run (the safety section of the program):

- The lock first: `~/smartroom-aurora-pr/STUDIO-LOCK`. Stop if
  `~/smartroom-aurora-kernel/HOLD-REBOOTS` exists.
- macOS stays the persistent default. Every Linux boot is a one-shot:
  `aurora-bless --set-boot-macos --yes`, then
  `aurora-bless --next --set-boot "SmartRoom Firmware" --yes`.
  `smartroom/hardware/studio-oneshot-reboot` does exactly that, checks
  `test -L /lib -a -L /bin -a -L /sbin` first, then reboots and waits for SSH.
- `panic=10` stays on the kernel command line.
- Never touch `end0`, NetworkManager's settings, Wi-Fi, sshd or the Room
  Controller. Never remove the Ethernet workaround profile.
- If Linux does not answer within 10 minutes, try 192.168.1.166, then macOS. If
  macOS answers, run no `sudo`, write `STUDIO NEEDS CLAUDE` to the status log
  and stop.

`smartroom/hardware/studio-state-report` (run on the Studio as root) prints what
each check below looks at. Its output for each run is in the job folder
(`check-before.txt`, `check-A.txt`, `check-B.txt`, `check-C.txt`).

### A. Boot with no screen

Reboot with nothing on the HDMI and USB-C ports (the Studio had no display
attached). Pass when the desktop is up and the Room Controller is online.

Result: SSH after 38 s; Hyprland up on Mesa's `aurora` driver; the agent
reported `no_display` and, once the QA rig added outputs, three monitors;
the Room Controller was connected; no failed units; no coredump.

### B. Network unplugged at boot (simulated)

A cable cannot be pulled remotely, and the network settings must not be touched.
`smartroom/hardware/studio-netsim` marks `end0` as unmanaged for the next boot
only, through a drop-in in `/run` (gone at any reboot; NetworkManager's profile
and config files are never written), and hands it back after 300 s, with a
second timer that restarts NetworkManager if there is still no default route
two minutes later. Pass when boot does not wait for the network, the desktop
comes up, and the room registers again by itself when the "cable" returns.

Result: `graphical.target` after 3.1 s of userspace (no hang); the agent
registered again 8 s after the hand-back; SSH back at 333 s. The first-connect
unit failed while offline (the system showed "degraded") and cleared itself on
the next 60 s poll. What this does not prove: the Ethernet PHY's own link-up
behaviour with a real cable.

### C. Crash, then reboot

`STUDIO_CRASH=1 smartroom/hardware/studio-oneshot-reboot` re-arms the one-shot
(so a reboot lands in Linux, not in macOS), checks `kernel.panic = 10` and
`panic=10` in `/proc/cmdline`, and runs `sysrq c`.

Result: the connection dropped at once, Linux answered 70 s later, still the
same one-shot (not macOS), btrfs replayed its tree-log, the PMU logged "1 boot
error" and the counter was clear after the next clean boot.

### Seen on the way, not part of the checks

- The Apple watchdog is present (`wdctl`), but systemd does not feed it. A hung
  kernel that does not panic is not rebooted by it.
- The Studio's package set is not the one our repo builds (other packages are
  newer or different); the room will drift until it is reinstalled from an image.

## Power-cut test for Lucas

The power cannot be cut remotely, so this is not done yet. Marking the feature
verified needs a person at the plug (or a switched power strip). Use the Studio
for P1 to P6, the Mac mini for M0 to M4.

What is already known: a Studio sets its own "start up automatically after a
power failure" at every boot (`smartroomos-ac-power.service`: the PMU
`pm_setting` byte, "restore" = bit 0 clear). It reads back correctly (off, then
restore, byte `0x22`), and the image check proves the unit and the kernel switch
are in the image. Whether a real cut brings the room back is what this test
answers. A Mac mini (Intel, T2) cannot be set from Linux at all: it needs
`sudo pmset -a autorestart 1` in macOS before the disk is erased
(`engine-install` does this for a Studio; the mini's installer must do it too
once the macOS path is merged).

Before you start, with the Studio on Linux and SSH working:

- Studio: `smartroomos-ac-power status` must print `mechanism=sysfs mode=restore`.
- Note the time on your phone for each step. Nobody is in a class.

### Studio

The step names match `docs/hardware-tests.md` in the firmware repo (P1 to P6).

| Step | Do | Pass |
| --- | --- | --- |
| P1 | Read only, on the Studio over SSH: `smartroomos-ac-power status`; `cat /sys/bus/platform/drivers/macsmc-reboot/*/ac_power_mode`. | `mechanism=sysfs mode=restore`; the file prints `off [restore] always`; `systemctl status smartroomos-ac-power` is active (exited). |
| P2 | Optional, and only if Lucas himself does it (macOS `sudo` is never run by an agent): in macOS `sudo pmset -a autorestart 0`, then Restart into Linux. | `journalctl -b -u smartroomos-ac-power` says `mode=restore (was off)`; a second reboot says `(was restore)`. |
| P3 | Linux up, `systemctl is-system-running` says `running`. Pull the plug, wait 60 s, plug back in. Do not press the power button. | The Studio powers on by itself within a minute; SSH answers within about 3 minutes of the plug; the desktop is up; the Room Controller shows online. Write down the seconds from plug to SSH. Then `smartroomos-ac-power status` says `(was restore)`. It booted Linux, not macOS and not the startup picker. |
| P4 | `sudo systemctl poweroff`. When the light is off, wait 60 s with the plug in, then pull the plug for 60 s and plug back in. | It stays off ("restore" does not turn on after a clean shutdown). Press the power button; it boots Linux. |
| P5 | Five 60 s cuts in a row, each only after SSH answers. | Linux every time; never recoveryOS or the picker; `journalctl -k | grep -i 'boot error'` shows no growth; the Room Controller comes back each time. |
| P6 | One cut of an hour or more (overnight). | It powers on; the clock is right (`timedatectl`); `smartroomos-ac-power status` still says `mode=restore`. |

If P3 fails (stays off), press the button once, SSH in, and keep the output of
`smartroomos-ac-power status` and `journalctl -b -1 | tail -50`.

### Mac mini (Intel, T2)

| Step | Do | Pass |
| --- | --- | --- |
| M0 | In macOS, before the install: `pmset -g | grep autorestart` must print `autorestart 1` (set it with `sudo pmset -a autorestart 1`). Install SmartRoom Firmware. In Linux: `smartroomos-ac-power status`. | `mechanism=t2-smc policy=set-from-macos pch_afterg3=0` (write down the number if it is 1). |
| M1 | Linux up, SSH answering. Pull the plug for 60 s and plug back in. | The mini powers on by itself; SSH within minutes. Write down the seconds. |
| M2 | If it stays off: press the button once, SSH in, `journalctl -b -1 | tail -50`. Boot macOS Internet Recovery and read `pmset -g | grep autorestart` again. | Records why. If it is still 1 and the mini stays off, the T2 holds it off and the room needs a switched power strip. |
| M3 | If it powers on but never answers SSH: connect a screen and photograph where it waits. | Records whether Apple's 2 to 4 minute firmware wait ends by itself. |
| M4 | `sudo systemctl poweroff`, wait 60 s, cut the power 60 s, plug back in. | Records whether it powers on after a clean shutdown (macOS's own rule differs between a cut while running and a cut after a clean shutdown). |

Keep the seconds and what you saw for each step; they go into
`docs/hardware-tests.md` in the firmware repo, and the feature is marked verified only if P3 to P6 pass
(M0 to M4 give the mini's answer separately; a mini that stays off is a reason
to give that room a switched power strip, not a reason to change the Studio
result).
