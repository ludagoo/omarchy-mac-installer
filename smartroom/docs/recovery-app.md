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

MEASURED

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

SCREENS
