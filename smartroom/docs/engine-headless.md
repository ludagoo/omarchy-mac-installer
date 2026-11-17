# Headless engine install: smartroom/mac/engine-install

`smartroom/mac/engine-install` installs a locally built OS image (the image builder's zip and `installer_data.json`) on an Apple Silicon Mac from macOS, over SSH, with no GUI, no Swift app and no signed catalog. It runs the installer's pinned Python Engine the way the app does (`Sources/OmarchyAppleInstaller/PinnedAsahiEngineExecutor.swift`): inspect, plan, install, with the same environment, input files, file modes and digests. Then it writes the new ESP's `omarchy/install.conf` the way the app does (`InstallConf.swift`, `InstallConfESP.swift`, `LiveInstallerEnvironment.swift` `recordInstallConf`). It ends where the app ends: the engine journal's `completion` is `awaiting_recovery`, and a person must finish step 2 in the Mac's own Recovery (1TR).

It reimplements nothing the engine does. The engine still inspects the Mac, computes the inventory and the plan, admits the plan, checks the decoder's signature, validates the payload, partitions, writes, stages Recovery and blesses. The driver only prepares the inputs the app would, picks a candidate (the app's UI step), and checks early a few preconditions the engine would otherwise only hit after it has started.

`Sources/OmarchyCanaryPhysicalTool/main.swift` is the precedent: a root command-line driver of the same executor. It also uses its own trust fingerprint, sequence and identity digest in place of a catalog, and the same binding digest formula.

This is a reviewed draft. Nothing here has run on a Mac yet; see [What is unverified](#what-is-unverified).

## Which engine

The driver uses the engine `Engine/source-lock.json` pins: `v0.9.2-omarchy.20261106.0f73bea79639`, `installer-v0.9.2-omarchy.20261106.0f73bea79639.tar.gz`, 17,904,144 bytes, SHA-256 `a60855716be5cea4f2113a368f784a5fe55a7034602f48fac8bb6e79f796fd7a`. It reads the lock at run time and never hard-codes the digest (`Engine/tests/test_engine_pin.py` forbids copies). If `--engine` is not given, it downloads the archive from `https://mac.omarchy.org/v1/engine/<version>/<file>`. The object is published: a HEAD request on 2026-11-17 returned 200 and 17,904,144 bytes. The driver checks size and SHA-256 before every use.

Why this engine and not the stable catalog's `v0.9.2-omarchy.20261022.31425f17fb9b` (SHA-256 `5fea6b56…d4b5`, the engine app 2.3.15 runs on the stable channel today):

- Its sources are the ones in this checkout. Every overlay file and the patch match the lock's digests, and the driver was reviewed against them.
- 20261022 fails Recovery staging for images with `recovery_gui: omarchy-native-v1`, and fails after it has already partitioned the disk. macOS AppleDouble `._*` sidecars on the FAT ESP break the Recovery app's inventory check. This is fixed in `b1d3ef2` (#176, #177), and `Development/Removal.md` names those failed journals. SmartRoom images declare native Recovery.
- 20261106 also writes the partition receipt (`<journal>.partitions.receipt`) and the ESP records before Recovery staging (`aef22bb`, `d7d98d9`). Removal relies on them after an interrupted install.
- It is the engine of the edge catalog and of app 2.3.16 (`.github/mac-release-pipeline.json`), and its `minimum_app_version` is 2.3.0, so any 2.3.x app's restore-image helper matches its contract.

To run another engine, point `--repo` at a checkout whose `Engine/source-lock.json` pins it. For example, `git show 32fe594:Engine/source-lock.json` is 20261022's lock, but do not use it for native-Recovery images.

## Before you start (on the Mac)

1. **A machine owner logged in at the console.** The engine refuses to run otherwise, in every mode. See [The console user](#the-console-user-running-over-ssh).
2. **`--owner`** is the macOS short name whose password goes on stdin. It must be an administrator listed in the booted macOS's `Preboot/<group>/var/db/AdminUserRecoveryInfo.plist`, and an APFS volume owner (secure token). The engine stages native Recovery for that owner (`omarchy_recovery.source_bootstrap`) and blesses with it. Normally this is the same user as the console user.
3. **Space.** You need a free extent of at least the stub (2.5 GB) plus the image's partitions (500 MiB + 2 GiB + 32 GiB). By default the driver takes the single largest `free` candidate the engine reports, all of it. `--size N` (bytes, or `N` with `M`/`G`/`T` for MiB/GiB/TiB) takes less. `--source diskNsM --size N` shrinks that macOS container instead (`resize`). The driver refuses when two free extents are equally large, when no free extent fits, or when the engine reports an existing Omarchy install (`replace`), unless you pass `--source`. The old `SmartRoomOS` stub on the home Studio is not reported as `replace` (its name and ESP label differ). For a fresh install, its stub, ESP and Linux partitions must be deleted first, or macOS shrunk. That is the owner's decision; the driver never deletes partitions.
4. **The restore-image helper** (`omarchy-restore-image`, the app's signed Swift decoder). Install mode refuses to start without it, even on Macs that never run it. See [The restore-image helper](#the-restore-image-helper).
5. **Files from this repository**, at the same relative paths: `smartroom/mac/engine-install`, `Engine/source-lock.json`, `Packaging/identity.conf`. Use `--repo DIR` to name the directory that holds `Engine/` and `Packaging/`.
6. **The image.** The zip must keep the exact file name that `installer_data.json`'s `package` names; the engine refuses any other name. You also need its SHA-256, which `PROVENANCE`'s `payload=` line records. The engine checks no payload signature: it binds the payload only by `payload_digest` in the plan digest.
7. **Network.** The engine fetches the parts of Apple's IPSW it needs from Apple's CDN (macOS 13.5 firmware for M1 and M2 Macs), and the driver may fetch the engine.

## The console user (running over SSH)

Upstream `src/system.py` (asahi-installer v0.9.2, `dffbb38e`) runs `scutil` with `show State:/Users/ConsoleUser` and takes the last `kCGSSessionUserNameKey` that is not `_mbsetupuser` as `login_user`. Upstream `src/main.py` `InstallerMain.main()` then exits 1 with "Could not detect logged in user. Perhaps you are running this installer over SSH?" when booted into macOS and `login_user` is empty or `unknown`. The engine patch keeps this check. It runs right after the engine's `inspection` record, so `inspect`, `plan` and `install` all exit 1 without a console session. No environment flag in the patch or the overlay bypasses it. `EXPERT` is refused in engine mode and would not bypass it either.

A second check matters later. The engine's `prepare_target` calls upstream `check_cur_os()`, which requires `login_user` to be in the booted macOS's `AdminUserRecoveryInfo.plist`. It first tries `diskutil apfs updatePreboot`, then exits 1. That happens after the journal's first `apfs_preparation_started` event, which would leave a journal that resumes as ambiguous. The app never meets either check, because it always runs in a GUI session.

**Resolution: meet the check; don't patch it.** The check reads machine state (the console session), not anything about the calling process. SSH works as long as someone is logged in at the console. The driver checks the same `scutil` key first, and checks that both the console user and `--owner` are in the Preboot admin list and that `--owner` has a secure token. If any check fails, it stops with an explanation. On a headless Mac:

- Automatic login for the owner, then reboot: System Settings, Users & Groups, Automatically log in as, or `sudo sysadminctl -autologin set -userName OWNER -password -` (unverified). This needs FileVault off; `fdesetup status` shows it. Turn it off again afterwards with `sudo sysadminctl -autologin off`.
- Or log in once through Screen Sharing (VNC) from another Mac and leave the session open.
- Check from SSH: `scutil <<< 'show State:/Users/ConsoleUser'` must list `kCGSSessionUserNameKey : OWNER`.

Rejected: putting a fake `scutil` first on the engine's `PATH` (the bundle's `bin/`). It would satisfy both checks without changing the engine archive's bytes, but it forges the state the engine authenticates against.

## The restore-image helper

Since 2.3.0 the engine does not carry the decoder. In install mode, `omarchy_runtime.EngineRuntime.from_environment` calls `omarchy_apple_aea.decoder`, which needs these before any disk change:

- `OMARCHY_RESTORE_IMAGE`: an absolute path to a regular file, not group or other writable, executable by its owner.
- `OMARCHY_RESTORE_IMAGE_REQUIREMENT`: a string that matches one of two exact forms (`omarchy_apple_aea.REQUIREMENT`). The file must pass `/usr/bin/codesign --verify --strict -R=<requirement>`. The two forms are:
  - Developer ID: `anchor apple generic and identifier "ID" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "TEAM"`
  - ad hoc: `identifier "ID" and cdhash H"<40 or 64 hex>"`

For a Mac Studio M2 Max on macOS 14.5, the engine picks macOS 13.5 OS firmware, which is not AEA encrypted. So the decoder is only signature-checked and never run. It does run for macOS 26 firmware (MacBook Neo, M3 Airs on 26.6.2).

**Official source.** The app ships the helper at `Omarchy Installer.app/Contents/Helpers/omarchy-restore-image` (`RestoreImageHelper.bundledURL`), signed by `Packaging/release/sign-app` with identifier `org.omarchy.installer.restore-image` and team `T2C384FJBD` (`Packaging/identity.conf`). The release DMG has volume name `Omarchy Installer` and holds the app beside an `/Applications` link (`Packaging/release/sign-and-package`). For app 2.3.16, the DMG is `https://mac.omarchy.org/v1/installer/2.3.16/Omarchy-Mac-Installer-2.3.16.dmg` (25,538,902 bytes, SHA-256 `0b70717b0bfa3277f41159b5de4a0cab9f75dda9ba64f13d4b4a02a7860dd027`):

```sh
curl -fLo /tmp/Omarchy-Mac-Installer-2.3.16.dmg https://mac.omarchy.org/v1/installer/2.3.16/Omarchy-Mac-Installer-2.3.16.dmg
echo "0b70717b0bfa3277f41159b5de4a0cab9f75dda9ba64f13d4b4a02a7860dd027  /tmp/Omarchy-Mac-Installer-2.3.16.dmg" | shasum -a 256 -c
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint /tmp/omarchy-dmg /tmp/Omarchy-Mac-Installer-2.3.16.dmg
helper="/tmp/omarchy-dmg/Omarchy Installer.app/Contents/Helpers/omarchy-restore-image"
codesign -d -r- "$helper"          # designated requirement, for the record
codesign -dv --verbose=4 "$helper" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|CDHash)='
```

**Deriving the requirement.** `codesign -d -r-` prints the designated requirement. For a Developer ID build that is `anchor apple generic and identifier "org.omarchy.installer.restore-image" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = T2C384FJBD)`. The engine does not accept that string verbatim, because it matches only the two forms above. The driver therefore does what the privileged helper does (`RestoreImageHelper.developerIDRequirement(team:)`, the same string `sign-app` uses). It reads `Identifier=` and `TeamIdentifier=` from `codesign -dv --verbose=4`, requires `org.omarchy.installer.restore-image` and `T2C384FJBD` from `Packaging/identity.conf`, builds the Developer ID form, and runs `codesign --verify --strict -R=` itself. If the helper is ad hoc signed (`Signature=adhoc`), it builds the cdhash form from `CDHash=`, as `Packaging/build-developer-pkg.sh` does.

**Fallback without the DMG (unverified).** `Engine/RestoreImage/bin/omarchy-restore-image` is the tracked unsigned build. On the Mac, `cp` it, then run `codesign -f -s - -i org.omarchy.installer.restore-image COPY` and pass `--restore-image COPY`. The driver pins it by cdhash. That is enough wherever the decoder is not run.

## The exact commands for an agent

From the machine with the checkout and the image (the image directory holds the zip, `installer_data.json` and `PROVENANCE`):

```sh
ssh MAC 'mkdir -p omarchy-headless/smartroom/mac omarchy-headless/Engine omarchy-headless/Packaging /Users/Shared/smartroom-image'
scp smartroom/mac/engine-install MAC:omarchy-headless/smartroom/mac/
scp Engine/source-lock.json MAC:omarchy-headless/Engine/
scp Packaging/identity.conf MAC:omarchy-headless/Packaging/
scp IMAGE/smartroom-firmware-*-os-package.zip IMAGE/installer_data.json MAC:/Users/Shared/smartroom-image/
sed -n 's/^payload=//p' IMAGE/PROVENANCE      # name|size|sha256
```

On the Mac, fetch and mount the DMG as above. Then run a dry run, which stops after the engine's plan and changes nothing on disk, followed by the install. The owner's password goes on stdin twice: `sudo -S` takes the first line if it needs one, and the driver reads the next. Both lines are the same password when the SSH user is the owner. Feed it from the agent's secret store through a pipe; never put it in an argument:

```sh
cmd='sudo -S -p "" "$HOME/omarchy-headless/smartroom/mac/engine-install" \
  --payload /Users/Shared/smartroom-image/ZIP --sha256 HEX \
  --installer-data /Users/Shared/smartroom-image/installer_data.json \
  --owner OWNER \
  --restore-image "/tmp/omarchy-dmg/Omarchy Installer.app/Contents/Helpers/omarchy-restore-image"'
{ printf '%s\n' "$PW"; printf '%s\n' "$PW"; } | ssh MAC "$cmd"            # dry run
{ printf '%s\n' "$PW"; printf '%s\n' "$PW"; } | ssh MAC "$cmd --yes"      # install
```

`--encrypt 0` (the default) and `--lane stable` (the default) go into `install.conf`. `--full-readback` sets `OMARCHY_FULL_READBACK=1`, which makes the engine read back `root.img` too. The output streams the engine's own output and every journal record (`journal N: event stub_and_esp_started` and so on). Everything is also written to `/var/root/omarchy-engine-install/run-<time>/engine-install.log`. The run ignores SIGHUP and SIGPIPE: if SSH drops, reconnect and `sudo tail -f` that log. Expect tens of minutes; most of it is writing `root.img`.

When it ends, the Mac's startup disk is the new stub (the engine blesses with `--setBoot`, not `--nextonly`). **Do not reboot it from SSH.** A plain start now boots the new OS's Recovery, which has no SSH. A person at the Mac (display or VoiceOver) does step 2, which the driver prints: shut down, hold the power button (on the back of a Studio or mini) until "Loading startup options", choose the new OS, Continue. The native Recovery app ("Finish setup") asks for the owner's password, then Install, then Restart. To go back to macOS instead, choose the macOS disk in startup options and Option-click "Always Use".

## What it does, step by step

| Step | The app | The driver |
| --- | --- | --- |
| Engine archive | Pinned by digest and size (`ValidationEngineArtifact`, catalog) | Lock's `validation_artifact`, checked by size and SHA-256. Entries must not be absolute or contain `..`. |
| Unpack | `<parent>/engine-execution-<uuid>/bundle`, 0700, `tar -xzf --no-same-owner --no-same-permissions`, a fresh copy per run | The same, under the run directory, per engine run. Its `installer.log` is kept as `<mode>-installer.log`, then the copy is removed. |
| Process | `bundle/Frameworks/Python.framework/Versions/3.13/bin/python3.13 bundle/main.py`, cwd `bundle`, the whole environment replaced, stdout to /dev/null, stderr captured | `env -i` with the same variables, cwd `bundle`. stdout and stderr go to the terminal and the log. |
| inspect | Runs as the GUI user. Journal `engine-execution-*/transcript.jsonl`; stdin /dev/null | Runs as root; otherwise the same. Kept as `inspect.jsonl`. |
| Candidate | The user and `InstallerAllocationRecommendation` | The largest `free` candidate, or `--source`/`--size`. Refuses ties and existing installs. |
| plan | `engine-plan-input-<uuid>/request.json` and `identity.json` (0400, sorted compact JSON) | `plan-input/request.json` and `identity.json`, 0400. Kept as `plan.jsonl`. |
| Handoff | Helper imports the package into a root-only directory: payload, metadata and engine 0400, decoder 0500, `request.json` and `identity.json` 0400 | `package/`: 0700, payload clone (`cp -c`) and `installer_data.json` 0400, `omarchy-restore-image` 0500, `request.json` and `identity.json` 0400. Payload SHA-256 is checked on the private copy. |
| install | `execution-journals/<binding hex>.jsonl` (0600, created first), umask 077, stdin = password + `\n`, then EOF | The same; stdin from the shell builtin `printf`. |
| Retry | `retry-recovery-authorization` with the same package and journal | `--retry RUN_DIR --yes` |
| install.conf | Helper finds the one ESP named `EFI - OMARC` inside the plan's extent on the plan's store; writes `format=1`, `encrypt=0/1`, `lane=…` atomically; reads back; unmounts | The same, but with the ESP label taken from the image's name: `EFI - SmartRoom Firmware` truncated to 11 characters is `EFI - Smart`, compared case-insensitively. The app's fixed `EFI - OMARC` would never match a SmartRoom image. A failure is fatal here, because without the file first boot defaults to encrypting. |

The driver uses the engine's own Python for its JSON, digest and plist steps, never the system's.

## Environment of the engine

Every run gets the base environment from `PinnedAsahiEngineExecutor.environment`, with nothing else inherited:

| Variable | Value |
| --- | --- |
| `HOME`, `TMPDIR` | the execution root `run-*/engine-execution-<uuid>` |
| `PATH` | `<bundle>/bin:/usr/bin:/bin:/usr/sbin:/sbin` |
| `LC_ALL`, `LANG` | `C` |
| `DYLD_LIBRARY_PATH` | `<bundle>/Frameworks/Python.framework/Versions/Current/lib` |
| `DYLD_FRAMEWORK_PATH` | `<bundle>/Frameworks` |
| `SSL_CERT_FILE` | `<bundle>/Frameworks/Python.framework/Versions/Current/etc/openssl/cert.pem` |
| `OMARCHY_ENGINE_JOURNAL` | inspect/plan: `<root>/transcript.jsonl`; install: `run-*/execution-journals/<binding hex>.jsonl` |
| `OMARCHY_PERFORMANCE_LOG` | the journal path + `.performance.jsonl` |
| `OMARCHY_ENGINE_MODE` | `inspect`, `plan`, `install` or `retry-recovery-authorization` |

The plan run adds:

| Variable | Value |
| --- | --- |
| `OMARCHY_ENGINE_REQUEST` | `plan-input/request.json`: `schema_version` 1, `layout_digest` (the inspection's), `candidate_kind`, `source_identifier`, `requested_length_bytes` (a multiple of 1 MiB) |
| `OMARCHY_ENGINE_IDENTITY` | `plan-input/identity.json`: `schema_version` 1, `engine_version` (the lock's name), `engine_digest` (`sha256:` + the archive's), `metadata_digest` (`sha256:` of `installer_data.json`'s bytes), `payload_digest` (`sha256:` + `--sha256`) |

Install and retry add:

| Variable | Value |
| --- | --- |
| `OMARCHY_ENGINE_REQUEST` | `package/request.json`: `format` 1, `operation` `install`, then `plan_digest`, `device_identifier`, `store_identifier`, `layout_digest`, `candidate_kind`, `source_identifier`, `offset_bytes`, `length_bytes`, `engine_version`, `required_human_steps`, all copied from the plan record |
| `OMARCHY_ENGINE_IDENTITY` | `package/identity.json`: `format` 1, `binding_digest`, `trust_root_fingerprint`, `catalog_sequence`, `catalog_payload_digest`, `plan_digest`, `engine_digest`, `metadata_digest`, `payload_digest` |
| `OMARCHY_ENGINE_METADATA` | `package/installer_data.json` |
| `OMARCHY_ENGINE_PAYLOAD` | `package/<zip>` (the name must equal metadata `package`) |
| `OMARCHY_ENGINE_BINDING_DIGEST` | the identity's `binding_digest` |
| `OMARCHY_ENGINE_PLAN_DIGEST` | the plan record's `plan_digest` (64 hex digits, no prefix) |
| `OMARCHY_MACHINE_OWNER` | `--owner` |
| `DISTRO`, `OMARCHY_INSTALLER_NAME`, `DISTRO_DOCS` | `Omarchy`, `Omarchy Installer` (`INSTALLER_APP_NAME`), `https://omarchy.org/manual/`, as the app sets them |
| `OMARCHY_RESTORE_IMAGE`, `OMARCHY_RESTORE_IMAGE_REQUIREMENT` | `package/omarchy-restore-image` and its requirement |
| `OMARCHY_FULL_READBACK` | `1` only with `--full-readback` (the app never sets it) |

Never set: `OMARCHY_RECOVERY_APP`, `_MANIFEST`, `_REQUIREMENT`. The app passes these only for images without `recovery_gui` (`NativeRecoveryTemplate.imageNeedsTemplate`), and its template is not available headless. Images without `recovery_gui` fall back to the engine's Terminal step 2. `OMARCHY_ENGINE_REPAIR_MANIFEST` is never set either (no repair).

**Digests.** The engine computes the plan digest itself (`omarchy_contract._canonical_plan_digest`). The binding digest is `CandidateBoundPlanIdentity.bindingDigest`: SHA-256 over the length-prefixed (`len:value`, joined by `|`) fields `omarchy.apple.candidate-bound-plan`, `1`, trust root fingerprint, catalog sequence, catalog payload digest, plan digest, device, store, layout digest, kind, source, offset, length, engine, metadata and payload digests, written as `sha256:<hex>`. There is no catalog, so the three catalog fields describe what this run really had:

- `trust_root_fingerprint` is `sha256:` followed by 64 zeros: unsigned.
- `catalog_sequence` is the run's Unix time, so a reinstall at the same layout never reuses a completed journal.
- `catalog_payload_digest` is the SHA-256 of `package/catalog-local.json`: a local unsigned record of device, engine, metadata and payload.

The engine checks only their format and their binding (`omarchy_execution._validate_identity` and `_validate_environment_binding`). The digest chain was tested against the real `omarchy_contract`, `omarchy_planner.emit_plan` and `omarchy_execution.admit_execution`.

## Run directory

`/var/root/omarchy-engine-install` (`--state`), 0700:

- `engine/<archive>` (0400)
- `run-<time>/`:
  - `engine-install.log`, `params` (owner, encrypt, lane, readback, payload name; no secret)
  - `inspect.jsonl`, `plan.jsonl`, `*-installer.log`
  - `plan-input/`
  - `package/`, including `restore-image.requirement` and `catalog-local.json`
  - `execution-journals/` (journal, `.evidence`, `.receipt`, `.performance.jsonl`)

A dry run deletes its payload clone. After an install, the clone stays for `--retry`; delete `package/*.zip` once step 2 is done. A fresh install refuses to start while any journal in the state directory has events but no completion.

## When it fails

- **Before `--yes`, or before the first journal `event`:** nothing on disk changed. Fix the cause and run again.
- **Recovery authorization failed** (journal ends with `recovery_handoff_started`, usually a wrong password): run `engine-install --retry RUN_DIR --yes` with the password on stdin. This is the app's `retry-recovery-authorization`: the engine re-reads the installed checkpoint, then blesses again. `install.conf` is written after it.
- **Anything else after an event:** do not start a fresh install. The engine refuses to replay a started stage (`AmbiguousMutationState`). Read the log and journal. Getting back means removing the new partitions by hand: the APFS stub container, then the ESP, boot and root partitions, all of which `<journal>.partitions.receipt` names. The app's Remove Omarchy reads install journals only from its own helper directory (`/var/db/org.omarchy.installer`), so it never sees this driver's journal or receipt. Whether it recognizes a completed headless install was not checked.

## What is unverified

Nothing below has run on macOS. The Python helper and the digest chain were tested on Linux against the real engine modules. The bash flow was run end to end under Bash 5.3, with fake macOS tools and a fake `main.py` built on the real journal, planner, admission and stage-1 code. That covered the exact environment set and cwd, file modes, stdin, `--yes`, wrong password then `--retry`, the unfinished-journal guard, and the ESP locator. It proves none of the following:

1. Bash 3.2 (`/bin/bash` on macOS). This was a manual review for Bash 4 constructs only.
2. macOS tool behaviour:
   - `plutil -extract … raw` on JSON input (macOS 12+)
   - `codesign -dv --verbose=4` field names, including `Signature=adhoc`
   - `cp -c` falling back when it cannot clone
   - `diskutil info -plist /` exposing `APFSVolumeGroupID`
   - `/System/Volumes/Preboot/<group>/var/db/AdminUserRecoveryInfo.plist` being the file upstream reads
   - the wording of `sysadminctl -secureTokenStatus`
   - a secure token being the same as an APFS volume owner
   - `sudo -S` consuming exactly one line
   - `sysadminctl -autologin` syntax
3. That `env -i` hands `DYLD_*` to the bundled Python under SIP, as `Process` does.
4. That the official 2.3.16 helper reports `TeamIdentifier=T2C384FJBD` and satisfies the Developer ID requirement. Also, its compatibility with engine 20261106 when it actually runs (macOS 26 firmware); on a 13.5-firmware Mac it is only signature-checked.
5. The console-user behaviour on a headless Mac Studio: automatic login without a display, FileVault interaction, and `scutil` output over SSH.
6. That running inspect and plan as root gives the same inventory as the app's unprivileged runs.
7. The SmartRoom payload passing the engine's install preflight (`_validate_full_os_package`, `omarchy_recovery.validate_payload`) on a real Mac. Only `mac-image-check` checks it today.
8. The ESP's reported volume name case (`EFI - SMART` or `EFI - Smart`); the comparison is case-insensitive. Also whether the engine leaves the ESP mounted.
9. Survival of the run when the SSH session drops (HUP and PIPE ignored, `tee` keeps logging).
10. App steps the driver does not repeat:
    - validating the owner's credentials before submission (a wrong password surfaces at bless, and `--retry` recovers)
    - re-checking the host identity before execution
    - the optional Recovery-account handoff and Recovery-app refresh at shutdown (`RecoveryAccountHandoff.swift`)
    - install timing history
11. Step 2 itself (native Recovery on the stub, the boot policy, the first boot of the image with `encrypt=0`). The driver stops at `awaiting_recovery`.
