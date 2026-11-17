# SmartRoom carry on omarchy-mac-installer

`smartroom/main` is what SmartRoom Firmware builds and installs its Mac Studio
image with: omacom's `main` (mirrored here as `main`, fast-forward only) plus
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
| 2 | `image-builder`: `build-mac-image --smartroom DIR` (one profile switch; every hunk is `profile == smartroom`), plus `mac-image-check payload --os-name` and the `smartroom` profile, `finalize-root --headless`, `package_record.py --local-repository/--not-installed` | Builds the headless image from the same stable channel record as Omarchy's: no `omarchy`/`omarchy-settings`/desktop lists; our `omarchy-mac-boot` and `smartroom-omarchy-helpers` from a signed local repo; `omarchy-apply-system` replaced by the two runtime steps the boot chain needs (`install/config/snapper.sh`, the hardware deferral with `platform-setup.sh`, both the runtime's own code); no owner provisioning, Plymouth splash or display manager; the room layer runs as `setup/run` before the initramfs; the picker/stub/Limine name is "SmartRoom Firmware"; the ESP carries `omarchy/install.conf` `encrypt=0`. The Omarchy release inspection (which holds the desktop runtime) is skipped for this profile; `smartroom/desk-check` and omarchy-mac-boot's own `omarchy-apple-silicon-boot-check` check the boot chain instead. The stock build is unchanged (the builder's own `image-builder/test/all` passes). | Partly: "build-mac-image: a headless profile without the desktop runtime" could be offered to omacom as a draft once rooms prove it | omacom ships a headless profile |
| 3 | `smartroom/`: `room/` (package list, Apple-list drops, overlay exclusions, `setup-run`), `build-packages`, `build-image`, `desk-check`, `mac/install-onto-existing-stub`, `mac/engine-install` (+ `docs/`) | Our layer and tooling only; nothing upstream reads it | No (ours) | Never |

### Not carried (brief task 3f)

None of the old SmartRoom boot changes come along: no U-Boot `bootdelay`
patch, no own mkinitcpio `HOOKS`, no copied `asahi` hook, no own `limine.conf`
template or hash-less menu, no `panic=10`, `intel_iommu`, `iommu=pt` or
`pm_async=off`. `smartroom/room/overlay-exclude` keeps every such file of our
overlay out of the image; Omarchy's are used unchanged. Nothing yet shows that
upstream misbehaves headless without one; if the Studio test does, it becomes
a listed carry patch with its evidence.

### Files of ours that override one of Omarchy's

None at the file level: the room layer installs only paths Omarchy does not
ship. Two of Omarchy's *settings* are set by the image instead of the
installer app: `TARGET_OS_NAME` in `/etc/default/limine` (kept by our
omarchy-mac-boot patch) and `omarchy/install.conf` on the ESP (Omarchy's own
encryption switch, `encrypt=0`). The installed `/etc/localtime` is
America/Chicago (the room setup), not the builder's UTC.

## Building

On an aarch64 Arch Linux host with Docker (studio-build):

```sh
image-builder/bin/mac-image-inputs resolve INPUTS --channel-set --channel stable --release-tag v4.5.0 \
  --recovery-app REC --cache CACHE            # REC: esp/aurora/recovery from the official stable zip
image-builder/bin/build-mac-image --inputs INPUTS --recovery-app REC --cache CACHE OUT       # stock (baseline)
SMARTROOM_PKG_KEY=<fpr> smartroom/build-packages PKGS                                      # our two packages
smartroom/build-image --inputs INPUTS --recovery-app REC --cache CACHE --packages PKGS \
  --firmware omarchy-base [--firmware-repo BUNDLE] --keys AUTHORIZED_KEYS OUT              # SmartRoom
sudo smartroom/desk-check OUT/*.zip WORKDIR
```

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
