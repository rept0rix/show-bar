import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let shared = AppDelegate()
    private let previewsKey = "ShowBar.previewsEnabled"
    private let legacyEnabledKey = "ShowBar.enabled"
    private let loginKey = "ShowBar.launchAtLogin"
    private let dockTipKey = "ShowBar.explainedDock"
    private var statusItem: NSStatusItem!
    private var captureItem: NSStatusItem!
    private var cropItem: NSStatusItem!
    private var clipboardItem: NSStatusItem!
    private var snapItem: NSStatusItem!
    fileprivate var hover = HoverController()
    private var permissionsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var rateWindow: NSWindow?
    private var offeredUpdate: String?
    private var permissionsModel: PermissionsModel?
    private var permissionsTimer: Timer?
    private var sawAccessibility = false
    private var sawScreenRecording = false

    var previewsAreEnabled: Bool {
        get {
            if let obj = UserDefaults.standard.object(forKey: previewsKey) {
                return (obj as? Bool) ?? true
            }
            if let obj = UserDefaults.standard.object(forKey: legacyEnabledKey) {
                return (obj as? Bool) ?? true
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: previewsKey)
            UserDefaults.standard.set(newValue, forKey: legacyEnabledKey)
            syncHover()
        }
    }

    var commandTabIsEnabled: Bool {
        get { WindowSwitcher.shared.commandTabEnabled }
        set {
            WindowSwitcher.shared.commandTabEnabled = newValue
            syncHover()
        }
    }

    fileprivate func applyPreviewPreferences() {
        hover.reloadAppearance()
    }

    fileprivate func applyDockPosition() {
        hover.noteDockMoved()
    }

    private var enabled: Bool {
        get { previewsAreEnabled }
        set { previewsAreEnabled = newValue }
    }

    static func main() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.naoryanko.showbar"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if CommandLine.arguments.contains("--relaunch") {
            for _ in 0..<30 {
                let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
                if others.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.08)
            }
        } else {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let others = running.filter { $0.processIdentifier != currentPID }
            if let existing = others.first {
                existing.activate()
                exit(0)
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sawAccessibility = AXIsProcessTrusted()
        sawScreenRecording = CGPreflightScreenCaptureAccess()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        captureItem = NSStatusBar.system.statusItem(withLength: 28)
        cropItem = NSStatusBar.system.statusItem(withLength: 28)
        clipboardItem = NSStatusBar.system.statusItem(withLength: 28)
        snapItem = NSStatusBar.system.statusItem(withLength: 28)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(rememberFrontApp),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        UNUserNotificationCenter.current().delegate = self
        noteUpdate(nil)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installQuickShots()
        DockAutohide.restore()
        ClipboardShelf.shared.start()
        ShotShelf.cleanupLaunchTempFiles()
        syncHover()
        ensureLaunchAtLogin()
        let isFirstLaunch = UserDefaults.standard.object(forKey: "ShowBar.hasLaunchedBefore") == nil
        if isFirstLaunch {
            UserDefaults.standard.set(true, forKey: "ShowBar.hasLaunchedBefore")
        }
        Telemetry.shared.track("app_launched", params: [
            "first_launch": isFirstLaunch ? "true" : "false",
            "accessibility": AXIsProcessTrusted() ? "true" : "false",
            "screen_recording": CGPreflightScreenCaptureAccess() ? "true" : "false"
        ])
        let lastOnboardingVersion = UserDefaults.standard.string(forKey: "ShowBar.lastOnboardingVersion")
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "ShowBar.hasCompletedOnboarding") && (lastOnboardingVersion == ShowBarSupport.version)
        if !hasCompletedOnboarding || !PermissionsState.allGranted {
            showOnboarding()
        }
        recommendKeepingTheDockIcon()
        AppUpdate.restoreBadge()
        AppUpdate.checkOnLaunch()
        AppGate.checkPolicyOnLaunch()
        previewAfterUpdateIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.presentRateRequestIfNeeded()
        }
    }


    func noteUpdate(_ version: String?) {
        offeredUpdate = version
        let ready = version != nil
        statusItem?.length = ready ? 32 : NSStatusItem.squareLength
        statusItem?.button?.image = menuBarIcon(updateReady: ready)
        statusItem?.button?.toolTip = version.map { "Show Bar — update \($0) is ready" } ?? "Show Bar"
    }

    func relaunchAfterUpdate() {
        WindowSwitcher.shared.stop()
        relaunch()
    }

    func pauseForUpdate() {
        hover.stop()
        WindowSwitcher.shared.stop()
    }

    func resumeAfterUpdateFailure() {
        syncHover()
    }

    /// The first capture after an update is the slow one. Mark the version as previewed so the windows are ready.
    private func previewAfterUpdateIfNeeded() {
        let key = "ShowBar.previewedVersion"
        let version = ShowBarSupport.version
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let lastOnboardingVersion = UserDefaults.standard.string(forKey: "ShowBar.lastOnboardingVersion")
            let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "ShowBar.hasCompletedOnboarding") && (lastOnboardingVersion == ShowBarSupport.version)
            if !hasCompletedOnboarding || !PermissionsState.allGranted {
                showOnboarding()
            } else {
                showPermissions()
            }
        }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        WindowSnap.rememberFront()
        ClipboardShelf.shared.rememberTarget()
        populateMenu(menu)
    }

    private func menuIcon(_ symbol: String, tint: NSColor? = nil) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        if let tint {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            return tinted
        }
        image.isTemplate = true
        return image
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if let version = offeredUpdate {
            menu.addItem(updateButtonItem(version))
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: "Show Bar  v\(ShowBarSupport.version)", action: nil, keyEquivalent: "")
        header.image = menuIcon("sparkles.rectangle.stack")
        header.isEnabled = false
        menu.addItem(header)

        let accessibilityOn = AXIsProcessTrusted()
        let screenOn = CGPreflightScreenCaptureAccess()
        if !accessibilityOn || !screenOn {
            let permsItem = NSMenuItem(
                title: "Grant Required Permissions…",
                action: #selector(openPermissions),
                keyEquivalent: ""
            )
            permsItem.target = self
            permsItem.image = menuIcon("exclamationmark.shield.fill", tint: .systemOrange)
            menu.addItem(permsItem)
        }
        menu.addItem(.separator())

        let previewsItem = NSMenuItem(
            title: "Window Previews",
            action: #selector(togglePreviews),
            keyEquivalent: ""
        )
        previewsItem.target = self
        previewsItem.state = previewsAreEnabled ? .on : .off
        previewsItem.image = menuIcon("macwindow.on.rectangle")
        menu.addItem(previewsItem)

        let cmdTabItem = NSMenuItem(
            title: "Command-Tab Switcher",
            action: #selector(toggleCommandTab),
            keyEquivalent: ""
        )
        cmdTabItem.target = self
        cmdTabItem.state = commandTabIsEnabled ? .on : .off
        cmdTabItem.image = menuIcon("command.square")
        menu.addItem(cmdTabItem)

        menu.addItem(.separator())

        let shot = NSMenuItem(title: "Screenshot", action: nil, keyEquivalent: "")
        shot.image = menuIcon("camera.viewfinder")
        let shotMenu = NSMenu()
        let thisItem = NSMenuItem(title: "Copy This Screen    ⌘⇧3", action: #selector(copyThisScreen), keyEquivalent: "")
        thisItem.target = self
        thisItem.image = menuIcon("display")
        shotMenu.addItem(thisItem)
        if NSScreen.screens.count > 1 {
            let allItem = NSMenuItem(title: "Copy Every Screen", action: #selector(copyAllScreens), keyEquivalent: "")
            allItem.target = self
            allItem.image = menuIcon("rectangle.on.rectangle")
            shotMenu.addItem(allItem)
        }
        let area = NSMenuItem(title: "Copy Selection    ⌘⇧4", action: #selector(copySelection), keyEquivalent: "")
        area.target = self
        area.image = menuIcon("rectangle.dashed")
        shotMenu.addItem(area)
        shot.submenu = shotMenu
        menu.addItem(shot)

        let isRec = VideoRecorder.shared.isRecording
        let recTitle = isRec ? "Stop Screen Recording" : "Record Screen"
        let recItem = NSMenuItem(title: recTitle, action: #selector(toggleScreenRecording), keyEquivalent: "")
        recItem.target = self
        recItem.image = menuIcon(isRec ? "stop.circle.fill" : "record.circle", tint: isRec ? .systemRed : nil)
        menu.addItem(recItem)

        let clips = NSMenuItem(title: "Clipboard History", action: nil, keyEquivalent: "")
        clips.image = menuIcon("doc.on.clipboard")
        let clipMenu = NSMenu()
        let recent = Array(ClipboardShelf.shared.clips.prefix(6))
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing copied yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            clipMenu.addItem(empty)
        } else {
            for clip in recent {
                let item = NSMenuItem(title: ClipboardShelf.shared.menuTitle(for: clip), action: #selector(pasteClip(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clip.id.uuidString
                item.image = menuIcon(clip.kind == .image ? "photo" : (clip.kind == .link ? "link" : "doc.text"))
                clipMenu.addItem(item)
            }
        }
        clipMenu.addItem(.separator())
        let history = NSMenuItem(title: "Open Clipboard Shelf    ⌃⌥V", action: #selector(showClipboard), keyEquivalent: "")
        history.target = self
        history.image = menuIcon("clock.arrow.circlepath")
        clipMenu.addItem(history)
        clips.submenu = clipMenu
        menu.addItem(clips)

        let snap = NSMenuItem(title: "Snap Window", action: nil, keyEquivalent: "")
        snap.image = menuIcon("rectangle.split.2x1")
        let snapMenu = NSMenu()
        for zone in SnapZone.allCases {
            let item = NSMenuItem(title: zone.title, action: #selector(snapFront(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = zone.rawValue
            item.image = menuIcon("macwindow")
            snapMenu.addItem(item)
        }
        snap.submenu = snapMenu
        menu.addItem(snap)

        menu.addItem(.separator())

        let tourItem = NSMenuItem(title: "Interactive Desktop Tour…", action: #selector(openOnboarding), keyEquivalent: "")
        tourItem.target = self
        tourItem.image = menuIcon("sparkles")
        menu.addItem(tourItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openPermissions), keyEquivalent: ",")
        settings.target = self
        settings.image = menuIcon("gearshape")
        menu.addItem(settings)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.image = menuIcon("power")
        menu.addItem(login)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.image = menuIcon("arrow.triangle.2.circlepath")
        menu.addItem(updates)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Show Bar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = menuIcon("xmark.circle")
        menu.addItem(quit)
        statusItem.button?.appearsDisabled = !previewsAreEnabled && !commandTabIsEnabled
    }

    @objc fileprivate func togglePreviews() {
        previewsAreEnabled.toggle()
        permissionsModel?.refresh()
    }

    @objc fileprivate func toggleCommandTab() {
        commandTabIsEnabled.toggle()
        permissionsModel?.refresh()
    }

    @objc fileprivate func toggleEnabled() {
        togglePreviews()
    }

    @objc func openOnboarding() {
        showOnboarding()
    }

    @objc func openPermissions() {
        showPermissions()
    }

    @objc private func resetCommandTab() {
        WindowSwitcher.shared.reset()
    }

    @objc private func showSample() {
        Telemetry.shared.track("sample_preview_requested")
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

    private func installQuickShots() {
        if let button = captureItem.button {
            button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Copy this screen")
            button.image?.isTemplate = true
            button.toolTip = "Show Bar: Capture Screen to Shelf (⌘⇧3)"
            button.target = self
            button.action = #selector(copyScreen)
        }
        if let button = cropItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Copy a selection")
            button.image?.isTemplate = true
            button.toolTip = "Show Bar: Capture Selection Area to Shelf (⌘⇧4)"
            button.target = self
            button.action = #selector(copySelection)
        }
        if let button = clipboardItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard history")
            button.image?.isTemplate = true
            button.toolTip = "Show Bar: Clipboard History (⌃⌥V)"
            button.target = self
            button.action = #selector(showClipboard)
        }
        if let button = snapItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Move this window to half the screen")
            button.image?.isTemplate = true
            button.toolTip = "Show Bar: Snap Window to Half (⌃⌥← / ⌃⌥→)"
            button.target = self
            button.action = #selector(snapFrontHalf)
        }
        VideoRecorder.shared.onStatusChanged = { [weak self] isRec, elapsed in
            DispatchQueue.main.async {
                guard let button = self?.captureItem.button else { return }
                if isRec {
                    button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording screen")
                    button.image?.isTemplate = false
                    button.contentTintColor = .systemRed
                    let m = Int(elapsed) / 60
                    let s = Int(elapsed) % 60
                    button.toolTip = String(format: "Recording (%02d:%02d) — Click to stop and edit", m, s)
                } else {
                    button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Copy this screen")
                    button.image?.isTemplate = true
                    button.contentTintColor = nil
                    button.toolTip = "Copy this screen"
                }
            }
        }
    }

    @objc private func rememberFrontApp() {
        WindowSnap.rememberFront()
        ClipboardShelf.shared.rememberTarget()
    }

    @objc private func snapFrontHalf() {
        WindowSnap.cycleFrontHalf()
    }

    @objc private func toggleScreenRecording() {
        VideoRecorder.shared.toggleRecording()
    }

    @objc private func copyScreen() {
        if VideoRecorder.shared.isRecording {
            VideoRecorder.shared.stopRecording()
            return
        }
        ShotShelf.shared.captureScreen()
    }

    @objc private func copyThisScreen() {
        ShotShelf.shared.captureScreenUnderPointer()
    }

    @objc private func copyAllScreens() {
        ShotShelf.shared.captureAllScreens()
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
        Telemetry.shared.track("donate_clicked")
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
        alert.messageText = "Move Show Bar to the Trash?"
        alert.informativeText = "Show Bar will quit and the app will be deleted. It will not open the next time the Mac starts. This cannot be undone. To use Show Bar again, install it from the download page."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Show Bar is still installed"
            failed.informativeText = "The app could not be moved to the Trash, so nothing was removed. \(error.localizedDescription)"
            failed.runModal()
            return
        }
        UserDefaults.standard.set(false, forKey: loginKey)
        try? SMAppService.mainApp.unregister()
        hover.stop()
        WindowSwitcher.shared.stop()
        NSApp.terminate(nil)
    }

    private func updateButtonItem(_ version: String) -> NSMenuItem {
        let item = NSMenuItem()
        let button = NSButton(title: "Update to \(version)", target: self, action: #selector(installOfferedUpdate))
        button.bezelStyle = .push
        button.controlSize = .large
        button.setButtonType(.momentaryPushIn)
        button.frame = NSRect(x: 14, y: 8, width: 212, height: 30)
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        wrap.addSubview(button)
        item.view = wrap
        return item
    }

    @objc private func checkForUpdates() {
        AppUpdate.checkManually()
    }

    @objc private func installOfferedUpdate() {
        AppUpdate.askAgain()
    }

    func applicationWillTerminate(_ notification: Notification) {
    }

    @objc private func quit() {
        hover.stop()
        WindowSwitcher.shared.stop()
        NSApp.terminate(nil)
    }

    private func syncHover() {
        if previewsAreEnabled && AXIsProcessTrusted() {
            hover.start()
        } else {
            hover.stop()
        }
        if AXIsProcessTrusted() {
            WindowSwitcher.shared.onWillShow = { [weak self] in
                self?.hover.dismissPreview()
            }
            WindowSwitcher.shared.start()
        } else {
            WindowSwitcher.shared.stop()
        }
        statusItem?.button?.appearsDisabled = !previewsAreEnabled && !commandTabIsEnabled
    }

final class DesktopTourWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc key
            AppDelegate.shared.closeOnboarding()
            return
        }
        super.keyDown(with: event)
    }
}

    func closeOnboarding() {
        UserDefaults.standard.set(true, forKey: "ShowBar.hasCompletedOnboarding")
        UserDefaults.standard.set(ShowBarSupport.version, forKey: "ShowBar.lastOnboardingVersion")
        onboardingWindow?.close()
        onboardingWindow = nil
        syncHover()
    }

    func showOnboarding() {
        Telemetry.shared.track("onboarding_view_opened")
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = permissionsModel ?? PermissionsModel()
        model.refresh()
        model.dockCount = hover.iconCount
        permissionsModel = model

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let hudWidth: CGFloat = min(860, screen.visibleFrame.width - 40)
        let hudHeight: CGFloat = 360
        let hudX = screen.visibleFrame.minX + (screen.visibleFrame.width - hudWidth) / 2
        let hudY = screen.visibleFrame.maxY - hudHeight - 18
        let windowRect = NSRect(x: hudX, y: hudY, width: hudWidth, height: hudHeight)

        let window = DesktopTourWindow(contentRect: windowRect)
        window.minSize = windowRect.size
        window.maxSize = windowRect.size

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: windowRect.size))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.isEmphasized = true
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.24, alpha: 0.34).cgColor
        root.layer?.cornerRadius = 24
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1.2
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.34).cgColor

        let hostingView = NSHostingView(rootView: DesktopTourOverlayView(
            model: model,
            onAccessibility: { PermissionsState.promptAccessibility() },
            onScreen: { PermissionsState.promptScreenRecording() },
            onPreview: { AppDelegate.shared.hover.showSamplePreview() },
            onFinish: { [weak self] in self?.closeOnboarding() },
            onOpenSettings: { [weak self] in
                self?.closeOnboarding()
                self?.showPermissions()
            }
        ))
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        hostingView.frame = NSRect(origin: .zero, size: windowRect.size)
        hostingView.autoresizingMask = [.width, .height]
        root.addSubview(hostingView)
        window.contentView = root
        window.delegate = self
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
        NSApp.activate(ignoringOtherApps: true)
        startPermissionsTimer()
    }

    func showPermissions() {
        Telemetry.shared.track("permissions_view_opened")
        if let permissionsWindow {
            permissionsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = permissionsModel ?? PermissionsModel()
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Show Bar Settings & Guide"
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(max(fitted.height, 600), screenHeight - 48)
        let size = NSSize(width: 560, height: height)
        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.isEmphasized = true
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.24, alpha: 0.34).cgColor
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(size)
        window.center()
        permissionsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPermissionsTimer()
    }

    private func startPermissionsTimer() {
        permissionsTimer?.invalidate()
        // resource: active 0.8 — runs only while the permissions window is open.
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
            source.draw(in: NSRect(x: 0, y: 0, width: side - 2, height: side - 2))
            let ring = NSRect(x: side - 9, y: side - 9, width: 9, height: 9)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: ring).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: ring.insetBy(dx: 1.2, dy: 1.2)).fill()
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === rateWindow {
            UserDefaults.standard.set(false, forKey: ShowBarSupport.askForRateKey)
            rateWindow = nil
            return
        }
        if window === onboardingWindow {
            onboardingWindow = nil
        }
        if window === permissionsWindow {
            permissionsWindow = nil
        }
        if onboardingWindow == nil && permissionsWindow == nil {
            permissionsTimer?.invalidate()
            permissionsTimer = nil
        }
    }

    private func pollPermissions() {
        let hadAccessibility = sawAccessibility
        let hadScreen = sawScreenRecording
        permissionsModel?.refresh()
        let hasAccessibility = AXIsProcessTrusted()
        let hasScreen = CGPreflightScreenCaptureAccess()
        if hadAccessibility != hasAccessibility || hadScreen != hasScreen {
            sawAccessibility = hasAccessibility
            sawScreenRecording = hasScreen
            syncHover()
        }
        let currentDockCount = hover.iconCount
        if permissionsModel?.dockCount != currentDockCount {
            permissionsModel?.dockCount = currentDockCount
        }
        if (!hadAccessibility && hasAccessibility) || (!hadScreen && hasScreen) {
            relaunch()
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--relaunch"]
        hover.stop()
        WindowSwitcher.shared.stop()
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
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func resetScreenRecordingPermission() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.naoryanko.showbar"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        try? process.run()
        process.waitUntilExit()
        promptScreenRecording()
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.3" // showbar-version
    }
}

final class PermissionsModel: ObservableObject {
    @Published var accessibility = false
    @Published var screen = false
    @Published var dockCount = 0
    @Published var previewsEnabled = true
    @Published var commandTabEnabled = true
    @Published var launchAtLogin = false
    @Published var previewSize = PreviewPreferences.sizeName
    @Published var maxWindows = PreviewPreferences.maxWindows
    @Published var showTitles = PreviewPreferences.showTitles
    @Published var dockEdge = DockPlacement.current

    var allGranted: Bool { accessibility && screen }

    func refresh() {
        let newAccessibility = AXIsProcessTrusted()
        if accessibility != newAccessibility { accessibility = newAccessibility }

        let newScreen = CGPreflightScreenCaptureAccess()
        if screen != newScreen { screen = newScreen }

        let newPreviewsEnabled = AppDelegate.shared.previewsAreEnabled
        if previewsEnabled != newPreviewsEnabled { previewsEnabled = newPreviewsEnabled }

        let newCommandTabEnabled = AppDelegate.shared.commandTabIsEnabled
        if commandTabEnabled != newCommandTabEnabled { commandTabEnabled = newCommandTabEnabled }

        let newLaunchAtLogin = SMAppService.mainApp.status == .enabled
        if launchAtLogin != newLaunchAtLogin { launchAtLogin = newLaunchAtLogin }

        let newPreviewSize = PreviewPreferences.sizeName
        if previewSize != newPreviewSize { previewSize = newPreviewSize }

        let newMaxWindows = PreviewPreferences.maxWindows
        if maxWindows != newMaxWindows { maxWindows = newMaxWindows }

        let newShowTitles = PreviewPreferences.showTitles
        if showTitles != newShowTitles { showTitles = newShowTitles }

        let newDockEdge = DockPlacement.current
        if dockEdge != newDockEdge { dockEdge = newDockEdge }
    }
}

private enum SettingsPage: CaseIterable {
    case permissions, guide, dock, shortcuts, shots, app

    var title: String {
        switch self {
        case .permissions: return "Permissions"
        case .guide: return "Features Guide"
        case .dock: return "Dock"
        case .shortcuts: return "Shortcuts"
        case .shots: return "Shots"
        case .app: return "App"
        }
    }
}

private struct BuyCoffeeButton: View {
    var action: () -> Void
    @State private var isHovered = false
    @State private var steamRising = false
    @State private var cupWiggle = false

    private let bgTop = Color(red: 1.0, green: 0.88, blue: 0.16)
    private let bgBottom = Color(red: 1.0, green: 0.77, blue: 0.0)
    private let textDark = Color(red: 0.14, green: 0.11, blue: 0.06)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack(alignment: .top) {
                    // Gentle rising steam animation
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(textDark.opacity(steamRising ? 0.08 : 0.45))
                            .frame(width: 1.6, height: 4)
                            .offset(y: steamRising ? -6 : -1)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(textDark.opacity(steamRising ? 0.45 : 0.08))
                            .frame(width: 1.6, height: 4)
                            .offset(y: steamRising ? -1 : -6)
                    }
                    .offset(x: -1, y: -3)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: steamRising)

                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 12, weight: .bold))
                        .rotationEffect(.degrees(isHovered ? (cupWiggle ? 10 : -10) : 0))
                        .animation(
                            isHovered
                                ? .easeInOut(duration: 0.2).repeatForever(autoreverses: true)
                                : .easeOut(duration: 0.15),
                            value: cupWiggle
                        )
                }

                Text("Buy me a coffee")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(textDark)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                LinearGradient(
                    colors: isHovered
                        ? [Color(red: 1.0, green: 0.93, blue: 0.28), Color(red: 1.0, green: 0.82, blue: 0.05)]
                        : [bgTop, bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8)
            )
            .shadow(
                color: Color(red: 1.0, green: 0.78, blue: 0.0).opacity(isHovered ? 0.5 : 0.18),
                radius: isHovered ? 5 : 2,
                y: isHovered ? 1.5 : 0.8
            )
            .scaleEffect(isHovered ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.65)) {
                isHovered = hovering
                cupWiggle = hovering
            }
        }
        .onAppear {
            steamRising = true
        }
    }
}

struct GlassVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
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
    @State private var tab: SettingsPage
    @State private var shotAfter = ShotPreferences.after
    @State private var saveFolderDisplay = ShotPreferences.saveDirectory.path

    init(
        model: PermissionsModel,
        onAccessibility: @escaping () -> Void,
        onScreen: @escaping () -> Void,
        onRelaunch: @escaping () -> Void,
        onPreview: @escaping () -> String?,
        onDonate: @escaping () -> Void
    ) {
        self.model = model
        self.onAccessibility = onAccessibility
        self.onScreen = onScreen
        self.onRelaunch = onRelaunch
        self.onPreview = onPreview
        self.onDonate = onDonate
        _tab = State(initialValue: model.allGranted ? .guide : .permissions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Show Bar")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("v\(ShowBarSupport.version)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 0.8))
                    }
                    Text(readyText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.allGranted && model.dockCount > 0 ? Color.green : Color.orange)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Show a preview now") {
                        previewNote = onPreview() ?? "Preview is open. Move pointer away to close."
                    }
                    .buttonStyle(TourGlassButtonStyle())
                    BuyCoffeeButton(action: onDonate)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )

            if !model.allGranted {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Permissions Required")
                            .font(.subheadline.weight(.semibold))
                        Text("Show Bar needs Accessibility & Screen Recording to display window previews.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tab != .permissions {
                        Button("Review Permissions") {
                            tab = .permissions
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.35), lineWidth: 1))
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
                case .permissions: permissionsPage
                case .guide: guidePage
                case .dock: dockPage
                case .shortcuts: shortcutsPage
                case .shots: shotsPage
                case .app: appPage
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
        }
        .padding(.horizontal, 22)
        .padding(.top, 32)
        .padding(.bottom, 22)
        .frame(width: 560)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 85)
        }
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
            Toggle("Window previews", isOn: Binding(
                get: { model.previewsEnabled },
                set: { value in
                    guard value != model.previewsEnabled else { return }
                    AppDelegate.shared.togglePreviews()
                    model.refresh()
                }
            ))
            Group {
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
            .disabled(!model.previewsEnabled)
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Command-Tab window switcher", isOn: Binding(
                get: { model.commandTabEnabled },
                set: { value in
                    guard value != model.commandTabEnabled else { return }
                    AppDelegate.shared.toggleCommandTab()
                    model.refresh()
                }
            ))
            Text("Command-Tab shows the windows, including what is open on Desktop 2 and Desktop 3. A card marked Desktop 2 switches straight to that desktop. Arrows move. Release Command to switch. When turned off, the default macOS Command-Tab switcher is used.")
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
            Text("Command-Shift-3 copies this screen. Command-Shift-4 drags a part, and the pointer turns into a crosshair. The Shots tab chooses whether the shelf stays, saves, or closes.")
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

    private var shotsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("After a screenshot")
                .font(.headline)
            Picker("After a screenshot", selection: Binding(
                get: { shotAfter },
                set: { mode in
                    shotAfter = mode
                    ShotPreferences.after = mode
                }
            )) {
                ForEach(ShotAfter.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(shotAfter.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Several shots sit together in the corner. Click a picture, or the pencil, to open it large and mark it up. Done puts the edited picture back. The X on a picture leaves it out. Copy all puts the remaining pictures on the clipboard as files, so one paste sends all of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Save Location")
                    .font(.headline)
                Text("Folder where screenshots are saved when clicking Save or using auto-save modes:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(saveFolderDisplay)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Select Folder"
                        panel.message = "Choose destination folder for screenshots"
                        panel.directoryURL = ShotPreferences.saveDirectory
                        if panel.runModal() == .OK, let url = panel.url {
                            ShotPreferences.saveDirectory = url
                            saveFolderDisplay = url.path
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if ShotPreferences.isCustomDirectory {
                        Button("Reset to Desktop") {
                            ShotPreferences.resetSaveDirectory()
                            saveFolderDisplay = ShotPreferences.saveDirectory.path
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ShotPreferences.saveDirectory.path)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text("The camera and the dashed rectangle in the menu bar take a screenshot without opening this menu. On a window preview, the split button snaps the window left and right, and the camera copies that window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var guidePage: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Interactive Onboarding Tour")
                            .font(.subheadline.weight(.semibold))
                        Text("Prefer a step-by-step guided walkthrough?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Launch Desktop Tour →") {
                        AppDelegate.shared.showOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("How Show Bar upgrades your Mac experience:")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                guideCard(
                    icon: "macwindow.on.rectangle",
                    iconColor: .blue,
                    title: "1. Dock Window Previews",
                    badge: "Exclusive to Show Bar",
                    summary: "Hover over any app icon in the Dock to see live thumbnail previews of all its open windows.",
                    whyBetter: "Native macOS Dock shows nothing on hover. Show Bar lets you bring any window to front, snap it, or close it right from the preview card.",
                    howToUse: "Just hover your mouse over any running app icon in your Dock!"
                )

                guideCard(
                    icon: "square.stack.3d.down.right.fill",
                    iconColor: .orange,
                    title: "2. Multi-Shot Screenshot Shelf",
                    badge: "No Desktop Clutter",
                    summary: "Screenshots stack neatly in a floating corner shelf instead of cluttering your desktop.",
                    whyBetter: "macOS dumps separate files on your desktop. Show Bar stacks screenshots together: mark them up, reorder them, and click 'Copy All' to paste all of them at once in WhatsApp or email.",
                    howToUse: "Press ⌘⇧3 (Screen) / ⌘⇧4 (Selection) or click the Camera in the menu bar."
                )

                guideCard(
                    icon: "doc.on.clipboard.fill",
                    iconColor: .green,
                    title: "3. Clipboard History (Multi-Copy)",
                    badge: "Never Lose Anything",
                    summary: "Recalls everything you copied — texts, links, code, and images.",
                    whyBetter: "Native macOS only remembers the last copied item. Show Bar saves your history with instant search, while safely ignoring password manager items.",
                    howToUse: "Press ⌃⌥V (Control-Option-V) or click the document icon in the menu bar."
                )

                guideCard(
                    icon: "rectangle.split.2x1.fill",
                    iconColor: .purple,
                    title: "4. Window Snapping",
                    badge: "No Fullscreen Lock",
                    summary: "Snap windows to left/right halves or corners in an instant.",
                    whyBetter: "Native Split View locks your workspace into fullscreen. Show Bar snaps windows smoothly in normal desktop mode without locking.",
                    howToUse: "Press ⌃⌥ + Arrow keys or click the split icon on any preview card."
                )

                guideCard(
                    icon: "command.square.fill",
                    iconColor: .red,
                    title: "5. Visual Command-Tab Switcher",
                    badge: "Multi-Desktop Spaces",
                    summary: "See actual window previews when pressing Command-Tab, across all Desktops.",
                    whyBetter: "Native Command-Tab shows only small app icons. Show Bar shows full window thumbnails and lets you jump directly between Desktops.",
                    howToUse: "Hold ⌘ and press Tab, then use arrow keys to navigate."
                )
            }
            .padding(.trailing, 4)
        }
        .frame(maxHeight: 330)
    }

    private func guideCard(
        icon: String,
        iconColor: Color,
        title: String,
        badge: String,
        summary: String,
        whyBetter: String,
        howToUse: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.headline)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(iconColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(iconColor.opacity(0.12), in: Capsule())
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 4) {
                Text("★ Why better:")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(whyBetter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text("👉 How:")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                Text(howToUse)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("How to grant permissions in 2 simple steps:")
                    .font(.subheadline.weight(.semibold))
                Text("Click each button below to open macOS System Settings, then turn the toggle ON for Show Bar. It will update here automatically!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )

            permissionCard(
                icon: "accessibility",
                iconColor: .blue,
                title: "1. Accessibility",
                detail: model.accessibility
                    ? "Active ✓. Dock icons found: \(model.dockCount). Window hover & snapping ready."
                    : "Allows Show Bar to detect when you hover over Dock icons, snap windows, and switch apps.",
                granted: model.accessibility,
                buttonTitle: "Open Accessibility Settings →",
                action: onAccessibility
            )

            permissionCard(
                icon: "record.circle",
                iconColor: .purple,
                title: "2. Screen Recording",
                detail: model.screen
                    ? "Active ✓. Live window thumbnail previews are enabled."
                    : "Allows Show Bar to draw live thumbnail previews of windows and save screenshots to the shelf. All rendering is 100% on-device.",
                granted: model.screen,
                buttonTitle: "Open Screen Recording Settings →",
                action: onScreen
            )

            if !model.screen {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Note: After toggling Screen Recording in System Settings, macOS will restart Show Bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if model.allGranted {
                    Label("All permissions active", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Open Features Guide →") {
                        tab = .guide
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Relaunch Show Bar", action: onRelaunch)
                        .buttonStyle(.bordered)
                    if !model.screen {
                        Button("Reset Permission") {
                            PermissionsState.resetScreenRecordingPermission()
                        }
                    }
                }
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("100% Private & Local. No screen data, images, or keystrokes ever leave your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Guided Onboarding Wizard →") {
                    AppDelegate.shared.showOnboarding()
                }
                .buttonStyle(.link)
                .font(.caption.weight(.semibold))
            }
        }
    }

    private func permissionCard(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    if granted {
                        Text("Active ✓")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(granted ? 0.03 : 0.06),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(granted ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
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
            DisclosureGroup("Uninstall") {
                Text("This deletes Show Bar. The app goes to the Trash and quits. It will not open the next time the Mac starts. To use it again, install it from the download page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Move Show Bar to the Trash…") {
                    AppDelegate.shared.removeApp()
                }
                .foregroundStyle(.red)
            }
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

// MARK: - Keycap UI Components
struct KeyCapBadge: View {
    let key: String
    var isSpecial: Bool = false

    var body: some View {
        Text(key)
            .font(.system(size: 13.5, weight: .bold, design: .rounded))
            .foregroundStyle(isSpecial ? Color.yellow : Color.white)
            .padding(.horizontal, key.count > 2 ? 8 : 7)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(white: 0.28).opacity(0.95),
                                Color(white: 0.16).opacity(0.95)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.40), Color.white.opacity(0.12)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 2, x: 0, y: 1.5)
            )
    }
}

struct KeyComboView: View {
    let keys: [String]
    var label: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<keys.count, id: \.self) { index in
                KeyCapBadge(key: keys[index])
                if index < keys.count - 1 {
                    Text("+")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.70))
                }
            }
            if let label {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.leading, 3)
            }
        }
    }
}

// MARK: - Unified iOS Glass Tour Button Styles (Single Consistent Palette)
struct TourPrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.96 : 0.50))
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(configuration.isPressed ? 0.30 : 0.22),
                                Color.white.opacity(configuration.isPressed ? 0.20 : 0.12)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.50), Color.white.opacity(0.18)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct TourActionButtonStyle: ButtonStyle {
    var accentColor: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(configuration.isPressed ? 0.28 : 0.20),
                                Color.white.opacity(configuration.isPressed ? 0.18 : 0.11)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.45), Color.white.opacity(0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct TourGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.24 : 0.14))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct DesktopTourOverlayView: View {
    @ObservedObject var model: PermissionsModel
    var onAccessibility: () -> Void
    var onScreen: () -> Void
    var onPreview: () -> String?
    var onFinish: () -> Void
    var onOpenSettings: () -> Void

    @State private var step: Int = 0

    // Live Detection States
    @State private var hasTakenFirstShot = false
    @State private var shotCount = 0
    @State private var hasOpenedClipboard = false
    @State private var hasDockHover = false
    @State private var dockApp = ""
    @State private var samplePreviewActive = false
    @State private var hasUsedCommandTab = false

    private let totalSteps = 7

    var body: some View {
        VStack(spacing: 12) {
            // Header: Step dots + title + Exit button
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Color.white.opacity(0.95) : (i < step ? Color.white.opacity(0.55) : Color.white.opacity(0.20)))
                            .frame(width: i == step ? 24 : 8, height: 6)
                            .animation(.spring(response: 0.3), value: step)
                    }
                }

                Spacer()

                Text(stepBadgeTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))

                Spacer()

                Button(action: onFinish) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Close")
                    }
                }
                .buttonStyle(TourGlassButtonStyle())
            }

            Divider().overlay(Color.white.opacity(0.16))

            // Body
            Group {
                switch step {
                case 0: welcomeStep
                case 1: firstShotStep
                case 2: multiShotStep
                case 3: clipboardStep
                case 4: dockPreviewsStep
                case 5: commandTabStep
                case 6: readyStep
                default: welcomeStep
                }
            }
            .frame(width: 824, height: 224)

            Divider().overlay(Color.white.opacity(0.16))

            // Bottom Bar
            HStack {
                if step > 0 {
                    Button(action: {
                        AppDelegate.shared.hover.dismissPreview()
                        withAnimation(.easeInOut(duration: 0.2)) { step -= 1 }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left")
                            Text("Previous")
                        }
                    }
                    .buttonStyle(TourGlassButtonStyle())
                }

                Spacer()

                nextStepButton
            }
        }
        .padding(18)
        .frame(width: 860, height: 360)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.white.opacity(0.20), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowBar.screenshotCaptured"))) { note in
            let count = (note.userInfo?["count"] as? Int) ?? 1
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                hasTakenFirstShot = true
                shotCount = count
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowBar.clipboardOpened"))) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                hasOpenedClipboard = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowBar.dockPreviewShown"))) { note in
            let app = (note.userInfo?["app"] as? String) ?? ""
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                hasDockHover = true
                dockApp = app
                samplePreviewActive = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowBar.commandTabShown"))) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                hasUsedCommandTab = true
            }
        }
    }

    private var stepBadgeTitle: String {
        switch step {
        case 0: return "Step 1 of 7 · Permissions Setup"
        case 1: return "Step 2 of 7 · Floating Screenshot Shelf"
        case 2: return "Step 3 of 7 · Stack Multiple Screenshots & Copy All"
        case 3: return "Step 4 of 7 · Clipboard History"
        case 4: return "Step 5 of 7 · Live Dock Window Previews & Snap"
        case 5: return "Step 6 of 7 · Visual Command-Tab Switcher"
        case 6: return "Step 7 of 7 · All Set"
        default: return "Show Bar Guide"
        }
    }

    // MARK: - Step 0: Permissions Setup
    private var welcomeStep: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Two macOS Permissions")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Everything runs 100% locally on your Mac. Turn on both permissions to unlock Dock previews and screenshots:")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer()

                if model.allGranted {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Permissions Ready")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
                }
            }

            VStack(spacing: 10) {
                permissionRow(
                    icon: "hand.raised.fill",
                    title: "1. Accessibility",
                    subtitle: "Detects when your pointer hovers over Dock icons and snaps windows to halves/corners.",
                    path: "System Settings → Privacy & Security → Accessibility",
                    granted: model.accessibility,
                    buttonTitle: "Open Accessibility",
                    action: onAccessibility
                )

                permissionRow(
                    icon: "camera.viewfinder",
                    title: "2. Screen Recording",
                    subtitle: "Renders live window thumbnails above the Dock and captures screenshots to the corner shelf.",
                    path: "System Settings → Privacy & Security → Screen Recording",
                    granted: model.screen,
                    buttonTitle: "Open Screen Recording",
                    action: onScreen
                )
            }
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        path: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.24), lineWidth: 1))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(granted ? "Enabled" : "Required")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(granted ? 0.9 : 0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(granted ? 0.18 : 0.10), in: Capsule())
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Enabled")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 1))
            } else {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(buttonTitle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(TourActionButtonStyle())
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(granted ? 0.30 : 0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Step 1: First Screenshot & Corner Shelf (with Visual Illustration)
    private var firstShotStep: some View {
        HStack(alignment: .center, spacing: 20) {
            // Left: Visual Diagram of the Floating Corner Shelf
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .semibold))
                    Text("WHAT IT LOOKS LIKE IN YOUR BOTTOM-RIGHT CORNER")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.65))

                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))

                        VStack(spacing: 6) {
                            HStack {
                                Circle().fill(Color.white.opacity(0.22)).frame(width: 20, height: 20)
                                    .overlay(Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                                Spacer()
                                Circle().fill(Color.white.opacity(0.22)).frame(width: 20, height: 20)
                                    .overlay(Image(systemName: "doc.on.clipboard").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                            }
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.75))
                            HStack {
                                HStack(spacing: 4) {
                                    Image(systemName: "pencil.tip")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Click to Markup / Crop")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.white.opacity(0.88))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.16), in: Capsule())
                                Spacer()
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 116)

                    HStack {
                        Text("1 screenshot")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Label("Copy", systemImage: "doc.on.doc.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.16), in: Capsule())
                        Label("Save", systemImage: "square.and.arrow.down")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.16), in: Capsule())
                    }
                    .foregroundStyle(.white)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.26), lineWidth: 1))
                )
            }
            .frame(width: 360)

            // Right: Clear Explanation + Action
            VStack(alignment: .leading, spacing: 12) {
                Text("Screenshots Stay in a Floating Glass Shelf")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Instead of vanishing after 4 seconds or dumping files on your desktop, every screenshot sits in the bottom-right corner until you copy, edit, drag, or close it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    KeyComboView(keys: ["⌘", "⇧", "3"], label: "Full Screen")
                    KeyComboView(keys: ["⌘", "⇧", "4"], label: "Select Area")
                }

                if !hasTakenFirstShot {
                    Button {
                        ShotShelf.shared.captureScreenUnderPointer()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "camera.fill")
                            Text("Take a Test Screenshot Now")
                        }
                    }
                    .buttonStyle(TourActionButtonStyle())
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screenshot captured to your bottom-right corner!")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text("Try clicking the thumbnail in the corner to annotate, or click Next below.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Step 2: Multi-Shot Stacking & Copy All (with Visual Illustration)
    private var multiShotStep: some View {
        HStack(alignment: .center, spacing: 20) {
            // Left: Visual Diagram of Stacked Screenshots + Copy All
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("MULTI-SHOT SIDE-BY-SIDE DECK")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.65))

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(1...3, id: \.self) { idx in
                            VStack(spacing: 6) {
                                Image(systemName: "macwindow")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white.opacity(0.8))
                                Text("Shot #\(idx)")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 108)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
                            )
                        }
                    }

                    HStack {
                        Text("3 screenshots stacked")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Copy All (1-Click)")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.24), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.26), lineWidth: 1))
                )
            }
            .frame(width: 360)

            // Right: Clear Explanation + Action
            VStack(alignment: .leading, spacing: 12) {
                Text("Stack Multiple Shots & Copy All at Once")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Take 2 or 3 screenshots in a row — they line up side by side in the same corner shelf. Click the Copy All button (doc.on.doc) to paste every screenshot together in one Cmd+V.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                if shotCount < 2 {
                    Button {
                        ShotShelf.shared.captureScreenUnderPointer()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus.rectangle.on.rectangle")
                            Text("Take a 2nd Screenshot to Stack")
                        }
                    }
                    .buttonStyle(TourActionButtonStyle())
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(shotCount) screenshots are now stacked in your corner shelf!")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text("Click the double-document button on the shelf anytime to copy all of them at once.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Step 3: Multi-Copy Clipboard History (with Visual Illustration)
    private var clipboardStep: some View {
        HStack(alignment: .center, spacing: 20) {
            // Left: Visual Diagram of Clipboard History Window
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                    Text("CLIPBOARD HISTORY PANEL (⌃⌥V)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.65))

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("Search copied text, links, images…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    clipboardMockRow(icon: "doc.text", title: "Meeting notes & project summary…", tag: "Click to paste")
                    clipboardMockRow(icon: "link", title: "https://github.com/rept0rix/show-bar", tag: "Click to paste")
                    clipboardMockRow(icon: "photo", title: "Captured Screenshot Image", tag: "Click to paste")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.26), lineWidth: 1))
                )
            }
            .frame(width: 360)

            // Right: Clear Explanation + Action
            VStack(alignment: .leading, spacing: 12) {
                Text("Never Lose Anything You Copy")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("macOS normally forgets your previous copy the moment you press Cmd+C again. Show Bar keeps a searchable history of your copied text, links, and images — click any item to paste it immediately.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                KeyComboView(keys: ["⌃ Ctrl", "⌥ Option", "V"], label: "Open Clipboard Shelf")

                if !hasOpenedClipboard {
                    Button {
                        ClipboardShelf.shared.show()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Open Clipboard History")
                        }
                    }
                    .buttonStyle(TourActionButtonStyle())
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clipboard History is open!")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text("Click any saved row to paste it, or click ✕ on the panel to close it.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func clipboardMockRow(icon: String, title: String, tag: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 20)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer()
            Text(tag)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Step 4: Live Dock Previews & Snap (with Visual Illustration)
    private var dockPreviewsStep: some View {
        HStack(alignment: .center, spacing: 20) {
            // Left: Visual Diagram of Dock Hover Previews
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("DOCK HOVER WINDOW PREVIEWS")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.65))

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        dockPreviewMockCard(title: "Browser — Tab 1", active: true)
                        dockPreviewMockCard(title: "Project Notes", active: false)
                    }
                    HStack(spacing: 12) {
                        ForEach(["safari", "folder.fill", "terminal.fill", "gearshape.fill"], id: \.self) { sym in
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(sym == "safari" ? 0.28 : 0.12))
                                .frame(width: 30, height: 30)
                                .overlay(Image(systemName: sym).font(.system(size: 14)).foregroundStyle(.white))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.10), in: Capsule())
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.26), lineWidth: 1))
                )
            }
            .frame(width: 360)

            // Right: Clear Explanation + Action
            VStack(alignment: .leading, spacing: 12) {
                Text("Hover Any Dock Icon for Live Window Previews")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Move your pointer over any open app in the Dock to see live thumbnails of its windows. Click a card to switch straight to that window, or use the top buttons on a card to Snap (◫), Screenshot (📷), Minimize (−), or Close (✕).")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                KeyComboView(keys: ["⌃ Ctrl", "⌥ Option", "← / →"], label: "Snap Window Left / Right")

                if !hasDockHover && !samplePreviewActive {
                    Button {
                        samplePreviewActive = true
                        _ = onPreview()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "macwindow.on.rectangle")
                            Text("Show Sample Dock Preview")
                        }
                    }
                    .buttonStyle(TourActionButtonStyle())
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live Dock Preview Active!")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text("Hover any running app in your Dock anytime to pick, snap, or close individual windows.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dockPreviewMockCard(title: String, active: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(active ? 0.16 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(active ? 0.65 : 0.20), lineWidth: active ? 1.5 : 1)
                    )
                    .frame(height: 68)
                HStack(spacing: 4) {
                    Image(systemName: "minus").font(.system(size: 7, weight: .bold))
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 7, weight: .bold))
                    Image(systemName: "camera").font(.system(size: 7, weight: .bold))
                    Spacer()
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(6)
            }
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(active ? 0.95 : 0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 5: Visual Command-Tab Switcher (with Visual Illustration)
    private var commandTabStep: some View {
        HStack(alignment: .center, spacing: 20) {
            // Left: Visual Diagram of the Command-Tab Switcher
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "command.square.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("VISUAL COMMAND-TAB WINDOW SWITCHER")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.65))

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        switcherMockCard(icon: "safari", title: "Web Browser", space: "Desktop 1", selected: false)
                        switcherMockCard(icon: "chevron.left.forwardslash.chevron.right", title: "Show Bar Project", space: "Current", selected: true)
                        switcherMockCard(icon: "calendar", title: "Calendar & Notes", space: "Desktop 2", selected: false)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 9))
                        Text("Arrows or Tab to navigate · Release ⌘ to switch")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 2)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.26), lineWidth: 1))
                )
            }
            .frame(width: 370)

            // Right: Clear Explanation + Action
            VStack(alignment: .leading, spacing: 12) {
                Text("See Actual Windows Across All Desktops")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Standard macOS Command-Tab only shows small app icons. Show Bar shows full visual window previews and even displays windows located on Desktop 2 or Desktop 3 so you can jump straight to them.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    KeyComboView(keys: ["⌘", "Tab"], label: "Next Window")
                    KeyComboView(keys: ["⌘", "⇧", "Tab"], label: "Prev")
                }

                if !hasUsedCommandTab {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("Hold ⌘ and press Tab right now on your keyboard to try it!")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Command-Tab Switcher tested!")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text("Release ⌘ anytime to instantly bring that window to the front.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func switcherMockCard(icon: String, title: String, space: String, selected: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.20 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                selected ? Color.white.opacity(0.9) : Color.white.opacity(0.18),
                                lineWidth: selected ? 1.8 : 1
                            )
                    )
                    .frame(height: 80)

                VStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(selected ? 1.0 : 0.75))
                        .padding(.top, 14)
                    Text(title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: .infinity)

                if space != "Current" {
                    Text(space)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(selected ? 1.04 : 1.0)
    }

    // MARK: - Step 6: You're a Pro & Settings (Clean 3-Card Summary Grid)
    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Bar is Ready")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Show Bar runs quietly in your top menu bar. Here are your key shortcuts & tools:")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer()

                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(TourGlassButtonStyle())
            }

            HStack(spacing: 12) {
                summaryFeatureCard(
                    icon: "camera.viewfinder",
                    title: "Screenshots Shelf",
                    keys: ["⌘", "⇧", "3 / 4"],
                    detail: "Stack shots in the corner, markup, or Copy All at once."
                )
                summaryFeatureCard(
                    icon: "doc.on.clipboard",
                    title: "Clipboard History",
                    keys: ["⌃", "⌥", "V"],
                    detail: "Search and paste any previously copied text, link, or image."
                )
                summaryFeatureCard(
                    icon: "rectangle.split.2x1",
                    title: "Snap & Switch",
                    keys: ["⌃", "⌥", "← / →"],
                    detail: "Hover Dock icons for window previews or press ⌘Tab."
                )
            }
        }
    }

    private func summaryFeatureCard(icon: String, title: String, keys: [String], detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            KeyComboView(keys: keys)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        )
    }

    // MARK: - Next Step Button (Only shown once the current step is completed)
    private var nextStepButton: some View {
        Group {
            if step == 0 {
                if model.allGranted {
                    Button("Start Live Tour 🚀") {
                        withAnimation(.spring(response: 0.3)) { step = 1 }
                    }
                    .buttonStyle(TourPrimaryButtonStyle(isEnabled: true))
                } else {
                    stepPendingBadge("Grant both permissions above to continue")
                }
            } else if step == 1 {
                if hasTakenFirstShot {
                    Button("Next: Multi-Shot Stacking →") {
                        withAnimation(.spring(response: 0.3)) { step = 2 }
                    }
                    .buttonStyle(TourPrimaryButtonStyle(isEnabled: true))
                } else {
                    stepPendingBadge("Take a screenshot above to unlock Next")
                }
            } else if step == 2 {
                if shotCount >= 2 {
                    Button("Next: Clipboard History →") {
                        withAnimation(.spring(response: 0.3)) { step = 3 }
                    }
                    .buttonStyle(TourPrimaryButtonStyle(isEnabled: true))
                } else {
                    stepPendingBadge("Take a 2nd screenshot to unlock Next")
                }
            } else if step == 3 {
                if hasOpenedClipboard {
                    Button("Next: Dock Previews →") {
                        withAnimation(.spring(response: 0.3)) { step = 4 }
                    }
                    .buttonStyle(TourPrimaryButtonStyle(isEnabled: true))
                } else {
                    stepPendingBadge("Open Clipboard History to unlock Next")
                }
            } else if step == 4 {
                if hasDockHover || samplePreviewActive {
                    Button("Next: Command-Tab Switcher →") {
                        AppDelegate.shared.hover.dismissPreview()
                        withAnimation(.easeInOut(duration: 0.2)) { step = 5 }
                    }
                    .buttonStyle(TourPrimaryButtonStyle(isEnabled: true))
                } else {
                    stepPendingBadge("Hover a Dock icon or click Sample Preview to unlock Next")
                }
            } else if step == 5 {
                if hasUsedCommandTab {
                    Button("Next: Finish & Settings →") {
                        withAnimation(.easeInOut(duration: 0.2)) { step = 6 }
                    }
                    .buttonStyle(TourPrimaryButtonStyle(isEnabled: true))
                } else {
                    HStack(spacing: 8) {
                        stepPendingBadge("Press ⌘Tab on your keyboard")
                        Button("Skip to Finish →") {
                            hasUsedCommandTab = true
                            withAnimation(.easeInOut(duration: 0.2)) { step = 6 }
                        }
                        .buttonStyle(TourActionButtonStyle())
                    }
                }
            } else {
                Button("Start Using Show Bar 🚀", action: onFinish)
                    .buttonStyle(TourPrimaryButtonStyle(isEnabled: true))
            }
        }
    }

    private func stepPendingBadge(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(text)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

