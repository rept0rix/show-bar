import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let shared = AppDelegate()
    private let defaultsKey = "ShowBar.enabled"
    private let loginKey = "ShowBar.launchAtLogin"
    private let dockTipKey = "ShowBar.explainedDock"
    private var statusItem: NSStatusItem!
    private var hover = HoverController()
    private var permissionsWindow: NSWindow?
    private var adminWindow: NSWindow?
    private var rateWindow: NSWindow?
    private var offeredUpdate: String?
    private var permissionsModel: PermissionsModel?
    private var permissionsTimer: Timer?
    private var sawAccessibility = false
    private var sawScreenRecording = false

    var previewsAreEnabled: Bool { enabled }

    fileprivate func applyPreviewPreferences() {
        hover.reloadAppearance()
    }

    fileprivate func applyDockPosition() {
        hover.noteDockMoved()
    }

    private var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sawAccessibility = AXIsProcessTrusted()
        sawScreenRecording = CGPreflightScreenCaptureAccess()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        UNUserNotificationCenter.current().delegate = self
        noteUpdate(nil)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        DockAutohide.restore()
        ClipboardShelf.shared.start()
        syncHover()
        ensureLaunchAtLogin()
        if !PermissionsState.allGranted {
            showPermissions()
        }
        recommendKeepingTheDockIcon()
        AppUpdate.restoreBadge()
        AppUpdate.checkOnLaunch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.presentRateRequestIfNeeded()
        }
    }

    func noteUpdate(_ version: String?) {
        offeredUpdate = version
        statusItem?.button?.image = menuBarIcon(updateReady: version != nil)
        statusItem?.button?.toolTip = version.map { "Show Bar — update \($0) is ready" } ?? "Show Bar"
    }

    func relaunchAfterUpdate() {
        WindowSwitcher.shared.stop()
        relaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func menuWillOpen(_ menu: NSMenu) {
        WindowSnap.rememberFront()
        ClipboardShelf.shared.rememberTarget()
        menu.removeAllItems()
        if let version = offeredUpdate {
            let ready = NSMenuItem(title: "Update to \(version)…", action: #selector(installOfferedUpdate), keyEquivalent: "")
            ready.target = self
            ready.image = menuBarDot
            menu.addItem(ready)
            menu.addItem(.separator())
        }
        let toggle = NSMenuItem(
            title: enabled ? "Previews enabled" : "Previews disabled",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let accessibilityOn = AXIsProcessTrusted()
        let screenOn = CGPreflightScreenCaptureAccess()
        addStatusItem(
            menu,
            title: accessibilityOn ? "Accessibility: Working" : "Accessibility: Not working",
            ok: accessibilityOn,
            action: #selector(fixAccessibility)
        )
        addStatusItem(
            menu,
            title: screenOn ? "Screen Recording: Working" : "Screen Recording: Not working",
            ok: screenOn,
            action: #selector(fixScreenRecording)
        )
        let ready = accessibilityOn && screenOn && hover.iconCount > 0
        addStatusItem(
            menu,
            title: ready ? "Status: Ready" : "Status: Not ready",
            ok: ready,
            action: #selector(openPermissions)
        )
        if accessibilityOn {
            let dock = NSMenuItem(title: "Dock icons: \(hover.iconCount)", action: nil, keyEquivalent: "")
            dock.isEnabled = false
            menu.addItem(dock)
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openPermissions), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let preview = NSMenuItem(title: "Show a preview now", action: #selector(showSample), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)

        let snap = NSMenuItem(title: "Snap window", action: nil, keyEquivalent: "")
        let snapMenu = NSMenu()
        for zone in SnapZone.allCases {
            let item = NSMenuItem(title: zone.title, action: #selector(snapFront(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = zone.rawValue
            snapMenu.addItem(item)
        }
        snap.submenu = snapMenu
        menu.addItem(snap)

        let shot = NSMenuItem(title: "Screenshot", action: nil, keyEquivalent: "")
        let shotMenu = NSMenu()
        let whole = NSMenuItem(title: "Copy screen    ⌘⇧3", action: #selector(copyScreen), keyEquivalent: "")
        whole.target = self
        shotMenu.addItem(whole)
        let area = NSMenuItem(title: "Copy selection    ⌘⇧4", action: #selector(copySelection), keyEquivalent: "")
        area.target = self
        shotMenu.addItem(area)
        shot.submenu = shotMenu
        menu.addItem(shot)

        let clips = NSMenuItem(title: "Clipboard", action: nil, keyEquivalent: "")
        let clipMenu = NSMenu()
        let recent = Array(ClipboardShelf.shared.clips.prefix(8))
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing copied yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            clipMenu.addItem(empty)
        } else {
            for clip in recent {
                let item = NSMenuItem(title: ClipboardShelf.shared.menuTitle(for: clip), action: #selector(pasteClip(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clip.id.uuidString
                clipMenu.addItem(item)
            }
        }
        clipMenu.addItem(.separator())
        let history = NSMenuItem(title: "Show history    ⌃⌥V", action: #selector(showClipboard), keyEquivalent: "")
        history.target = self
        clipMenu.addItem(history)
        clips.submenu = clipMenu
        menu.addItem(clips)

        let donate = NSMenuItem(title: "Donate", action: #selector(openDonate), keyEquivalent: "")
        donate.target = self
        menu.addItem(donate)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let dockTip = NSMenuItem(title: "Keep the Dock icon…", action: #selector(explainDockIcon), keyEquivalent: "")
        dockTip.target = self
        menu.addItem(dockTip)

        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Show Bar…", action: #selector(removeApp), keyEquivalent: "")
        remove.target = self
        remove.attributedTitle = NSAttributedString(
            string: "Remove Show Bar…",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(remove)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let admin = NSMenuItem(title: "Admin…", action: #selector(openAdmin), keyEquivalent: "")
        admin.target = self
        menu.addItem(admin)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.button?.appearsDisabled = !enabled
    }

    @objc fileprivate func toggleEnabled() {
        enabled.toggle()
        syncHover()
    }

    @objc private func openPermissions() {
        showPermissions()
    }

    @objc private func showSample() {
        if let message = hover.showSamplePreview() {
            let alert = NSAlert()
            alert.messageText = "Show Bar"
            alert.informativeText = message
            alert.runModal()
        }
    }

    @objc private func snapFront(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let zone = SnapZone(rawValue: raw) else { return }
        WindowSnap.apply(zone)
    }

    @objc private func copyScreen() {
        ShotShelf.shared.captureScreen()
    }

    @objc private func copySelection() {
        ShotShelf.shared.beginSelection()
    }

    @objc private func showClipboard() {
        ClipboardShelf.shared.show()
    }

    @objc private func pasteClip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ClipboardShelf.shared.paste(id: id)
    }

    @objc private func openDonate() {
        NSWorkspace.shared.open(ShowBarSupport.donateURL)
    }

    private func addStatusItem(_ menu: NSMenu, title: String, ok: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = ok ? .on : .off
        menu.addItem(item)
    }

    @objc private func fixAccessibility() {
        PermissionsState.promptAccessibility()
    }

    @objc private func fixScreenRecording() {
        PermissionsState.promptScreenRecording()
    }

    @objc fileprivate func toggleLoginItem() {
        let turningOn = SMAppService.mainApp.status != .enabled
        UserDefaults.standard.set(turningOn, forKey: loginKey)
        applyLaunchAtLogin(turningOn, tellUser: true)
    }

    private func ensureLaunchAtLogin() {
        let firstChoice = UserDefaults.standard.object(forKey: loginKey) == nil
        if firstChoice {
            UserDefaults.standard.set(true, forKey: loginKey)
        }
        applyLaunchAtLogin(UserDefaults.standard.bool(forKey: loginKey), tellUser: firstChoice)
    }

    private func applyLaunchAtLogin(_ enabled: Bool, tellUser: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            guard tellUser else { return }
            let alert = NSAlert()
            alert.messageText = "Show Bar could not set launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func explainDockIcon() {
        let alert = NSAlert()
        alert.messageText = "Keep Show Bar in the Dock"
        alert.informativeText = "Right-click the Show Bar icon on the left side of the screen, then choose Options → Keep in Dock. The icon in the top menu bar stays even when this window is closed."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func recommendKeepingTheDockIcon() {
        guard !UserDefaults.standard.bool(forKey: dockTipKey) else { return }
        UserDefaults.standard.set(true, forKey: dockTipKey)
        DispatchQueue.main.async { [weak self] in
            self?.explainDockIcon()
        }
    }

    @objc fileprivate func removeApp() {
        let alert = NSAlert()
        alert.messageText = "Remove Show Bar?"
        alert.informativeText = "Show Bar moves to the Trash and stops opening when the Mac starts. This cannot be undone from the app. Install it again to bring it back."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(false, forKey: loginKey)
        try? SMAppService.mainApp.unregister()
        hover.stop()
        WindowSwitcher.shared.stop()
        do {
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Show Bar could not move itself to the Trash"
            failed.informativeText = error.localizedDescription
            failed.runModal()
            return
        }
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        AppUpdate.checkManually()
    }

    @objc private func installOfferedUpdate() {
        AppUpdate.askAgain()
    }

    @objc private func openAdmin() {
        if let adminWindow {
            adminWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingView(rootView: AdminView(model: AdminModel()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Admin"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        adminWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        hover.stop()
        WindowSwitcher.shared.stop()
        NSApp.terminate(nil)
    }

    private func syncHover() {
        if enabled && AXIsProcessTrusted() {
            hover.start()
            WindowSwitcher.shared.onWillShow = { [weak self] in
                self?.hover.dismissPreview()
            }
            WindowSwitcher.shared.start()
        } else {
            hover.stop()
            WindowSwitcher.shared.stop()
        }
        statusItem?.button?.appearsDisabled = !enabled
    }

    private func showPermissions() {
        if let permissionsWindow {
            permissionsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = PermissionsModel()
        model.refresh()
        model.dockCount = hover.iconCount
        permissionsModel = model
        let host = NSHostingView(rootView: PermissionsView(
            model: model,
            onAccessibility: { PermissionsState.promptAccessibility() },
            onScreen: { PermissionsState.promptScreenRecording() },
            onRelaunch: { AppDelegate.shared.relaunch() },
            onPreview: { AppDelegate.shared.hover.showSamplePreview() },
            onDonate: { AppDelegate.shared.openDonate() }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(max(fitted.height, 560), screenHeight - 48)
        window.setContentSize(NSSize(width: 480, height: height))
        window.center()
        permissionsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionsTimer?.invalidate()
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.pollPermissions()
        }
    }

    private func presentRateRequestIfNeeded() {
        guard UserDefaults.standard.bool(forKey: ShowBarSupport.askForRateKey) else { return }
        guard rateWindow == nil else { return }
        let host = NSHostingView(rootView: RatePrompt(onFinish: { [weak self] in
            UserDefaults.standard.set(false, forKey: ShowBarSupport.askForRateKey)
            self?.rateWindow?.close()
        }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Show Bar"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        rateWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func menuBarIcon(updateReady: Bool) -> NSImage? {
        guard let source = NSApp.applicationIconImage.copy() as? NSImage else { return nil }
        let side: CGFloat = 18
        source.size = NSSize(width: side, height: side)
        source.isTemplate = false
        guard updateReady else { return source }
        let canvas = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect)
            let ring = NSRect(x: side - 8, y: side - 8, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: ring).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: ring.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    private var menuBarDot: NSImage {
        let side: CGFloat = 12
        let canvas = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === adminWindow {
            adminWindow = nil
            return
        }
        if window === rateWindow {
            UserDefaults.standard.set(false, forKey: ShowBarSupport.askForRateKey)
            rateWindow = nil
            return
        }
        guard window === permissionsWindow else { return }
        permissionsTimer?.invalidate()
        permissionsTimer = nil
        permissionsWindow = nil
    }

    private func pollPermissions() {
        let hadAccessibility = sawAccessibility
        let hadScreen = sawScreenRecording
        permissionsModel?.refresh()
        let hasAccessibility = AXIsProcessTrusted()
        let hasScreen = CGPreflightScreenCaptureAccess()
        sawAccessibility = hasAccessibility
        sawScreenRecording = hasScreen
        permissionsModel?.dockCount = hover.iconCount
        syncHover()
        if (!hadAccessibility && hasAccessibility) || (!hadScreen && hasScreen) {
            relaunch()
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        hover.stop()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { AppUpdate.askAgain() }
    }
}

enum PermissionsState {
    static var allGranted: Bool {
        AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()
    }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func promptScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum ShowBarSupport {
    static let ownerName = "Naor Yanko"
    static let ownerEmail = "na0ryank0@gmail.com"
    static let downloadURL = URL(string: "https://github.com/rept0rix/show-bar/releases/latest")!
    static let linkedInURL = URL(string: "https://www.linkedin.com/in/naoryanko")!
    /// Mac App Store page. Leave nil until the page exists; the rating button opens this.
    static let storeURL: URL? = nil
    static let askForRateKey = "ShowBar.askForRate"
    // Replace these with your own pages before you publish.
    static let donateURL = URL(string: "https://buymeacoffee.com/na0ryank0r")!
    static let adURL = URL(string: "https://buymeacoffee.com/na0ryank0r")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4" // showbar-version
    }
}

final class PermissionsModel: ObservableObject {
    @Published var accessibility = false
    @Published var screen = false
    @Published var dockCount = 0
    @Published var previewsEnabled = true
    @Published var launchAtLogin = false
    @Published var previewSize = PreviewPreferences.sizeName
    @Published var maxWindows = PreviewPreferences.maxWindows
    @Published var showTitles = PreviewPreferences.showTitles
    @Published var dockEdge = DockPlacement.current

    var allGranted: Bool { accessibility && screen }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screen = CGPreflightScreenCaptureAccess()
        previewsEnabled = AppDelegate.shared.previewsAreEnabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        previewSize = PreviewPreferences.sizeName
        maxWindows = PreviewPreferences.maxWindows
        showTitles = PreviewPreferences.showTitles
        dockEdge = DockPlacement.current
    }
}

private enum SettingsPage: CaseIterable {
    case dock, shortcuts, permissions, app

    var title: String {
        switch self {
        case .dock: return "Dock"
        case .shortcuts: return "Shortcuts"
        case .permissions: return "Permissions"
        case .app: return "App"
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    var onAccessibility: () -> Void
    var onScreen: () -> Void
    var onRelaunch: () -> Void
    var onPreview: () -> String?
    var onDonate: () -> Void
    @State private var previewNote = ""
    @State private var showRatePrompt = false
    @State private var tab = SettingsPage.dock

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show Bar")
                        .font(.title2.weight(.semibold))
                    Text("Version \(ShowBarSupport.version)")
                        .font(.title3.weight(.semibold))
                    Text(readyText)
                        .font(.headline)
                        .foregroundStyle(model.allGranted && model.dockCount > 0 ? Color.green : Color.orange)
                }
            }

            HStack(spacing: 8) {
                Button("Show a preview now") {
                    previewNote = onPreview() ?? "Preview is open. Move the pointer away to close it."
                }
                .buttonStyle(.borderedProminent)
                Button("Rate…") { showRatePrompt = true }
                Button("Buy me a coffee", action: onDonate)
            }
            if !previewNote.isEmpty {
                Text(previewNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Section", selection: $tab) {
                ForEach(SettingsPage.allCases, id: \.self) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .dock: dockPage
                case .shortcuts: shortcutsPage
                case .permissions: permissionsPage
                case .app: appPage
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        }
        .padding(24)
        .frame(width: 520)
        .sheet(isPresented: $showRatePrompt) {
            RatePrompt(onFinish: { showRatePrompt = false })
        }
    }

    private var dockChoice: DockPlacement {
        switch model.dockEdge {
        case .left: return .left
        case .right: return .right
        case .bottom, .top: return .bottom
        }
    }

    private var dockPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The Dock cannot sit on the top edge of the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Position", selection: Binding(
                get: { dockChoice },
                set: { value in
                    DockPlacement.current = value
                    model.dockEdge = value
                    AppDelegate.shared.applyDockPosition()
                }
            )) {
                Text("Left").tag(DockPlacement.left)
                Text("Bottom").tag(DockPlacement.bottom)
                Text("Right").tag(DockPlacement.right)
            }
            .pickerStyle(.segmented)
            Toggle("Previews", isOn: Binding(
                get: { model.previewsEnabled },
                set: { value in
                    guard value != model.previewsEnabled else { return }
                    AppDelegate.shared.toggleEnabled()
                    model.refresh()
                }
            ))
            Picker("Size", selection: Binding(
                get: { model.previewSize },
                set: { value in
                    PreviewPreferences.sizeName = value
                    model.refresh()
                    AppDelegate.shared.applyPreviewPreferences()
                }
            )) {
                Text("Small").tag("small")
                Text("Medium").tag("medium")
                Text("Large").tag("large")
            }
            .pickerStyle(.segmented)
            Picker("How many", selection: Binding(
                get: { model.maxWindows },
                set: { value in
                    PreviewPreferences.maxWindows = value
                    model.refresh()
                    AppDelegate.shared.applyPreviewPreferences()
                }
            )) {
                Text("All").tag(0)
                Text("2").tag(2)
                Text("4").tag(4)
                Text("6").tag(6)
            }
            .pickerStyle(.segmented)
            Toggle("Show window names", isOn: Binding(
                get: { model.showTitles },
                set: { value in
                    PreviewPreferences.showTitles = value
                    model.refresh()
                    AppDelegate.shared.applyPreviewPreferences()
                }
            ))
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Command-Tab shows the windows. Arrows move. Release Command to switch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Clipboard")
                .font(.headline)
            Text("Control-Option-V opens what you copied. A click pastes it. Hidden passwords are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open clipboard history") {
                ClipboardShelf.shared.show()
            }
            Text("Screenshots")
                .font(.headline)
            Text("Command-Shift-3 copies the screen. Command-Shift-4 copies a selection. Nothing is saved as a file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Snap")
                .font(.headline)
            Text("Control-Option and an arrow takes half the screen. U, I, J, and K take the corners. Return fills the screen. The same shortcut puts the window back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                title: "Accessibility",
                detail: model.accessibility ? "On. Dock icons found: \(model.dockCount)." : "Off. If the switch is already on, turn it off and on again.",
                granted: model.accessibility,
                action: onAccessibility
            )
            permissionRow(
                title: "Screen Recording",
                detail: model.screen ? "On. Window pictures can be drawn." : "Off. Previews will show titles only until this is on.",
                granted: model.screen,
                action: onScreen
            )
            Button("Relaunch", action: onRelaunch)
        }
    }

    private var appPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { value in
                    guard value != model.launchAtLogin else { return }
                    AppDelegate.shared.toggleLoginItem()
                    model.refresh()
                }
            ))
            Text("The menu-bar icon stays when this window is closed. To keep the Dock icon, right-click Show Bar in the Dock and choose Options → Keep in Dock.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check for Updates…") {
                AppUpdate.checkManually()
            }
            Button("Download page") {
                NSWorkspace.shared.open(ShowBarSupport.downloadURL)
            }
            Divider()
            Text("Remove Show Bar deletes the app. It goes to the Trash, and you install it again to get it back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Remove Show Bar…", role: .destructive) {
                AppDelegate.shared.removeApp()
            }
            .buttonStyle(.bordered)
        }
    }

    private var readyText: String {
        if model.allGranted && model.dockCount > 0 {
            return "Ready"
        }
        if !model.accessibility {
            return "Waiting for Accessibility"
        }
        if !model.screen {
            return "Waiting for Screen Recording"
        }
        return "Waiting for the Dock"
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(granted ? "On" : "Allow", action: action)
                .disabled(granted)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RatePrompt: View {
    var onFinish: () -> Void
    @State private var stars = 0

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Rate Show Bar")
                .font(.title2.weight(.semibold))
            Text("If Show Bar is useful, a rating in the store helps other people find it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        stars = value
                    } label: {
                        Image(systemName: value <= stars ? "star.fill" : "star")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.yellow)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(value) stars")
                }
            }
            HStack(spacing: 10) {
                Button("Not now", action: onFinish)
                Button("Rate in the App Store") {
                    if let url = ShowBarSupport.storeURL {
                        NSWorkspace.shared.open(url)
                    }
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ShowBarSupport.storeURL == nil)
            }
            if ShowBarSupport.storeURL == nil {
                Text("The store link will go on this button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
