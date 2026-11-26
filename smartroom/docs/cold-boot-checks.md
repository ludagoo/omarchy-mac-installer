# Building an edge image and checking a cold boot

The image to install is the one whose desk-check passed. Rebuild it with `smartroom/hardware/build-edge-image`. Do not install an image from before the zero-touch fixes (Limine checksums on, or `panic=10` missing). The install note is [install-zoom-room.md](install-zoom-room.md).

## Build

ARM builds happen only on a native aarch64 build host. Pin three commits and run:

```
smartroom/hardware/build-edge-image INSTALLER_SHA PKGS_SHA FIRMWARE_SHA
```

It builds `aura`, `linux-aurora` and `mesa-aurora` (with `vulkan-aurora`), makes the SmartRoom package repo (`smartroom/build-packages`), makes the image (`smartroom/build-image`) and runs `smartroom/desk-check` on it. It stops at the first failed check. The desk-check is the gate: it has to pass, including the line "Mesa opens the kernel's GPU driver (aurora)" and the line from `smartroom/ac-power-check` that says the power-on-after-power-loss unit is in the image.

## Cold-boot checks

Three checks, each a one-shot Linux boot. macOS stays the persistent default. `panic=10` stays on the kernel command line. Do not change network settings, sshd, or the Room Controller as part of a check.

### A. Boot with no screen

Reboot with nothing on the HDMI and USB-C ports. Pass when the desktop is up and the Room Controller is online.

### B. Network unplugged at boot

Pass when boot does not wait for the network, the desktop comes up, and the room registers again by itself when the link returns. A simulation may mark the wired interface unmanaged for the next boot only, through a drop-in in `/run`, and hand it back after a few minutes. That does not prove the Ethernet PHY's own link-up with a real cable.

### C. Crash, then reboot

Confirm `kernel.panic = 10` and `panic=10` in `/proc/cmdline`, then trigger a panic. Pass when Linux comes back on the same one-shot boot and the filesystem replays cleanly.

A real power cut is a site procedure. It is not part of this repository.
