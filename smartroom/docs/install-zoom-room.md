# Install SmartRoom Firmware on a 2023 Mac Studio

Put SmartRoom Firmware beside macOS. macOS keeps a volume. SmartRoom Firmware is the container the engine creates. Which image is current, host names, and MDM preparation are per install and are not in this repository.

## Tools

| Tool | Role |
|---|---|
| `smartroom/mac/engine-install` | Shrinks macOS and installs the image. See [engine-headless.md](engine-headless.md). |
| `smartroom/mac/smartroom-boot-os` | Switches the default between SmartRoom Firmware and macOS. |
| `smartroom/mac/remove-firmware` | Removes the SmartRoom Firmware container. |
| `smartroom/hardware/build-edge-image` | Builds an image. The one to install is the one whose desk-check passed. |
| [cold-boot-checks.md](cold-boot-checks.md) | The build recipe and the three cold-boot checks. |
| [recovery-app.md](recovery-app.md) | The recovery app branded for the image. |

## Disk split

When the install shrinks macOS, macOS keeps only the engine's minimum, which already includes the installer's own reserve. Confirm the split in `engine-install` before a visit.

## One-time macOS steps

The first install uses 1TR (Startup Options). The person at the Mac holds the power button, chooses Options, and allows the security change the stub asks for. That password is never written into a document in this repository.

Remote Login for the admin account is on before a remote install. FileVault, a firmware password, and any lock an MDM holds are cleared before the visit. How a site clears them is not documented here.

## What not to do

- Do not pipe a download into a shell.
- Do not install an image from before the zero-touch fixes (Limine checksums on, or `panic=10` missing).
- Do not run `pacman -Syu` on a room. Updates are whole releases (`smartroom-release`).
- macOS stays the persistent startup volume unless the room is switched on purpose (`smartroom-boot-os`). A Linux trial is a one-shot.

## After install

First boot reads `firstboot.env` from the ESP (`SMARTROOM_SERVER_URL`, https only, and `SMARTROOM_AGENT_INSTALL_SHA256`). A production server needs `--production` on `engine-install`, which sets `SMARTROOM_PRODUCTION=1`. The room registers as pending until ops adopts it.
