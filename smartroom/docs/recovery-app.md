# The Recovery app techs see in 1TR (carry patch 4)

After `engine-install`, the tech starts the Mac into 1TR and picks
"SmartRoom Firmware". Recovery then opens the native Recovery app that the
image carries in `esp/aurora/recovery/` (the Engine copies it unchanged to the
stub). Upstream it is "Omarchy Installer"; on `smartroom/main` it says
SmartRoom Firmware everywhere a tech can see it or hear it with VoiceOver.

## What changed

All shown names come from `Recovery/Sources/SmartRoomBrand.swift`:

| | |
| --- | --- |
| `osName` | `SmartRoom Firmware` (the startup picker and Startup Disk name the stub this) |
| `appName` | `SmartRoom Firmware Installer` (window title, which VoiceOver reads; app menu; About; Help) |
| `recoveryAccountName` | `SmartRoom Firmware Recovery` (full name of the optional recovery account; Startup Disk lists it) |
| `recoveryAccountPlaceholder` | `smartroom-owner` (the account form's suggestion) |

- Banner: `SmartRoomWordmark.swift`, "SMARTROOM" over "FIRMWARE", drawn from a
  cell grid like upstream's wordmark, in the window's text and accent colours,
  in the same 400 × 94 point frame. Its accessibility label is
  "SmartRoom Firmware".
- Prompts, titles, sheets and errors: "set up SmartRoom Firmware", "Setting up
  SmartRoom Firmware", "Restart to start using SmartRoom Firmware", the
  wrong-Recovery sheets ("Select SmartRoom Firmware…", "The installer will
  select SmartRoom Firmware as the startup disk…"), the log viewer's note.
- `CFBundleName` is `SmartRoom Firmware Installer` (Info.plist and
  `en.lproj/InfoPlist.strings`): the menu bar's app menu and the About panel.
- The bundle carries the MIT `LICENSE` (Contents/Resources); nothing shows it.
- `engine-install`'s printed 1TR step 5 names "SmartRoom Firmware Installer"
  and its "Finish setup" screen.

Layout, sizes, colours, fonts, the flow and every behaviour are upstream's.

## What still says Omarchy

Not drawn, but matched by the pinned Engine, the image builder or the stub
layout, so they stay:

- the bundle directory `Omarchy Installer.app` (Engine `APP_NAME`; the stub's
  `.IAPhysicalMedia` `AppName`; the legacy `step2.sh` launcher path);
- `CFBundleDisplayName` = `Omarchy Installer` in Info.plist and its
  `InfoPlist.strings` line. The pinned Engine's `validate_source` refuses the
  image's app without exactly these, before it writes anything, and
  `recovery_app.py` in the image builder checks the same. Recovery's own
  Springboard reads this localized name when it launches the app
  (`Recovery/Tests/BundleLookupCheck.m` replays that lookup);
- the executable `OmarchyRecovery`, the bundle identifier
  `org.aurorasilicon.omarchy.recovery.recovery`, the `OmarchyRecovery*` keys,
  Swift type names (`OmarchyTheme`, the unused `OmarchyWordmark`) and the
  `Aurora/Recovery/…` and `omarchy-recovery-account` paths on the stub;
- text the app does not own: macOS's own tools' output in Show Details
  (bputil, kmutil, bless), and the `aura` command's name.

Measured on a test Mac Studio (macOS 14.5, CLT 16.2, preview build of
`6dcf34a`, `OUT/screens/install/names.txt`):

| What macOS reports | Value |
| --- | --- |
| window title, its accessibility title (VoiceOver) | SmartRoom Firmware Installer |
| the app's accessibility title (VoiceOver's app name) | SmartRoom Firmware Installer |
| app menu, About panel, Help alert | SmartRoom Firmware Installer |
| banner accessibility label | SmartRoom Firmware |
| `NSRunningApplication.localizedName` (LaunchServices) | **Omarchy Installer** |

LaunchServices names a running app by its `CFBundleDisplayName`, so wherever
macOS itself lists running apps (Force Quit, Cmd-Tab) and wherever Recovery's
Springboard shows the app it launches, it is "Omarchy Installer". The app
cannot change that without the Engine refusing the image. Whether Recovery
shows that name anywhere in 1TR is not verified (no fresh install was done in
this job); the app opens full-size over it. Removing it needs either the
upstream change in CARRY.md (patch 4, "Upstream PR candidate") or our own
Engine build.

Two of upstream's own sheet titles are wider than the 460-point sheet and are
clipped in upstream too: "Start Recovery with the power butto…" and
"Couldn't verify the recovery envir…" (`04d`, `04e`). The branded titles are
kept short enough to fit ("Open the installer in Recovery", "Open the paired
Recovery"); upstream's layout is not changed here.

## Rebuild after an upstream sync

On a Mac with the Command Line Tools (headless install below):

```sh
smartroom/mac/build-recovery-app --screens OUT
```

It builds both modes from the checkout, runs upstream's Recovery fixtures
(`test-all.sh`), checks the recovery build with the image builder's
`recovery_app.py`, the pinned Engine's `validate_source` (with `codesign`) and
`smartroom/recovery-branding app`, then runs the preview build's
`--smartroom-snapshots` for both flows (install, repair) into `OUT/screens`
and fails if a screen's text says Omarchy. `--screens` needs a user logged in
at the Mac's screen; a display is not needed. Copy `OUT/recovery` to the build
host and use it as `--recovery-app`; see CARRY.md, Building.

Command Line Tools without the GUI prompt (never run `git`, `python3`,
`clang`, `swift` or `xcrun` before they are installed; those are the stubs
that open it):

```sh
sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
softwareupdate -l | grep 'Label: Command Line Tools'
sudo softwareupdate -i "Command Line Tools for Xcode-<version>" --verbose
sudo rm /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
```

## Screens

`smartroom/mac/build-recovery-app --screens` writes these; the set for
release-3 (app manifest `56ab72cb…`) is in
`~/smartroom-omarchy-fork/release/smartroom-3/screens/` on the Mini, with
`before-after-01.png` (upstream and SmartRoom side by side, same 780 × 440
window).

| File | Screen |
| --- | --- |
| `install/01-finish-setup` | Finish setup: the password request 1TR opens on |
| `install/02-password-not-accepted` | a refused password, asked again in place |
| `install/03-authorize-startup-disk` | the startup-disk repair password |
| `install/04a`–`04e` | the wrong-Recovery and environment sheets |
| `install/05-sheet-setup-failed` | a failure sheet |
| `install/06-setting-up`, `07-sheet-show-details` | installing, and Utilities → Show Details (log viewer) |
| `install/08-installation-complete` | the finished screen (Restart) |
| `install/09`–`13` | the optional recovery account form, its sheets and resume |
| `install/14-about-panel`, `15-help-alert` | About and Help |
| `recovery/r1`–`r3` | the repair flow (Repair startup, Restoring, Recovery complete) |
| `*/menus.txt`, `*/names.txt` | every menu item; the names macOS reports |

Each `.png` has a `.txt` beside it with every title, label, button, placeholder
and accessibility label on that screen.
