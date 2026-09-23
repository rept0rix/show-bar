import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let shared = AppDelegate()
    private let defaultsKey = "ShowBar.enabled"
    private var statusItem: NSStatusItem!
    private var hover = HoverController()
    private var permissionsWindow: NSWindow?
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
        app.setActivationPolicy(.accessory)
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sawAccessibility = AXIsProcessTrusted()
        sawScreenRecording = CGPreflightScreenCaptureAccess()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSApp.applicationIconImage {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Show Bar"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        DockAutohide.restore()
        syncHover()
        if !PermissionsState.allGranted {
            showPermissions()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
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

        let donate = NSMenuItem(title: "Donate", action: #selector(openDonate), keyEquivalent: "")
        donate.target = self
        menu.addItem(donate)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

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
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Show Bar could not set launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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

    func windowWillClose(_ notification: Notification) {
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
    struct Release: Identifiable {
        let version: String
        let notes: [String]
        var id: String { version }
    }

    static let ownerName = "Naor Yanko"
    static let ownerEmail = "na0ryank0@gmail.com"
    static let downloadURL = URL(string: "https://github.com/rept0rix/show-bar/releases/latest")!
    static let linkedInURL = URL(string: "https://www.linkedin.com/in/naoryanko")!
    // Replace these with your own pages before you publish.
    static let donateURL = URL(string: "https://www.buymeacoffee.com")!
    static let adURL = URL(string: "https://www.buymeacoffee.com")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
    }

    static let releases: [Release] = [
        Release(version: "1.1", notes: [
            "Previews open beside the Dock icon, and they open faster.",
            "Move a window to another desktop from its card.",
            "A white bar under the name marks the window under the pointer.",
            "Rest on a card for two seconds to peek that window. Click to switch, or leave to put it back.",
            "Command-Tab shows the windows, newest first, and stays on the screen.",
            "Settings can move the Dock to the left, right, top, or bottom."
        ]),
        Release(version: "1.0", notes: [
            "Hover a Dock icon to see that app's windows.",
            "Click a window to switch to it.",
            "Close one window, minimize it, or quit the app from the card.",
            "Choose the preview size, how many windows, and whether names are shown."
        ])
    ]
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

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    var onAccessibility: () -> Void
    var onScreen: () -> Void
    var onRelaunch: () -> Void
    var onPreview: () -> String?
    var onDonate: () -> Void
    @State private var previewNote = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show Bar")
                        .font(.title2.weight(.semibold))
                    Text("Hover a Dock icon to see its windows, like Windows.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(readyText)
                        .font(.headline)
                        .foregroundStyle(model.allGranted && model.dockCount > 0 ? Color.green : Color.orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("About")
                    .font(.headline)
                Text("Version \(ShowBarSupport.version)")
                    .font(.title3.weight(.semibold))
                Text("\(ShowBarSupport.ownerName) · \(ShowBarSupport.ownerEmail)")
                    .foregroundStyle(.secondary)
                Button("Naor Yanko on LinkedIn") {
                    NSWorkspace.shared.open(ShowBarSupport.linkedInURL)
                }
                Text("Show Bar is not in the Mac App Store. The download is the GitHub release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ShowBarSupport.releases) { release in
                    Text("Version \(release.version)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(release.notes, id: \.self) { note in
                        Text("• \(note)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Previews", isOn: Binding(
                    get: { model.previewsEnabled },
                    set: { value in
                        guard value != model.previewsEnabled else { return }
                        AppDelegate.shared.toggleEnabled()
                        model.refresh()
                    }
                ))
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { value in
                        guard value != model.launchAtLogin else { return }
                        AppDelegate.shared.toggleLoginItem()
                        model.refresh()
                    }
                ))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Dock")
                    .font(.headline)
                Picker("Position", selection: Binding(
                    get: { model.dockEdge },
                    set: { value in
                        DockPlacement.current = value
                        model.dockEdge = value
                        AppDelegate.shared.applyDockPosition()
                    }
                )) {
                    Text("Left").tag(DockPlacement.left)
                    Text("Right").tag(DockPlacement.right)
                    Text("Top").tag(DockPlacement.top)
                    Text("Bottom").tag(DockPlacement.bottom)
                }
                .pickerStyle(.segmented)
                Text("Moves the Dock itself to that edge. Previews follow it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Preview windows")
                    .font(.headline)
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
                Text("Size changes the thumbnail size on the next hover. All shows every window. Quit closes that app. The X closes only that window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Download page") {
                NSWorkspace.shared.open(ShowBarSupport.downloadURL)
            }

            VStack(spacing: 10) {
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
            }

            HStack {
                Button("Show a preview now") {
                    previewNote = onPreview() ?? "Preview is open. Move the pointer away to close it."
                }
                .buttonStyle(.borderedProminent)
                Button("Donate", action: onDonate)
                Spacer()
                Button("Relaunch", action: onRelaunch)
                Button("Close") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
            }

            if !previewNote.isEmpty {
                Text(previewNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ADVERTISEMENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Button(action: { NSWorkspace.shared.open(ShowBarSupport.adURL) }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sponsor Show Bar")
                                .font(.headline)
                            Text("This is the ad slot. It stays in this window and never covers the previews.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 480)
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
