# Unattended macOS -> Linux-stub boot switching on Apple Silicon (bless, MDM, Jamf, credentials)

Research date: 2026-11-17. Web research only; nothing was run on any Mac.

Evidence tags used below:
- **[DOC]**: vendor documentation (Apple, Jamf) or a man page.
- **[SRC]**: source code I read: XNU `IONVRAM.cpp` and `IOKitKeysPrivate.h`, `asahi-installer/src/main.py`, `asahi-bless/lib.rs`.
- **[COMM]**: community report (Asahi GitHub issues, Jamf Nation, forums, Eclectic Light).
- **[INF]**: my own inference. Not verified. Test it.

Caveat on Apple sources: support.apple.com/guide/deployment and /guide/security pages returned HTTP 404 to my fetcher.
Claims tagged [DOC, indexed] come from the search-engine excerpts of those Apple pages, not from a full read.
developer.apple.com MDM schema pages were read in full through their JSON endpoints.

---

## TL;DR

1. macOS `bless` on Apple Silicon needs **local owner** credentials (`--user`, `--stdinpass`) to change boot policy. Running as root is not enough. Without them, bless fails with `Bootability failed Error Domain=BYErrorDomain Code=103 "Owner authentication is required" UserInfo={BYErrorHint=LocalAuthenticationRequired…}` [DOC man page; COMM Asahi #174/#267].
   - The well-known `0xe00002e2` and `0xe00002bc` errors ("Could not set boot device property") come from **Intel/SIP-era** bless. They are not the Apple Silicon failure mode [COMM nshipster, Apple Community].
2. Root cannot write `boot-volume` or `alt-boot-volume` with `nvram`. In XNU, writes to the system NVRAM region (GUID 40A0DDD2-…) need the private entitlement `com.apple.private.iokit.system-nvram-allow` unless the variable is on a short allow-list. `boot-volume` is not on that list [SRC].
   - `systemsetup -liststartupdisks` returns empty or `(null)` on Apple Silicon [COMM].
3. **No MDM command or DDM declaration sets the startup disk** (confirmed against Apple's current command and declaration lists) [DOC].
   - The bootstrap token is only used for: software update authorization, kext approval / kernel-cache rebuild, Erase All Content and Settings (EACAS), Platform SSO user creation, and granting secure tokens / volume ownership.
   - It cannot be handed to `bless` [DOC; INF].
4. Jamf has a "Startup Disk" field in the policy *Restart Options* payload, but nothing documents it working on Apple Silicon. It has no field for owner credentials [DOC; INF].
   - Script parameters 4-11 appear in `ps` while the script runs [COMM].
   - Jamf LAPS passwords can be retrieved through the API, but owner status depends on the account type (see §3).
5. The cleanest credential-free design: **make the Linux stub the persistent default, and have Linux set macOS as "next boot only" (`asahi-bless --next`)**. "Switch macOS -> Linux" then becomes just "reboot macOS", which works as root or via MDM RestartDevice.
   - Risk: macOS updates have been reported to reset the default boot volume to macOS [COMM].
   - Risk: macOS 27 hides Asahi-style volumes unless the APFS "bootable" flag is set [COMM/Asahi blog].

---

## 1. What `bless` needs on Apple Silicon

### Documented (bless(8), Xcode man-page mirror) [DOC]
Source: https://keith.github.io/xcode-man-pages/bless.8.html
- Section "OPTIONS FOR APPLE SILICON DEVICES".
- `--user`: "Collect a local owner username to authorize boot policy modification."
- `--stdinpass`: "Collect a local owner password from stdin without prompting."
- `--passpromt` (sic): prompt for the password.
- `--mount` (Apple Silicon): "Use the volume mounted at directory to change the active boot device, in conjunction with --setBoot. The volume must already be properly blessed."
- `--nextonly` (Apple Silicon, Mount mode): "Only change the boot device selection for the next boot."
- NOTE: "Admin credentials may be prompted when running bless on an Apple silicon platform (beyond running the tool as an admin user). However, if the volume has been previously blessed by a different OS instance, then these credentials may not be necessary or used to bless the target OS."
- The man page does **not** say whether `--nextonly` is exempt from the credential requirement. It also doesn't say whether the owner must be an admin.
  - It says "owner" in the flag descriptions and "Admin credentials" in the note.
  - [INF] Test both points on a lab Mac. See "Tests" at the end.

### Real-world precedent: Asahi installer [SRC]
Source: https://raw.githubusercontent.com/AsahiLinux/asahi-installer/main/src/main.py
- The installer runs `bless --setBoot --device /dev/<stub system volume> --user <admin> --stdinpass` and passes the password on stdin.
- It only offers users listed in `<Preboot>/<VGID>/var/db/AdminUserRecoveryInfo.plist` (admin users). It also refuses to run unless there is "at least one administrator user that is a machine owner".
- This is not proof that bless requires admin. The installer also runs `bputil`, which needs admin.
- Known quirk, from a code comment: if the password starts or ends with a space, `--stdinpass` fails ("a silly Apple bug"). The installer falls back to an interactive prompt.

### Error messages seen on Apple Silicon [COMM]
- `Bootability failed Error Domain=BYErrorDomain Code=103 "Owner authentication is required" UserInfo={BYErrorHint=LocalAuthenticationRequired…}`
  - Seen when the user isn't an owner or the password is wrong.
  - Sources: https://github.com/AsahiLinux/asahi-installer/issues/174 and https://github.com/AsahiLinux/asahi-installer/issues/267. In #267 the maintainer says "your admin account is not, in fact, a machine owner" and suggests `sudo diskutil apfs updatePreboot /`.
- `Bootability failed Error Domain=BYErrorDomain Code=302 "The signing server encountered an error during personalization"` (underlying AuthInstallErrorDomain 3501/3503).
  - bless contacted Apple's signing server (gs.apple.com) and the request failed.
  - Sources: https://github.com/AsahiLinux/asahi-installer/issues/48 and https://github.com/AsahiLinux/asahi-installer/issues/333.
  - [INF] Personalization probably happens only when the target is first made bootable or its LocalPolicy is (re)created, not on every switch. Still, allow outbound access to gs.apple.com from the Macs.
- `Could not set boot device property: 0xe00002e2` / `0xe00002bc` are Intel SIP-era errors.
  - nshipster (2019, Intel/Boot Camp, "Setting startup disk not allowed while System Integrity Protection is enabled"): https://nshipster.com/bless/
  - Apple Community (Intel Mac mini 2011): https://discussions.apple.com/thread/255689863

### `nvram boot-volume` / `alt-boot-volume` as root
- [SRC] XNU `iokit/Kernel/IONVRAM.cpp` `verifyPermission()`:
  - A write to the system-region GUID needs `systemAllow`, which means the `com.apple.private.iokit.system-nvram-allow` entitlement (or the internal variant, or kernel). The only exception is a variable on `IONVRAMSystemVariableList`.
  - Otherwise the code logs "Not entitled for system region writes" and denies the write.
  - The allow-list (`IOKitKeysPrivate.h`) contains: allow-root-hash-mismatch, auto-boot, auto-boot-halt-stage, base-system-path, boot-args, boot-command, boot-image, bootdelay, darkboot, emu, one-time-boot-command, policy-nonce-digests, prevent-restores, prev-lang:kbd, root-live-fs, sep-debug-args, StartupMute, SystemAudioVolume*.
  - **`boot-volume` and `alt-boot-volume` are not on the list.**
  - Sources: https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IONVRAM.cpp and https://github.com/apple-oss-distributions/xnu/blob/main/iokit/IOKit/IOKitKeysPrivate.h
- [INF] So `sudo nvram 40A0DDD2-77F8-4392-B4A3-1E7304206516:boot-volume=…` should be denied: `/usr/sbin/nvram` is not expected to carry that private entitlement.
  - Writing `boot-volume` without the GUID lands in the common region, which iBoot ignores.
  - Reading is allowed for root (`admin` check in the Read case), so macOS can *detect* the current default.
- [COMM] Even allow-listed `boot-args` is refused under SIP with "(iokit/common) not permitted": https://discussions.apple.com/thread/255070042
- [DOC] Eclectic Light: NVRAM on Apple Silicon is "not intended to be meddled with by the user".
  - `boot-volume` is the "default boot volume".
  - Only a DFU restore fully resets NVRAM.
  - Source: https://eclecticlight.co/2024/07/30/nvram-in-apple-silicon-macs/
- [SRC] From Linux, `asahi-bless` writes `boot-volume` (persistent) or `alt-boot-volume` (`--next`) directly as System-type variables.
  - Value: `EF57347C-0000-AA11-AA11-00306543ECAC:<part-uuid>:<vg-uuid>`.
  - `--clear-next` deletes `alt-boot-volume`.
  - Source: https://docs.rs/asahi-bless/0.4.2/src/asahi_bless/lib.rs.html
  - The firmware reads `boot-volume` in stage 1 (https://asahilinux.org/docs/fw/boot/). No credentials are needed because Linux has no entitlement gate.

### `systemsetup -setstartupdisk`
- [DOC] Apple's Terminal guide still documents `systemsetup -setstartupdisk` for remote Macs, with no Apple Silicon caveat: https://support.apple.com/en-us/guide/terminal/apd0445a31b-28d0-4ad2-bc19-abf64f36446b/2.11/mac/11.0
- [COMM] On Apple Silicon, `systemsetup -liststartupdisks` returns empty (https://eclecticlight.co/2026/07/18/what-makes-a-volume-bootable/). An M4 user reports `-getstartupdisk` returning `(null)` and being unable to set the disk from the CLI (r/osx thread, via search excerpt).
- [INF] Treat it as non-functional on Apple Silicon.

---

## 2. MDM / bootstrap token

### MDM commands and declarations
- **MDM commands** [DOC]: Apple's current list (https://developer.apple.com/documentation/devicemanagement/commands-and-queries) covers profiles, device info, Erase / Lock / Restart / Shut Down, apps, media, AccountConfiguration, SetAutoAdminPassword, Set/Verify Firmware Password, Set/Verify Recovery Lock, Settings, LOM, SecurityInfo, RotateFileVaultKey, user management and others. **None selects a boot volume.**
- **RestartDevice keys** [DOC]: only `NotifyUser`, `RebuildKernelCache` and `KextPaths`. RebuildKernelCache is the one that pulls the bootstrap token.
  - Source: https://developer.apple.com/documentation/devicemanagement/restartdevicecommand/command-data.dictionary
- **Settings command items** [DOC]: no startup-disk item. Items include accessibility, Bluetooth, DeviceName, HostName, SoftwareUpdateSettings, TimeZone and similar.
- **DDM declarations** [DOC]: the full list (https://developer.apple.com/documentation/devicemanagement/devicemanagement-declarations) has 68 entries: accounts, apps, assets, DiskManagementSettings, Passcode, SoftwareUpdate*, ScreenSharing, Services*, Safari and others. **No boot or startup declaration.**
- **Verdict: confirmed, no MDM or DDM path to set the startup disk.**

### Bootstrap token on Apple Silicon
- SecurityInfo keys [DOC] (https://developer.apple.com/documentation/devicemanagement/securityinforesponse/securityinfo-data.dictionary):
  - `BootstrapTokenAllowedForAuthentication`: whether the SEP "supports and allows secure operations to use the Bootstrap Token". Set automatically under ADE, or manually in recoveryOS.
  - `BootstrapTokenRequiredForSoftwareUpdate`.
  - `BootstrapTokenRequiredForKernelExtensionApproval`: covers the kext policy payload and RestartDevice with RebuildKernelCache.
- Apple Platform Deployment [DOC, indexed] (https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web):
  - On Apple Silicon the bootstrap token can authorize software updates, silently authorize EACAS, and create users at first Platform SSO login. It grants secure tokens, and with them volume ownership, to accounts.
  - On macOS 26+ it is created at enrollment and grants the first user a secure token.
  - "When a bootstrap token is available and in use, it also becomes a volume owner…"
- Jamf [DOC] (https://learn.jamf.com/r/en-US/technical-articles/Manually_Leveraging_Apples_Bootstrap_Token_Functionality): "macOS can request the bootstrap token from Jamf Pro when additional authorization from a volume owner is required, such as when issuing managed software update commands."
- **Can it authorize bless?**
  - [INF] No. No document lists startup-disk or boot-volume selection as a bootstrap-token use.
  - The token is fetched by macOS system components only for the MDM operations above. There is no local API that hands it to a process, and `bless --user` needs a username plus password.

---

## 3. Jamf Pro options

- **Built-in action** [DOC]: the policy *Restart Options* payload has "Startup Disk: Specify the disk to restart computers from."
  - Its only Apple Silicon note concerns the bootstrap token for MDM RestartDevice.
  - Source: https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Policy_Payload_Reference
  - [INF] It runs bless on the client but has no way to pass owner credentials, so expect error 103 for a non-macOS volume. Don't rely on it.
- **Script parameters 4-11** [COMM]:
  - They are passed as argv to the script, so they are visible in `ps -e` / `ps aux` while the policy runs.
  - Jamf's "Encrypted Script Parameters" only obfuscates: the passphrase sits in the script and the ciphertext is still in argv.
  - Values are stored server-side and can be read by any Jamf admin with policy or script read rights.
  - Sources: https://community.jamf.com/t5/jamf-pro/secure-script-parameters/m-p/50376 and https://community.jamf.com/general-discussions-2/jamfing-for-joy-attacking-macos-in-enterprise-21140
  - Commands that embed passwords can land in policy logs: https://community.jamf.com/t5/jamf-pro/create-hidden-account-with-jamf-binary-password-security/m-p/188762
  - Inside the script, use `bless … --stdinpass <<<"$pw"` (a here-string, which is a shell builtin) so the password never enters bless's argv. Avoid `echo "$pw" |` in `sh` variants where echo isn't a builtin [INF].
- **Jamf LAPS / Management Account** [DOC]:
  - Since Jamf Pro 10.49 the Management Account password is randomized (29 characters), not set by the admin, and retrievable through `/api/v2/local-admin-password/{clientManagementId}/account/{username}/password`, with audit history.
  - Sources: https://community.jamf.com/tech-thoughts-180/laps-enhancements-and-changes-to-the-uie-management-account-53417 and https://learn.jamf.com/r/en-US/technical-paper-laps-current/Using_LAPS
  - Per the Jamf blog (https://www.jamf.com/blog/jamf-pro-laps-manage-local-admin-passwords/):
    - The jamf-binary LAPS account "can receive a secure token" and can unlock FileVault.
    - With the MDM LAPS account (the PreStage admin, whose password is set by `SetAutoAdminPassword`), "you can't enable the LAPS account for FileVault".
  - [DOC] `SetAutoAdminPassword` pushes a salted PBKDF2 *hash* for the ADE-created admin: https://developer.apple.com/documentation/devicemanagement/setautoadminpasswordcommand/command-data.dictionary
  - [INF] A hash push can't rewrap secure-token keys, so the MDM-created admin is unlikely to be a usable volume owner.
  - [COMM] Randomizing via SetAutoAdminPassword "will break Secure Token and volume ownership": https://community.jamf.com/t5/jamf-pro/upcoming-change-will-enforce-laps-on-prestage-admin-accounts/m-p/308443
  - [COMM] A Management Account that never logged in often has no secure token. It gets one from the bootstrap token after an interactive login: https://community.jamf.com/general-discussions-2/bootstrap-tokens-and-secure-tokens-57491
  - Check owner status per Mac with `diskutil apfs listUsers /` (look for "Volume Owner: Yes").
  - [INF] Using the Management Account as the bless owner would mean fetching its LAPS password at run time. That puts Jamf API credentials on the client, and rotation-after-view would trigger. It's possible, but worse than a dedicated account.
- **Community precedent**: I found **no** Jamf Nation or MacAdmins post that blesses a non-macOS volume unattended on Apple Silicon.
  - The closest precedents both use the same `--user/--stdinpass` owner pattern:
    - `startosinstall --user X --stdinpass` / erase-install. Owner, not admin, is the requirement, and errors include "Could not find provided owner on this system": https://community.jamf.com/t5/jamf-pro/os-update-via-self-service-for-m1-devices-bash-command-issue/m-p/266434
    - The `super` tool's non-admin, volume-owner "super" service account, stored in the System keychain: https://github.com/Macjutsu/super/wiki/Apple-Silicon-Local-Credentials
  - A third-party "Asahi Restart Helper" for macOS mentions `bless` and `--nextonly` and a privileged helper, but publishes no implementation: https://github.com/rxhfcy/Asahi-Restart-Helper--macOS-version

---

## 4. LaunchDaemon + stored owner credential

### Storage options [COMM/INF]
- **System keychain**:
  - Store with `security add-generic-password -s <svc> -a <acct> -w <pw> -T /usr/bin/security /Library/Keychains/System.keychain`; read as root with `find-generic-password -w`.
  - `super` does exactly this, base64-encoded, and states "any local administrator can access the base64 encoded strings in the System keychain" (super wiki above).
  - It also warns: don't deliver the secret via a configuration profile, because it is visible in System Settings.
- **Root-only 0600 file**: about the same protection as the keychain against root (none) and against standard users (good).
- [INF] Neither option protects against root or any admin who can sudo. The real control is **minimizing what the account can do**, plus rotation. A Jamf policy can periodically reset it with `sysadminctl -resetPasswordFor` using the old password, which keeps the secure token in sync.

### Can a non-admin owner be used?
- [DOC, indexed] Apple Platform Deployment:
  - Volume ownership accompanies the secure token.
  - "modifying startup security settings requires being both an administrator and a volume owner".
  - Authorizing software updates "is allowed by standard users and only requires ownership".
- [COMM] `super` runs `softwareupdate` with a **non-admin** volume-owner service account (super wiki).
- [COMM] For `startosinstall --user`, posters report the account "does not necessarily have to be an admin" but must have a secure token.
- **For `bless --user` specifically: no source either way.** The man page says "local owner" in the flags and "Admin credentials" in the note.
  - [INF] Ownership is enforced by the SEP or OIK and admin by Authorization Services. bless runs as root, so a standard owner *may* work.
  - **Must be tested** (Tests T2 and T3).
- Creating the account [COMM]:
  - A secure token can only be granted by an existing secure-token admin (two passwords: `sysadminctl -secureTokenOn bootswitch -password … -adminUser <tokenAdmin> -adminPassword …`). With an escrowed bootstrap token, macOS can grant one at login.
  - Without a token you get "Operation is not permitted without secure token unlock": https://community.jamf.com/t5/jamf-pro/sysadminctl-securetokenon-broken/td-p/194568
  - Hide it (`IsHidden 1`), set the shell to `/usr/bin/false`, and exclude it from SSH and Screen Sharing ACLs.
  - It still appears at the FileVault preboot unlock if FileVault is on (super wiki).

### What the owner credential enables (blast radius)
- [DOC, indexed] Volume owners can:
  - change the startup security policy (admin + owner);
  - authorize macOS updates and upgrades;
  - initiate Erase All Content and Settings;
  - and "more".
- [DOC, indexed] Apple Platform Security, LocalPolicy contents: Ownership is access to the single per-Mac OIK. It "is required to allow users to resign the LocalPolicy after making policy or software changes". Installing another OS requires owner consent.
  - Source: https://support.apple.com/guide/security/contents-a-localpolicy-file-mac-apple-silicon-secc745a0845/web
- Concretely:
  - (a) Change the default or next startup OS. [COMM, error 103]
  - (b) Authorize OS updates. [DOC]
  - (c) In 1TR with physical access: reduce security, permit kexts, disable SIP, or install another OS. **Admin + owner only**, so a standard owner can't do this. [DOC indexed + INF]
  - (d) Unlock FileVault at preboot and read data. Every secure-token user is FileVault-enabled. [INF, consistent with super wiki]
  - (e) Log in, unless login is blocked as above.
  - (f) Grant secure tokens to others: **admin owners only**. [COMM]
  - (g) EACAS: needs owner, and the System Settings UI also needs admin. [DOC indexed + INF]
- **Recommendation**: a dedicated, hidden, standard (non-admin) owner whose only purpose is boot switching. Use it only if test T2 shows bless accepts non-admin owners. Otherwise fall back to an admin owner and accept (c) and (f).

---

## 5. Credential-free alternatives; persistence behaviour

### Inverted default
**Linux stub as persistent default; macOS selected as next-boot-only from Linux.**
- From Linux: `asahi-bless --next --set-boot-macos -y` (or `--set-boot <name>`) writes `alt-boot-volume`; `--clear-next` removes it [SRC/DOC].
  - Man page: https://manpages.debian.org/trixie/asahi-bless/asahi-bless.1.en.html
- macOS -> Linux then needs only a reboot: `shutdown -r now` from a Jamf policy, or MDM RestartDevice. No owner credential is involved.
- One-time semantics:
  - [DOC] Apple's startup options "Continue" is a one-time start, and Option + "Always Use" sets the default. Sources: https://support.apple.com/en-us/102603 and https://support.apple.com/guide/mac-help/macos-recovery-a-mac-apple-silicon-mchl82829c17/mac
  - [SRC/COMM] asahi-bless implements "next boot only" via `alt-boot-volume`. Asahi users treat it as reverting afterwards: https://github.com/AsahiLinux/asahi-nvram/issues/23
  - **I found no primary source stating that iBoot clears `alt-boot-volume` once it is consumed.** [INF] It very likely does. Verify with T5.
- To keep macOS as the normal operating mode in this design, Linux would act as the boot manager.
  - On each boot it would immediately set `--next` macOS and reboot when macOS mode is wanted. Every macOS reboot then passes through Linux, at a time cost.
  - Alternatively, accept that any macOS reboot (nightly, crash, power) lands in Linux.
- Drift detection from macOS [INF from SRC]: root can *read* `nvram 40A0DDD2-77F8-4392-B4A3-1E7304206516:boot-volume`. A Jamf extension attribute can flag Macs whose default has drifted to macOS.

### Does a macOS update change the default? [COMM]
- **Yes, sometimes.**
  - Asahi maintainer: "Apple's upgrade process has been known to screw up OS boot policies sometimes". One report says the default became macOS after the update: https://github.com/AsahiLinux/asahi-installer/issues/100
  - A Sonoma-era report says that after a macOS update the Mac kept booting macOS by default; it was fixed with `asahi-bless`: https://discussion.fedoraproject.org/t/mac-os-switched-to-default-boot-option-after-apple-software-update/101151
  - The firmware also has separate `update-volume` and `upgrade-boot-volume` variables for the update flow (https://asahilinux.org/docs/fw/boot/).
  - **Implication**: the inverted design can still get stuck in macOS after an update. Keep the owner credential (or a manual step) as a fallback, and monitor drift.
- **macOS 27** [COMM, Asahi blog]: after upgrading to macOS 27, Asahi volumes vanished from Startup Disk and the boot picker.
  - Cause: macOS 27 boot tooling now honours an APFS "bootable" volume flag that the Asahi installer never set.
  - Fix: the Asahi installer's "Fix macOS 27 boot picker compatibility" option, or a Linux-side tool run **before** upgrading. New installs set the flag.
  - The firmware still booted the volume via macOS 26 tooling.
  - Source: https://asahilinux.org/2026/06/progress-report-7-1/
  - **Your custom "SmartRoom Firmware" stub must have this flag set before any Mac goes to macOS 27.** [INF] Otherwise macOS-side `bless` and Startup Disk will likely refuse it.
- **Power failure** [COMM/INF]:
  - The startup-disk setting lives in NVRAM (NOR flash), so it persists: https://eclecticlight.co/2025/02/21/how-external-bootable-disks-work-with-apple-silicon-macs/
  - If the selected disk can't boot, the Mac "will normally fall back to starting up from the internal SSD" (same source).
  - I found no report of a plain power loss changing the default. [INF] An unconsumed `alt-boot-volume` should likewise survive.
  - [DOC] After a firmware *revive or restore*, which is needed for example if power fails mid-update, the startup disk may need to be selected again: https://support.apple.com/HT213662

---

## Suggested tests on one lab Mac (macOS 14.5 and 15.x)
- T1: `sudo bless --mount "/Volumes/SmartRoom Firmware" --setBoot --nextonly` with **no** `--user`. Does it succeed, given the stub was "previously blessed"? Then the same without `--nextonly`. Record any error 103 output.
- T2: Create a hidden **standard** user with a secure token. Confirm `diskutil apfs listUsers /` shows Volume Owner: Yes. Run `sudo bless --mount … --setBoot [--nextonly] --user bootswitch --stdinpass <<<"$pw"`.
- T3: Repeat T2 as a LaunchDaemon (root, no GUI session, display unplugged) and as a Jamf policy script, to confirm nothing needs a GUI.
- T4: Repeat T2 with the network blocked to gs.apple.com, to see whether personalization (error 302) is needed per switch.
- T5: Inverted design.
  - From Linux: `asahi-bless --set-boot <stub>`, then `asahi-bless --next --set-boot-macos`, then reboot.
  - From macOS: read `40A0DDD2-…:alt-boot-volume` (it should be gone) and reboot. It should land in Linux.
- T6: Install a macOS point update via MDM with Linux as default. Afterwards, check whether `boot-volume` was rewritten to macOS.
