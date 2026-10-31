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
        #if DEBUG
        if CommandLine.arguments.contains("--companion-test-host") {
            RemoteBridge.runIsolatedTestHost()
        }
        #endif
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
        RemoteBridge.shared.start()
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
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "ShowBar.hasCompletedOnboarding")
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
            let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "ShowBar.hasCompletedOnboarding")
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

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if let version = offeredUpdate {
            menu.addItem(updateButtonItem(version))
            menu.addItem(.separator())
        }
        let version = NSMenuItem(title: "Version \(ShowBarSupport.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let onboardingItem = NSMenuItem(title: "Welcome & Onboarding Guide…", action: #selector(openOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)
        menu.addItem(.separator())

        let previewsItem = NSMenuItem(
            title: previewsAreEnabled ? "Window previews" : "Window previews (off)",
            action: #selector(togglePreviews),
            keyEquivalent: ""
        )
        previewsItem.target = self
        previewsItem.state = previewsAreEnabled ? .on : .off
        menu.addItem(previewsItem)

        let cmdTabItem = NSMenuItem(
            title: commandTabIsEnabled ? "Command-Tab switcher" : "Command-Tab switcher (off)",
            action: #selector(toggleCommandTab),
            keyEquivalent: ""
        )
        cmdTabItem.target = self
        cmdTabItem.state = commandTabIsEnabled ? .on : .off
        menu.addItem(cmdTabItem)

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

        let companion = NSMenuItem(title: "Companion devices…", action: #selector(openCompanion), keyEquivalent: "")
        companion.target = self
        menu.addItem(companion)

        let preview = NSMenuItem(title: "Show a preview now", action: #selector(showSample), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)

        let resetSwitcher = NSMenuItem(title: "Reset Command-Tab", action: #selector(resetCommandTab), keyEquivalent: "")
        resetSwitcher.target = self
        menu.addItem(resetSwitcher)

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
        let thisItem = NSMenuItem(title: "Copy this screen    ⌘⇧3", action: #selector(copyThisScreen), keyEquivalent: "")
        thisItem.target = self
        shotMenu.addItem(thisItem)
        if NSScreen.screens.count > 1 {
            let allItem = NSMenuItem(title: "Copy every screen", action: #selector(copyAllScreens), keyEquivalent: "")
            allItem.target = self
            shotMenu.addItem(allItem)
        }
        let area = NSMenuItem(title: "Copy selection    ⌘⇧4", action: #selector(copySelection), keyEquivalent: "")
        area.target = self
        shotMenu.addItem(area)
        shot.submenu = shotMenu
        menu.addItem(shot)

        let video = NSMenuItem(title: "Screen Recording", action: nil, keyEquivalent: "")
        let videoMenu = NSMenu()
        let isRec = VideoRecorder.shared.isRecording
        let recTitle = isRec ? "Stop Recording" : "Record Screen"
        let recItem = NSMenuItem(title: recTitle, action: #selector(toggleScreenRecording), keyEquivalent: "")
        recItem.target = self
        videoMenu.addItem(recItem)
        video.submenu = videoMenu
        menu.addItem(video)

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

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
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

    @objc private func openCompanion() {
        RemoteBridge.shared.showPairing()
    }

    func applicationWillTerminate(_ notification: Notification) {
        RemoteBridge.shared.stop()
    }

    @objc private func quit() {
        RemoteBridge.shared.stop()
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
        let host = NSHostingView(rootView: OnboardingView(
            model: model,
            onAccessibility: { PermissionsState.promptAccessibility() },
            onScreen: { PermissionsState.promptScreenRecording() },
            onPreview: { AppDelegate.shared.hover.showSamplePreview() },
            onFinish: { [weak self] in
                UserDefaults.standard.set(true, forKey: "ShowBar.hasCompletedOnboarding")
                self?.onboardingWindow?.close()
                self?.syncHover()
            },
            onOpenSettings: { [weak self] in
                self?.onboardingWindow?.close()
                self?.showPermissions()
            }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Show Bar"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Show Bar Settings & Guide"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(max(fitted.height, 580), screenHeight - 48)
        window.setContentSize(NSSize(width: 540, height: height))
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.9.7" // showbar-version
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
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Show Bar")
                            .font(.title2.weight(.bold))
                        Text("v\(ShowBarSupport.version)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
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
                    .buttonStyle(.borderedProminent)
                    BuyCoffeeButton(action: onDonate)
                }
            }

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
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
        }
        .padding(22)
        .frame(width: 540)
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
                    Button("Launch Onboarding Wizard →") {
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
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            permissionCard(
                icon: "accessibility",
                iconColor: .blue,
                title: "1. Accessibility (נגישות)",
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
                title: "2. Screen Recording (הקלטת מסך)",
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

struct OnboardingView: View {
    @ObservedObject var model: PermissionsModel
    var onAccessibility: () -> Void
    var onScreen: () -> Void
    var onPreview: () -> String?
    var onFinish: () -> Void
    var onOpenSettings: () -> Void

    @State private var step: Int = 0
    @State private var previewFeedback = ""

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Divider()

            ZStack {
                switch step {
                case 0:
                    welcomeStep
                case 1:
                    featuresStep
                case 2:
                    permissionsStep
                case 3:
                    readyStep
                default:
                    welcomeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()

            bottomBar
        }
        .frame(width: 560, height: 600)
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: i == step ? 22 : 8, height: 7)
                        .animation(.easeInOut(duration: 0.25), value: step)
                }
            }

            Spacer()

            Text(stepTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.02))
    }

    private var stepTitle: String {
        switch step {
        case 0: return "Step 1 of 4: Welcome"
        case 1: return "Step 2 of 4: Features Tour"
        case 2: return "Step 3 of 4: Permissions"
        case 3: return "Step 4 of 4: Ready!"
        default: return ""
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.2), Color.clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 75
                        )
                    )
                    .frame(width: 150, height: 150)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color.black.opacity(0.18), radius: 10, y: 5)
            }

            VStack(spacing: 6) {
                Text("Welcome to Show Bar")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("The missing window previews & workflow superpowers for your Mac Dock.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            VStack(alignment: .leading, spacing: 10) {
                welcomeFeatureRow(
                    icon: "macwindow.on.rectangle",
                    color: .blue,
                    title: "Live Dock Window Previews",
                    desc: "Hover any Dock icon to peek at open windows without switching apps."
                )
                welcomeFeatureRow(
                    icon: "command.square.fill",
                    color: .red,
                    title: "Visual ⌘+Tab Switcher",
                    desc: "See real live thumbnails across all Desktops and Spaces."
                )
                welcomeFeatureRow(
                    icon: "doc.on.clipboard.fill",
                    color: .green,
                    title: "Multi-Copy Clipboard History",
                    desc: "Press ⌃⌥V to recall previous texts, code snippets, and images."
                )
            }
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("100% on-device & private. No telemetry of your screen or keystrokes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func welcomeFeatureRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var featuresStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What Show Bar Does For You")
                    .font(.title2.weight(.bold))
                Text("5 superpowers designed to solve everyday macOS frustrations:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    onboardingFeatureCard(
                        icon: "macwindow.on.rectangle",
                        iconColor: .blue,
                        title: "1. Dock Window Previews",
                        badge: "Hover Any App",
                        desc: "Hover your mouse over any app icon in the Dock. You'll see live thumbnails of all its open windows. Click to switch, snap left/right, or close windows instantly without bringing the whole app forward.",
                        actionHint: "Hover mouse on any Dock icon"
                    )

                    onboardingFeatureCard(
                        icon: "command.square.fill",
                        iconColor: .red,
                        title: "2. Visual Command-Tab Switcher",
                        badge: "Multi-Desktop Spaces",
                        desc: "Native macOS ⌘+Tab shows tiny icons. Show Bar shows large live window previews and lets you jump directly to windows on other Desktops/Spaces.",
                        actionHint: "Hold ⌘ + press Tab"
                    )

                    onboardingFeatureCard(
                        icon: "rectangle.split.2x1.fill",
                        iconColor: .purple,
                        title: "3. Window Snapping",
                        badge: "No Fullscreen Lock",
                        desc: "Snap any window to the left half, right half, or full desktop width in a flash without being locked in Apple's restrictive Split View.",
                        actionHint: "Shortcut: ⌃⌥← / ⌃⌥→"
                    )

                    onboardingFeatureCard(
                        icon: "doc.on.clipboard.fill",
                        iconColor: .green,
                        title: "4. Multi-Copy Clipboard History",
                        badge: "Never Lose Copies",
                        desc: "Stores your recent copied texts, links, code, and images. Press the shortcut, type to search, and press Enter to paste anywhere.",
                        actionHint: "Shortcut: ⌃⌥V"
                    )

                    onboardingFeatureCard(
                        icon: "square.stack.3d.down.right.fill",
                        iconColor: .orange,
                        title: "5. Multi-Shot Shelf & Recording",
                        badge: "No Desktop Clutter",
                        desc: "Take screenshots that stack into a floating shelf instead of cluttering your desktop. Or record screen clips with clear audio and a quick trimmer.",
                        actionHint: "Shortcut: ⌘⇧3 / ⌘⇧4"
                    )
                }
                .padding(.trailing, 4)
            }
        }
    }

    private func onboardingFeatureCard(
        icon: String,
        iconColor: Color,
        title: String,
        badge: String,
        desc: String,
        actionHint: String
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

            Text(desc)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Text("👉 Try it:")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(actionHint)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Permissions Setup")
                    .font(.title2.weight(.bold))
                Text("Show Bar requires 2 quick macOS permissions to work its magic:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                onboardingPermissionCard(
                    icon: "hand.raised.fill",
                    iconColor: .blue,
                    title: "1. Accessibility (נגישות)",
                    why: "Enables Show Bar to detect mouse hover over Dock icons and manage window positions.",
                    isGranted: model.accessibility,
                    buttonTitle: model.accessibility ? "Configure in Settings ↗" : "Grant Accessibility Permission →",
                    action: onAccessibility
                )

                onboardingPermissionCard(
                    icon: "camera.viewfinder",
                    iconColor: .purple,
                    title: "2. Screen Recording (הקלטת מסך)",
                    why: "Enables macOS to generate live window thumbnail previews. Show Bar never records or uploads your screen.",
                    isGranted: model.screen,
                    buttonTitle: model.screen ? "Configure in Settings ↗" : "Grant Screen Recording Permission →",
                    action: onScreen
                )
            }

            HStack(spacing: 10) {
                Image(systemName: model.allGranted ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(model.allGranted ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.allGranted ? "All permissions active! You're ready." : "How to enable:")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.allGranted ? Color.green : Color.primary)
                    Text(model.allGranted
                        ? "Show Bar is fully connected. Click 'Continue' to finish setup."
                        : "Click each button above, toggle the switch next to Show Bar to ON in System Settings. Show Bar will detect it automatically!"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(
                (model.allGranted ? Color.green : Color.orange).opacity(0.1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            Spacer()
        }
    }

    private func onboardingPermissionCard(
        icon: String,
        iconColor: Color,
        title: String,
        why: String,
        isGranted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    if isGranted {
                        Text("Active ✓")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isGranted {
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
            Color.primary.opacity(isGranted ? 0.03 : 0.06),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isGranted ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 90, height: 90)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 4) {
                Text("You're All Set!")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Show Bar is running and ready to supercharge your workflow.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                readyTipRow(
                    number: "1",
                    title: "Hover over your Dock",
                    desc: "Move your cursor to any running app icon in your Dock to see instant live window previews."
                )
                readyTipRow(
                    number: "2",
                    title: "Look for Show Bar in the Menu Bar",
                    desc: "The Show Bar icon is in the top-right menu bar. Click it anytime for settings, screenshots, and clipboard history."
                )
                readyTipRow(
                    number: "3",
                    title: "Master the Key Shortcuts",
                    desc: "⌘+Tab for visual switching • ⌃⌥V for clipboard history • ⌃⌥← / ⌃⌥→ to snap windows."
                )
            }
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !previewFeedback.isEmpty {
                Text(previewFeedback)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .transition(.opacity)
            }

            HStack(spacing: 12) {
                Button("Test Live Preview Now 🪟") {
                    previewFeedback = onPreview() ?? "Preview displayed! Move cursor away to dismiss."
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }

    private func readyTipRow(number: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            if step > 0 {
                Button("← Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step -= 1
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if step < totalSteps - 1 {
                Button("Continue →") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button("Start Using Show Bar 🚀") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.02))
    }
}
