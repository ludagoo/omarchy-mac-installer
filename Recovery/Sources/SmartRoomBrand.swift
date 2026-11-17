// SmartRoom carry (CARRY.md patch 4): every name the Recovery app shows or
// VoiceOver reads comes from here. Keep in step with CFBundleName in
// build-app.sh and Resources/en.lproj/InfoPlist.strings
// (smartroom/test/recovery-branding-test.sh checks all three).
//
// Not renamed, because the pinned Engine, the image builder or the stub layout
// match on them and none is shown on screen: the bundle "Omarchy Installer.app",
// its CFBundleDisplayName "Omarchy Installer", CFBundleExecutable
// "OmarchyRecovery", the bundle identifier, OmarchyRecoveryBuildMode and the
// Aurora/omarchy-* paths on the stub.
enum SmartRoomBrand {
  /// The installed system, as the startup picker and Startup Disk name it.
  static let osName = "SmartRoom Firmware"
  /// This app: window title, app menu, alerts.
  static let appName = "SmartRoom Firmware Installer"
  /// Full name of the optional recovery account (Startup Disk lists it).
  static let recoveryAccountName = "SmartRoom Firmware Recovery"
  /// Suggested short name on the recovery account form.
  static let recoveryAccountPlaceholder = "smartroom-owner"
}
