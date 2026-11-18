import AppKit
import CoreFoundation
import ServiceManagement

#if !arch(arm64)
  #error("MenuBar supports Apple Silicon (arm64) only.")
#endif

@main
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  nonisolated private static let spacingPreferenceKeys = [
    "NSStatusItemSpacing", "NSStatusItemSelectionPadding",
  ]

  private let menu = NSMenu()
  private let loginItem = NSMenuItem(
    title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
  private let compactSpacingItem = NSMenuItem(
    title: "紧凑间距", action: #selector(toggleCompactSpacing), keyEquivalent: "")

  private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private var spacerItem: NSStatusItem?
  private var autoCollapseTimer: Timer?
  private var isBusy = false {
    didSet {
      loginItem.isEnabled = !isBusy
      compactSpacingItem.isEnabled = !isBusy
      updateStatusItem()
    }
  }

  private var isCollapsed: Bool { spacerItem != nil }

  private var isLoginItemRegistered: Bool {
    let status = SMAppService.mainApp.status
    return status == .enabled || status == .requiresApproval
  }

  private var isSpacingCompact: Bool {
    Self.spacingPreferenceKeys.allSatisfy { key in
      CFPreferencesCopyValue(
        key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
        kCFPreferencesCurrentHost) as? Int == 8
    }
  }

  static func main() {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }

  func applicationDidFinishLaunching(_: Notification) {
    statusItem.autosaveName = "MenuBar.HiddenBoundary"
    statusItem.button?.target = self
    statusItem.button?.action = #selector(handleStatusItemClick(_:))
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    menu.delegate = self
    menu.autoenablesItems = false
    loginItem.target = self
    compactSpacingItem.target = self
    menu.addItem(loginItem)
    menu.addItem(compactSpacingItem)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    ).target = NSApp
    updateStatusItem()
    toggleVisibility()
  }

  func applicationWillTerminate(_: Notification) {
    autoCollapseTimer?.invalidate()
    if let spacerItem { NSStatusBar.system.removeStatusItem(spacerItem) }
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  func menuNeedsUpdate(_: NSMenu) {
    loginItem.state = isLoginItemRegistered ? .on : .off
    compactSpacingItem.state = isSpacingCompact ? .on : .off
  }

  @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    } else {
      toggleVisibility()
    }
  }

  @objc private func handleAutoCollapse(_: Timer) {
    toggleVisibility()
  }

  @objc private func toggleLoginItem() {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    let service = SMAppService.mainApp
    let wasRegistered = isLoginItemRegistered
    do {
      if wasRegistered {
        try service.unregister()
      } else {
        try service.register()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
      }
    } catch {
      showError(wasRegistered ? "关闭登录启动失败" : "开启登录启动失败")
    }
  }

  @objc private func toggleCompactSpacing() {
    guard !isBusy else { return }
    let compact = !isSpacingCompact
    let wasCollapsed = isCollapsed
    isBusy = true
    expand(autoCollapse: false)
    Task {
      let errorTitle = await Task.detached { Self.applySpacing(compact: compact) }.value
      var collapseFailed = false
      if wasCollapsed {
        collapseFailed = !(await collapse())
      } else {
        expand()
      }
      isBusy = false
      menuNeedsUpdate(menu)
      if let errorTitle { showError(errorTitle) }
      if collapseFailed { showError("折叠图标失败") }
    }
  }

  private func toggleVisibility() {
    guard !isBusy else { return }
    if isCollapsed {
      expand()
      return
    }
    isBusy = true
    Task {
      let didCollapse = await collapse()
      isBusy = false
      if !didCollapse { showError("折叠图标失败") }
    }
  }

  private func expand(autoCollapse: Bool = true) {
    autoCollapseTimer?.invalidate()
    autoCollapseTimer = nil
    if let spacerItem { NSStatusBar.system.removeStatusItem(spacerItem) }
    spacerItem = nil
    updateStatusItem()
    guard autoCollapse else { return }
    autoCollapseTimer = Timer.scheduledTimer(
      timeInterval: 10, target: self, selector: #selector(handleAutoCollapse(_:)), userInfo: nil,
      repeats: false)
  }

  private func collapse() async -> Bool {
    autoCollapseTimer?.invalidate()
    autoCollapseTimer = nil
    let defaults = UserDefaults.standard
    if let position = defaults.object(
      forKey: "NSStatusItem Preferred Position MenuBar.HiddenBoundary") as? Double
    {
      // AppKit sorts saved positions as floats; use the next value, not a pixel offset.
      defaults.set(
        Double(Float(position).nextUp),
        forKey: "NSStatusItem Preferred Position MenuBar.HiddenSpacer")
    } else {
      defaults.removeObject(forKey: "NSStatusItem Preferred Position MenuBar.HiddenSpacer")
    }
    let item = NSStatusBar.system.statusItem(withLength: 1)
    item.autosaveName = "MenuBar.HiddenSpacer"
    item.button?.image = NSImage(size: NSSize(width: 1, height: 1))
    spacerItem = item
    for _ in 0..<20 {
      try? await Task.sleep(for: .milliseconds(100))
      if let statusFrame = statusItem.button?.window?.frame,
        let spacerFrame = item.button?.window?.frame,
        abs(statusFrame.minY - spacerFrame.minY) < 1,
        abs(statusFrame.height - spacerFrame.height) < 1,
        abs(statusFrame.minX - spacerFrame.maxX) < 1
      {
        item.length = 10_000
        return true
      }
    }
    expand(autoCollapse: false)
    return false
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else { return }
    button.appearsDisabled = isBusy
    guard !isBusy else {
      button.setAccessibilityLabel("正在处理")
      return
    }
    let isExpanded = !isCollapsed
    button.setAccessibilityLabel(isExpanded ? "折叠图标" : "展开图标")
    let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      let path = NSBezierPath()
      path.lineWidth = 1.8
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      if isExpanded {
        path.move(to: NSPoint(x: 4, y: 3))
        path.line(to: NSPoint(x: 4, y: 15))
      } else {
        path.move(to: NSPoint(x: 10, y: 15))
        path.line(to: NSPoint(x: 4, y: 9))
        path.line(to: NSPoint(x: 10, y: 3))
      }
      path.move(to: NSPoint(x: 15, y: 3))
      path.line(to: NSPoint(x: 15, y: 15))
      path.stroke()
      return true
    }
    image.isTemplate = true
    button.image = image
  }

  private func showError(_ title: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "确认")
    NSApp.activate()
    alert.runModal()
  }

  nonisolated private static func applySpacing(compact: Bool) -> String? {
    let value: CFNumber? = compact ? 8 as CFNumber : nil
    for key in spacingPreferenceKeys {
      CFPreferencesSetValue(
        key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
        kCFPreferencesCurrentHost)
    }
    guard
      CFPreferencesSynchronize(
        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    else { return compact ? "开启紧凑间距失败" : "关闭紧凑间距失败" }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["ControlCenter"]
    do {
      try process.run()
    } catch {
      return "重启控制中心失败"
    }
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : "重启控制中心失败"
  }
}
