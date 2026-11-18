# SmartRoom carry on omarchy-mac-installer

`smartroom/edge` (this branch) is `smartroom/main` at `ea01d43` plus the edge
boot chain. `smartroom/main` stays the stable line: m1n1-aurora, kernel 7.2,
the smartroom-3 image. Do not merge this branch back into `smartroom/main`.

On this branch the SmartRoom image is built from the Omarchy **edge** channel,
not stable. The channel's published edge database (2026-11-18) is still kernel
7.2.11 and m1n1-aurora. Kernel 7.3 and aura-as-bootloader exist only on the
draft pin omarchy-pkgs#3025 (`1102a177`, branch `pin/edgeB2`). This image
therefore installs `aura` and `linux-aurora` from the signed SmartRoom repo,
in place of the channel's `m1n1-aurora` and `linux-aurora`. The kernel
package is ludagoo/linux `b6d00c75` (7.3.0 plus the t6021 encoder stack),
not omacom/linux-aurora `4454eda`: those encoder commits do not cherry-pick
cleanly onto the pin. The package name
`aura` stays in `policy.json`'s refused list. The builder allows it only when
the resolved package comes from the SmartRoom repo.

A SmartRoom image does not install `omarchy-settings`, and the helpers
package only carries the stable pacman template. On edge, the installed
`/etc/pacman.conf` is the edge template from the settings package the build
already accepted (`aarch64-apple/pacman-edge.conf` and its mirror list).
A template already on the root still wins, so a stable image keeps the
helpers' stable files.

The pinned Engine enrolls a **raw** first stage (`kmutil configure-boot --raw
--entry-point 2048`). It overwrites asahi's m1n1 stage 1 with
`esp/aurora/stage1.bin` only when `installer_data.json` carries
`aurora_stage1.kind = common-raw-v1` and lists that Mac. This image qualifies
`j475cap` on OS firmware `13.5` only. The next object stays `m1n1/boot.bin`.
Stage 2 on the ESP is aura's `ESP_STAGE2` build, concatenated the way
`update-m1n1` already concatenates `usr/lib/asahi-boot/m1n1.bin`. Desk-check
requires the string `aura-try` in both, because m1n1-aurora also ships a file
at `usr/share/aura/stage1/aura-raw.bin` and that file is m1n1.

Zero-touch settings (Limine checksums off, `panic=10`) and the disk-split
default (macOS keeps its minimum + 20 GiB when the install shrinks macOS)
come along from `smartroom/main`. They are unchanged here.

`smartroom/main` is what a stable SmartRoom Firmware image builds with:
omacom's `main` (mirrored here as `main`, fast-forward only) plus
the patches below, rebased, never merged. The bottom layers are Omarchy's,
copied, and changed only where a headless room needs it: the image builder,
the Engine, omarchy-mac-boot (from ludagoo/omarchy-mac-pkgs `smartroom/main`)
and the boot chain (m1n1-aurora, uboot-aurora, Limine, linux-aurora, the
initramfs, vendor firmware, snapshots). The top layer is only ours: Hyprland,
Omarchy's Chromium, the room package list and the room's own files.

## Base

| | |
| --- | --- |
| Base commit | `c07e54c2134a8ec1415e7e2b917589ae1d3d7dc9` (omacom main, "Merge pull request #190 … pins/app-2.3.16"). Its `image-builder/` is byte-identical to `ddea08e4`, which built the published stable image `omarchy-mac-4.5.0-r2-2026.11.05`. |
| Channel | stable, `v4.5.0` (`pkgs.omarchy.org/stable`, `arm-stable-mirror.omarchy.org`) |

## Carried patches

| # | What | Why | Upstream PR candidate? | Drop when |
| --- | --- | --- | --- | --- |
| 1 | `CARRY.md`, `smartroom/sync-upstream.sh` | This file and the sync script | No (ours) | Never |
| 2 | `image-builder`: `build-mac-image --smartroom DIR` (one profile switch; every hunk is `profile == smartroom`), plus `mac-image-check payload --os-name` and the `smartroom` profile, `finalize-root --headless`, `package_record.py --local-repository/--not-installed` | Builds the headless image from the same stable channel record as Omarchy's: no `omarchy`/`omarchy-settings`/desktop lists; our `omarchy-mac-boot` and `smartroom-omarchy-helpers` from a signed local repo; `omarchy-apply-system` replaced by the two runtime steps the boot chain needs (`install/config/snapper.sh`, the hardware deferral with `platform-setup.sh`, both the runtime's own code); no owner provisioning, Plymouth splash or display manager; the room layer runs as `setup/run` before the initramfs; the picker/stub/Limine name is "SmartRoom Firmware"; the ESP carries `omarchy/install.conf` `encrypt=0`; `/etc/limine-entry-tool.d/zz-smartroom-firmware.conf` sets `ENABLE_VERIFICATION=no` (limine-entry-tool loads that directory after `/etc/limine-entry-tool.conf`, which ships `yes`, and before `/etc/default/limine`), so `limine.conf` has no file checksums. It cannot live in `/etc/default/limine`: first boot's `limine-boot.sh` rewrites that file and keeps only `TARGET_OS_NAME`. `GRUB_CMDLINE_LINUX_DEFAULT` gains `panic=10` (reboot 10s after a kernel panic); `grub-console.sh` rewrites `GRUB_CMDLINE_LINUX` only, and `omarchy-mac-limine-cmdline` copies the default line into the UKI command line, including when first boot derives it again (on 2026-11-18 the Studio's kernel file changed after its checksum was written, and Limine 12.9.3 stopped at "Press Y to continue" with no screen or keyboard: `uri_hash_mismatch()` waits for a key when `hash_mismatch_panic: no` and panics to a prompt when `yes`). The setup tree is handed to root (`chown -R 0:0`) as it enters the image root: it comes from the host's build user (uid 1000, which is the room's own user in the image). The Omarchy release inspection (which holds the desktop runtime) is skipped for this profile; `smartroom/desk-check` and omarchy-mac-boot's own `omarchy-apple-silicon-boot-check` check the boot chain instead. The stock build is unchanged (the builder's own `image-builder/test/all` passes). | Partly: "build-mac-image: a headless profile without the desktop runtime" could be offered to omacom as a draft once rooms prove it | omacom ships a headless profile |
| 3 | `smartroom/`: `room/` (package list, Apple-list drops, overlay exclusions, `owner-allow`, the AQC113 wired profile, `setup-run`), `build-packages`, `build-image`, `desk-check`, `recovery-branding`, `mac/engine-install`, `mac/remove-firmware`, `mac/smartroom-boot-os`, `mac/install-onto-existing-stub`, `mac/build-recovery-app`, `test/` (+ `docs/`, among them `install-zoom-room.md` and `recovery-app.md`) | Our layer and tooling only; nothing upstream reads it | No (ours) | Never |
| 4 | `Recovery/`: SmartRoom Firmware branding of the native Recovery app that 1TR runs ("Finish setup"). Three new files: `Sources/SmartRoomBrand.swift` (every shown name), `Sources/SmartRoomWordmark.swift` (the banner, same 400 × 94 frame), `Sources/SmartRoomSnapshots.swift` (preview builds only: `--smartroom-snapshots DIR` saves every screen). One-line hunks: the shown strings in `main.swift`, `InstallerView.swift`, `EnrollmentGate.swift`, `AuthorizationPrompt.swift`, `RecoveryActions.swift`, `RecoveryOwner.swift`, `Account/RecoveryAccountCore.swift` (the recovery account's full name), the preview hook in `main.swift`; `CFBundleName` in `build-app.sh` and `Resources/en.lproj/InfoPlist.strings`; `build-app.sh` puts the MIT `LICENSE` in the bundle; `test-all.sh` compiles `SmartRoomBrand.swift` into each fixture; `Tests/AuthorizationPromptCheck.swift` expects the new prompt. Layout, sizes, colours and flow are upstream's. | Techs installing a room see this app in 1TR (and hear it with VoiceOver); it must say SmartRoom Firmware, not Omarchy. Kept on purpose, because the pinned Engine (`omarchy_recovery.validate_source`), the image builder (`recovery_app.py`) and the stub layout match on them and none is drawn: the bundle `<INSTALLER_RECOVERY_APP_NAME>.app`, its `CFBundleDisplayName` (Engine contract, see [recovery-app.md](smartroom/docs/recovery-app.md#what-still-says-omarchy)), the executable `OmarchyRecovery`, the bundle identifier, `OmarchyRecoveryBuildMode`, the `Omarchy*` type names and the `Aurora/`/`omarchy-*` paths. | Partly: "make the Recovery app's product name a build setting" (one constant, and the Engine reading the display name from the manifest instead of a literal) | omacom makes the Recovery app's name configurable |

### Not carried (brief task 3f)

None of the old SmartRoom boot changes come along: no U-Boot `bootdelay`
patch, no own mkinitcpio `HOOKS`, no copied `asahi` hook, no own `limine.conf`
template, no `intel_iommu`, `iommu=pt` or `pm_async=off`. `panic=10` is
carried now (patch 2), as one word on `GRUB_CMDLINE_LINUX_DEFAULT`, which
first boot does not rewrite. `smartroom/room/overlay-exclude` keeps every such
file of our overlay out of the image (including `etc/limine-entry-tool.d/*`
and `etc/sysctl.d/10-smartroomos-panic.conf`); Omarchy's are used unchanged,
and the checksum switch uses a new drop-in name so it is not that excluded
file. Nothing yet shows that upstream misbehaves headless without one; if the
Studio test does, it becomes a listed carry patch with its evidence. That
happened twice: the hash-less menu (patch 2, the drop-in
`ENABLE_VERIFICATION=no`, 2026-11-18; first boot's rewrite of
`/etc/default/limine` would drop it) and `panic=10`.

### Files of ours that override one of Omarchy's

None at the file level: the room layer installs only paths Omarchy does not
ship. Checked on the built image (`pacman -Qo` on every room file): no file of
an Omarchy package (omarchy-mac-boot, the Aurora boot set, smartroom-omarchy-helpers)
is overwritten. Our room files that replace someone else's:

- package defaults: `/etc/greetd/config.toml` (greetd: autologin into the
  kiosk session), `/etc/hosts` (filesystem: the same two localhost lines),
  `/etc/locale.gen` (glibc: en_US.UTF-8, as the builder also sets);
- files Omarchy's builder writes (`builder/finalize-root`): `/etc/locale.conf`
  (identical), `/etc/vconsole.conf` (`KEYMAP=us`, the builder's has the same
  keymap plus XKB lines), `/etc/localtime` (America/Chicago instead of UTC).

Two of Omarchy's *settings* are set by the image instead of the installer
app: `TARGET_OS_NAME` in `/etc/default/limine` (kept by our omarchy-mac-boot
patch), `ENABLE_VERIFICATION=no` in
`/etc/limine-entry-tool.d/zz-smartroom-firmware.conf` (the file first boot
does not rewrite), `panic=10` on `GRUB_CMDLINE_LINUX_DEFAULT`, and
`omarchy/install.conf` on the ESP (Omarchy's own encryption
switch, `encrypt=0`). The room setup also masks `NetworkManager-wait-online`,
as stock Omarchy's desktop setup does.

## Building

On an aarch64 Arch Linux host with Docker (studio-build):

```sh
image-builder/bin/mac-image-inputs resolve INPUTS --channel-set --channel stable --release-tag v4.5.0 \
  --recovery-app REC --cache CACHE            # REC: OUT/recovery of smartroom/mac/build-recovery-app (patch 4)
image-builder/bin/build-mac-image --inputs INPUTS --recovery-app REC --cache CACHE OUT       # stock (baseline)
SMARTROOM_PKG_KEY=<fpr> smartroom/build-packages PKGS                                      # our two packages
smartroom/build-image --inputs INPUTS --recovery-app REC --cache CACHE --packages PKGS \
  --firmware omarchy-base [--firmware-repo BUNDLE] --keys AUTHORIZED_KEYS OUT              # SmartRoom
sudo smartroom/desk-check OUT/*.zip WORKDIR
bash smartroom/test/all                                                                   # our tools' tests
```

`desk-check` fails on any file under `/etc`, `/usr` or `/opt` of the image
owned by a non-root user or a user group (gid >= 1000) that
`smartroom/room/owner-allow` does not list (it lists nothing), and runs
`visudo -c` in the image. It also fails if the image's Recovery app
(`esp/aurora/recovery`) is not the SmartRoom build or still shows Omarchy
(`smartroom/recovery-branding app`).

The Recovery app is the one input built on a Mac (Swift/AppKit):
`smartroom/mac/build-recovery-app --screens OUT` builds it from this checkout,
checks it as the image builder and the pinned Engine will, and saves every
screen ([recovery-app.md](smartroom/docs/recovery-app.md)). Its manifest
digest (`OUT/recovery.sha256`) is the inputs' `recovery_app_manifest_sha256`:
resolve with `--recovery-app OUT/recovery`, or, to keep a release's channel
inputs, copy its inputs file and replace only that line.

### Patch 4 on an upstream sync

1. Rebase. A conflict in patch 4 is a one-line string: take upstream's new
   wording and put `SmartRoomBrand.osName`/`.appName` where it names the
   product.
2. `python3 smartroom/recovery-branding source` (also in `smartroom/test/all`)
   lists every Omarchy/Aurora string literal upstream added to
   `Recovery/Sources`. Brand it the same way, or, if it is only a path or an
   identifier that never reaches the screen, add it to `INTERNAL_LITERALS`
   there.
3. If upstream changed the Engine's Recovery contract (`omarchy_recovery.py`:
   `APP_NAME`, the `CFBundleDisplayName` check), follow it; never brand those.
4. On a Mac: `smartroom/mac/build-recovery-app --screens OUT`, look through
   `OUT/screens`, then build the image with `OUT/recovery` and desk-check it.

## Branches

- `main`: an exact mirror of omacom's `main`. Fast-forward only, never commit to it.
- `smartroom/main`: `main` + the carry above. Rebased, never merged. Before
  force-pushing it, tag the old tip `sr/prev-<date>`; never delete `sr/*` tags.

## Syncing with upstream

```sh
smartroom/sync-upstream.sh            # fast-forward main, show how far behind the carry is
smartroom/sync-upstream.sh --rebase   # rebase smartroom/main locally, print the range-diff
smartroom/sync-upstream.sh --push     # tag sr/prev-<date> and force-push
```

After a sync: `bash image-builder/test/all` (stock path), then build both
images and desk-check them. Patch 2 is the one most likely to conflict: it
touches the builder's package phases and `configure_image`; resolve by keeping
every SmartRoom hunk behind `profile == smartroom`.

GitHub Actions are disabled on this fork: none of the inherited workflows
(`mac-image`, `mac-upload`, `mac-catalog-sign`, `mac-promote`, `mac-app-release`
and the rest) can build, sign, notarize or publish anything from here.

## Rules

- Patches by an AI agent carry `Assisted-by: Claude:claude-opus-5-5` and no
  `Signed-off-by`. Upstream PRs go to omacom only (never AsahiLinux), and only
  as drafts Lucas reviews and sends.
