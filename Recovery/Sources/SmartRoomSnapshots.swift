#if OMARCHY_STEP2_PREVIEW
  import AppKit

  /// SmartRoom carry (CARRY.md patch 4), preview builds only: review every
  /// screen after an upstream sync without driving the UI by hand.
  ///
  ///     OmarchyRecovery --preview --smartroom-snapshots DIR
  ///     OmarchyRecovery --recovery-preview --smartroom-snapshots DIR
  ///
  /// walks the simulated flow, saving each state as DIR/<step>.png (the window
  /// with any sheet, as the app draws it) and DIR/<step>.txt (every title,
  /// label, placeholder and accessibility label on it), then names.txt (the
  /// names macOS reports for the app) and menus.txt, and quits. The app captures
  /// only its own windows, so no Screen Recording permission is needed.
  enum SmartRoomSnapshots {
    typealias Step = (name: String, delay: Double, action: () -> Void)
    private static var directory: URL?
    private static var model: InstallerModel!
    private static var controller: InstallerView!
    private static var window: NSWindow!
    private static var steps: [Step] = []
    private static var report: [String] = []

    static func start(model: InstallerModel, controller: InstallerView, window: NSWindow) {
      let arguments = CommandLine.arguments
      guard let flag = arguments.firstIndex(of: "--smartroom-snapshots"),
        flag + 1 < arguments.count
      else { return }
      let output = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
      try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      directory = output
      self.model = model
      self.controller = controller
      self.window = window
      steps = model.recoveryInterface ? recoverySteps() : installSteps()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() }
    }

    private static func installSteps() -> [Step] {
      var list: [Step] = [
        ("01-finish-setup", 0.5, {}),
        (
          "02-password-not-accepted", 0.6,
          {
            model.authorizationRejection =
              RecoveryPasswordRejected(username: NSUserName()).localizedDescription
          }
        ),
        (
          "03-authorize-startup-disk", 0.6,
          {
            model.authorizationRejection = nil
            model.authorizationPurpose = .repair
          }
        ),
      ]
      let issues: [EnrollmentGateIssue] = [
        .notRecovery, .rootRequired, .wrongPair, .powerButtonRequired, .cannotVerify,
      ]
      for (index, issue) in issues.enumerated() {
        list.append(
          (
            "04\(Character(UnicodeScalar(97 + index)!))-sheet-\(issue.rawValue)", 1.0,
            {
              dismissSheet()
              model.authorizationPurpose = .install
              model.environmentIssue = issue
            }
          ))
      }
      list += [
        (
          "05-sheet-setup-failed", 1.0,
          {
            dismissSheet()
            model.failure = RecoveryOwnerError.ambiguous.localizedDescription
          }
        ),
        (
          "06-setting-up", 2.0,
          {
            dismissSheet()
            model.authorize(with: "preview")
          }
        ),
        ("07-sheet-show-details", 1.0, { controller.showDetails(nil) }),
        ("08-installation-complete", 1.0, { dismissSheet() }),
        ("09-create-recovery-account", 1.5, { controller.showRecoveryAccountForm(nil) }),
        ("10-sheet-restart-simulated", 1.0, { model.skipRecoveryAccountAndRestart() }),
        (
          "11-authorize-recovery-account", 1.5,
          {
            dismissSheet()
            model.accountUsername = SmartRoomBrand.recoveryAccountPlaceholder
            model.accountPassword = "preview"
            model.accountConfirmation = "preview"
            model.createRecoveryAccount()
          }
        ),
        ("12-sheet-choose-startup-disk", 1.0, { model.finishSetup() }),
        (
          "13-resume-recovery-setup", 1.5,
          {
            dismissSheet()
            model.stage = .account
          }
        ),
        (
          "14-about-panel", 1.0,
          {
            model.stage = .complete
            NSApp.orderFrontStandardAboutPanel(nil)
          }
        ),
        ("15-help-alert", 0, { showHelpAlert() }),
      ]
      return list
    }

    private static func recoverySteps() -> [Step] {
      [
        ("r1-repair-startup", 0.5, {}),
        ("r2-restoring", 1.5, { model.restore() }),
        ("r3-recovery-complete", 1.0, {}),
      ]
    }

    private static func next() {
      guard !steps.isEmpty else { return finish() }
      let step = steps.removeFirst()
      step.action()
      // The simulated installation takes a few seconds; finished screens wait for it.
      let waitForComplete = step.name.hasSuffix("-complete")
      let ready = { !waitForComplete || model.stage == .complete }
      waitFor(ready, then: step.delay) {
        capture(step.name)
        next()
      }
    }

    private static func waitFor(
      _ ready: @escaping () -> Bool, then delay: Double, _ body: @escaping () -> Void,
      deadline: Date = Date().addingTimeInterval(20)
    ) {
      if ready() || Date() > deadline {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          waitFor(ready, then: delay, body, deadline: deadline)
        }
      }
    }

    /// Closes the sheet as a person would: Cancel, else its default button.
    private static func dismissSheet() {
      guard let sheet = window.attachedSheet, let root = sheet.contentView else { return }
      let buttons = allViews(root).compactMap { $0 as? NSButton }
      let cancel = buttons.first(where: { $0.keyEquivalent == "\u{1b}" })
      let done = buttons.first(where: { $0.keyEquivalent == "\r" })
      (cancel ?? done ?? buttons.first)?.performClick(nil)
    }

    /// Help → About … Recovery runs a modal alert; capture it, then end it.
    private static func showHelpAlert() {
      guard
        let item = NSApp.helpMenu?.items.first(where: {
          $0.action == NSSelectorFromString("showPreviewHelp:")
        }), let action = item.action
      else { return }
      // runModal serves only the modal run loop mode, not the main queue.
      let end = Timer(timeInterval: 1.0, repeats: false) { _ in
        if let alert = NSApp.modalWindow { save("15-help-alert", windows: [alert]) }
        NSApp.abortModal()
      }
      RunLoop.main.add(end, forMode: .modalPanel)
      _ = NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func capture(_ name: String) {
      if name == "15-help-alert" { return }  // saved while the alert was up
      var windows: [NSWindow] = [window]
      if let sheet = window.attachedSheet { windows.append(sheet) }
      if name == "14-about-panel",
        let panel = NSApp.windows.first(where: {
          $0 !== window && $0.isVisible && !($0 is RecoverySheet) && $0.sheetParent == nil
        })
      {
        windows = [panel]
      }
      save(name, windows: windows)
    }

    private static func save(_ name: String, windows: [NSWindow]) {
      guard let directory else { return }
      var method = "window server"
      // Front to back: a sheet before its window.
      var image = windowServerImage(windows.reversed().map { CGWindowID($0.windowNumber) })
      if image == nil {
        method = "cacheDisplay"
        image = drawnImage(windows)
      }
      if let image,
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      {
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
      } else {
        method = "none"
      }
      var lines = ["# \(name) (\(method), \(image?.width ?? 0)x\(image?.height ?? 0) px)"]
      for window in windows {
        lines.append("window title: \(window.title)")
        if let title = window.accessibilityTitle() { lines.append("window AX title: \(title)") }
        if let root = window.contentView { lines += texts(root) }
      }
      try? (lines.joined(separator: "\n") + "\n").write(
        to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
      report.append(lines[0])
    }

    /// CGWindowListCreateImageFromArray, looked up at run time: it captures this
    /// app's own windows without Screen Recording permission, but newer SDKs
    /// refuse to compile a direct call.
    private static func windowServerImage(_ ids: [CGWindowID]) -> CGImage? {
      typealias Function = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
      guard
        let symbol = dlsym(
          UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray")
      else { return nil }
      let create = unsafeBitCast(symbol, to: Function.self)
      // The array holds the CGWindowID values themselves, not CFNumbers.
      var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
      guard
        let array = values.withUnsafeMutableBufferPointer({
          CFArrayCreate(nil, $0.baseAddress, $0.count, nil)
        })
      else { return nil }
      // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
      return create(.null, array, 1 | 8)?.takeRetainedValue()
    }

    /// The windows as AppKit draws them, each sheet over its window.
    private static func drawnImage(_ windows: [NSWindow]) -> CGImage? {
      let base = windows[0]
      let scale = base.backingScaleFactor
      guard
        let canvas = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(base.frame.width * scale),
          pixelsHigh: Int(base.frame.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0)
      else { return nil }
      canvas.size = base.frame.size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
      for window in windows {
        guard let frame = window.contentView?.superview,
          let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        else { continue }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let origin = NSPoint(
          x: window.frame.minX - base.frame.minX, y: window.frame.minY - base.frame.minY)
        rep.draw(in: NSRect(origin: origin, size: window.frame.size))
      }
      NSGraphicsContext.restoreGraphicsState()
      return canvas.cgImage
    }

    private static func allViews(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(allViews)
    }

    private static func texts(_ root: NSView) -> [String] {
      var lines: [String] = []
      for view in allViews(root) where !view.isHiddenOrHasHiddenAncestor {
        if let field = view as? NSTextField {
          if !field.stringValue.isEmpty && !(field is NSSecureTextField) {
            lines.append("text: \(field.stringValue)")
          }
          if let placeholder = field.placeholderString {
            lines.append("placeholder: \(placeholder)")
          }
        } else if let button = view as? NSButton, !button.title.isEmpty {
          lines.append("button: \(button.title)")
        } else if let text = view as? NSTextView {
          lines.append("text view: \(text.string.prefix(400))")
        }
        if let label = view.accessibilityLabel(), !label.isEmpty {
          lines.append("AX label: \(label)")
        }
      }
      return lines
    }

    private static func menus(_ menu: NSMenu, depth: Int = 0) -> [String] {
      menu.items.flatMap { item -> [String] in
        let pad = String(repeating: "  ", count: depth)
        let line = item.isSeparatorItem ? pad + "----" : pad + item.title
        return [line] + (item.submenu.map { menus($0, depth: depth + 1) } ?? [])
      }
    }

    private static func finish() {
      guard let directory else { return }
      let info = Bundle.main.infoDictionary ?? [:]
      let localized = Bundle.main.localizedInfoDictionary ?? [:]
      let names = [
        "Info.plist CFBundleName: \(info["CFBundleName"] ?? "-")",
        "Info.plist CFBundleDisplayName: \(info["CFBundleDisplayName"] ?? "-")",
        "localized CFBundleName: \(localized["CFBundleName"] ?? "-")",
        "localized CFBundleDisplayName: \(localized["CFBundleDisplayName"] ?? "-")",
        "NSRunningApplication.localizedName: \(NSRunningApplication.current.localizedName ?? "-")",
        "ProcessInfo.processName: \(ProcessInfo.processInfo.processName)",
        "NSApp accessibility title: \(NSApp.accessibilityTitle() ?? "-")",
        "main window title: \(window.title)",
        "main window AX title: \(window.accessibilityTitle() ?? "-")",
        "wordmark AX label: \(SmartRoomWordmark(frame: .zero).accessibilityLabel() ?? "-")",
      ]
      try? ((names + [""] + report).joined(separator: "\n") + "\n").write(
        to: directory.appendingPathComponent("names.txt"), atomically: true, encoding: .utf8)
      if let menu = NSApp.mainMenu {
        try? (menus(menu).joined(separator: "\n") + "\n").write(
          to: directory.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
      }
      NSApp.terminate(nil)
    }
  }
#endif
