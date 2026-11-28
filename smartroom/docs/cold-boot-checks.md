# Cold-boot checks on a Studio

The image to install is a published release whose `desk-check` passed: the firmware repository's `release-dev` workflow builds it with `smartroom/build-packages`, `smartroom/build-image` and `smartroom/desk-check` (ludagoo/smartroomcontrollerfirmware, `.github/workflows/release-dev.yml`). Never install an image from before the zero-touch fixes (Limine checksums on, or `panic=10` missing); `desk-check` fails such an image. The install note is [install-zoom-room.md](install-zoom-room.md).

## Cold-boot checks

Three checks, each a one-shot Linux boot (`smartroom-boot-os firmware --once --reboot`) on a test Studio, whose default start stays macOS. After each boot, `smartroom/hardware/studio-state-report` (as root on the Studio) shows the kernel command line, the units, the network, the compositor and the Room Controller. `panic=10` stays on the kernel command line. Do not change network settings, sshd, or the Room Controller as part of a check.

### A. Boot with no screen

Reboot with nothing on the HDMI and USB-C ports. Pass when the desktop is up and the Room Controller is online.

### B. Network unplugged at boot

Pass when boot does not wait for the network, the desktop comes up, and the room registers again by itself when the link returns. `smartroom/hardware/studio-netsim arm` simulates it: the wired interface is unmanaged for the next boot only, through a drop-in in `/run`, and handed back after a few minutes. That does not prove the Ethernet PHY's own link-up with a real cable.

### C. Crash, then reboot

Confirm `kernel.panic = 10` and `panic=10` in `/proc/cmdline`, then trigger a panic. Pass when Linux comes back on the same one-shot boot and the filesystem replays cleanly.

A real power cut is a site procedure. It is not part of this repository.
