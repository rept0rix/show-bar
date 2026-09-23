import AppKit
import UserNotifications

/// Asks before replacing Show Bar when GitHub has a newer release.
enum AppUpdate {
    private static let declinedKey = "ShowBar.declinedUpdate"
    private static let offeredKey = "ShowBar.offeredUpdate"
    private static let notifiedKey = "ShowBar.notifiedUpdate"
    private static let latest = URL(string: "https://api.github.com/repos/rept0rix/show-bar/releases/latest")!
    private static var waiting: Offer?

    static func restoreBadge() {
        guard let saved = UserDefaults.standard.string(forKey: offeredKey),
              isNewer(saved, than: ShowBarSupport.version) else { return }
        AppDelegate.shared.noteUpdate(saved)
    }

    static func askAgain() {
        Task { @MainActor in
            if let waiting {
                ask(waiting)
                return
            }
            checkManually()
        }
    }

    static func checkOnLaunch() {
        Task { await look(automatic: true) }
    }

    static func checkManually() {
        Task { await look(automatic: false) }
    }

    private struct Offer {
        let version: String
        let notes: String
        let download: URL
    }

    private struct Release: Decodable {
        let tagName: String
        let body: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }
    }

    private static func look(automatic: Bool) async {
        do {
            let offer = try await fetch()
            let current = ShowBarSupport.version
            guard isNewer(offer.version, than: current) else {
                await MainActor.run {
                    waiting = nil
                    UserDefaults.standard.removeObject(forKey: offeredKey)
                    AppDelegate.shared.noteUpdate(nil)
                    if !automatic { upToDate(current) }
                }
                return
            }
            await MainActor.run {
                waiting = offer
                UserDefaults.standard.set(offer.version, forKey: offeredKey)
                AppDelegate.shared.noteUpdate(offer.version)
                notifyOnce(offer)
                let declined = UserDefaults.standard.string(forKey: declinedKey) == offer.version
                if automatic && declined { return }
                ask(offer)
            }
        } catch {
            if !automatic { await MainActor.run { failed(error) } }
        }
    }

    private static func fetch() async throws -> Offer {
        var request = URLRequest(url: latest)
        request.setValue("ShowBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.lookupFailed
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateError.noInstaller
        }
        guard isReleaseURL(asset.browserDownloadURL) else { throw UpdateError.untrustedURL }
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Offer(version: version, notes: notes, download: asset.browserDownloadURL)
    }

    private static let expectedTeam = "CM9QNMLQMQ"
    private static let expectedBundle = "com.naoryanko.showbar"

    /// The address published on the GitHub release. Redirects may leave this host.
    private static func isReleaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return false }
        let path = url.path.lowercased()
        return path.contains("/rept0rix/show-bar/releases/download/") && path.hasSuffix(".dmg")
    }

    /// Where a GitHub release file is allowed to redirect.
    fileprivate static func acceptsDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        if host == "github.com" { return url.path.lowercased().contains("/rept0rix/show-bar/") }
        return host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com"
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ raw: String) -> [Int] {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.first == "v" || text.first == "V" { text.removeFirst() }
            if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
            return text.split(separator: ".").map { Int($0) ?? 0 }
        }
        let left = parts(remote)
        let right = parts(local)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    @MainActor
    private static func ask(_ offer: Offer) {
        let alert = NSAlert()
        alert.messageText = "Update Show Bar to \(offer.version)?"
        alert.informativeText = offer.notes.isEmpty
            ? "A new version is ready. Show Bar will download it and relaunch."
            : trimmed(offer.notes)
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not now")
        NSRunningApplication.current.activate(from: .current, options: [])
        if alert.runModal() == .alertFirstButtonReturn {
            beginInstall(offer)
        } else {
            UserDefaults.standard.set(offer.version, forKey: declinedKey)
        }
    }

    @MainActor
    private static func beginInstall(_ offer: Offer) {
        let window = progressWindow("Downloading Show Bar \(offer.version)…")
        Task {
            do {
                let file = try await download(offer.download)
                try install(file)
                await MainActor.run {
                    UserDefaults.standard.set(true, forKey: ShowBarSupport.askForRateKey)
                    UserDefaults.standard.removeObject(forKey: offeredKey)
                    window.close()
                    AppDelegate.shared.relaunchAfterUpdate()
                }
            } catch {
                await MainActor.run {
                    window.close()
                    NSWorkspace.shared.open(offer.download)
                    let alert = NSAlert()
                    alert.messageText = "Show Bar could not replace itself"
                    alert.informativeText = "The download page is open. Open the disk image and drag Show Bar into Applications."
                    alert.runModal()
                }
            }
        }
    }

    private static func download(_ url: URL) async throws -> URL {
        guard isReleaseURL(url) else { throw UpdateError.untrustedURL }
        let redirectGuard = RedirectGuard()
        let session = URLSession(configuration: .ephemeral, delegate: redirectGuard, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.lookupFailed
        }
        guard let finalURL = response.url, acceptsDownload(finalURL) else { throw UpdateError.untrustedURL }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Show-Bar-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    private static func install(_ dmg: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("ShowBarUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmg.path, "-nobrowse", "-mountpoint", mount.path]
        try attach.run()
        attach.waitUntilExit()
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mount.path, "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
        }
        guard attach.terminationStatus == 0 else { throw UpdateError.mountFailed }
        let source = mount.appendingPathComponent("Show Bar.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.noInstaller }
        try verifyReplacement(source)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [source.path, Bundle.main.bundleURL.path]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else { throw UpdateError.copyFailed }
    }

    /// Refuses to replace Show Bar unless the disk contains this app, signed by this team.
    private static func verifyReplacement(_ app: URL) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL),
              plist["CFBundleIdentifier"] as? String == expectedBundle else {
            throw UpdateError.untrustedApp
        }
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", app.path]
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw UpdateError.untrustedApp }

        let detail = Process()
        detail.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        detail.arguments = ["-dv", "--verbose=4", app.path]
        let errors = Pipe()
        detail.standardError = errors
        detail.standardOutput = Pipe()
        try detail.run()
        detail.waitUntilExit()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard detail.terminationStatus == 0 else { throw UpdateError.untrustedApp }
        guard text.contains("TeamIdentifier=\(expectedTeam)") else { throw UpdateError.untrustedApp }
        guard text.contains("Identifier=\(expectedBundle)") else { throw UpdateError.untrustedApp }
        let fromThisTeam = text.contains("Authority=Apple Development") || text.contains("Authority=Developer ID Application")
        guard fromThisTeam else { throw UpdateError.untrustedApp }
    }

    private static func notifyOnce(_ offer: Offer) {
        guard UserDefaults.standard.string(forKey: notifiedKey) != offer.version else { return }
        UserDefaults.standard.set(offer.version, forKey: notifiedKey)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Update Show Bar"
            content.body = "Version \(offer.version) is ready."
            let request = UNNotificationRequest(
                identifier: "showbar-update-\(offer.version)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    @MainActor
    private static func progressWindow(_ text: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Show Bar"
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 24, width: 320, height: 24)
        window.contentView?.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(from: .current, options: [])
        return window
    }

    @MainActor
    private static func upToDate(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Show Bar \(version) is current"
        alert.informativeText = "There is no newer version."
        alert.runModal()
    }

    @MainActor
    private static func failed(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Show Bar could not check for an update"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private static func trimmed(_ text: String) -> String {
        if text.count <= 900 { return text }
        return String(text.prefix(900)) + "…"
    }
}

private enum UpdateError: LocalizedError {
    case lookupFailed, noInstaller, untrustedURL, untrustedApp, mountFailed, copyFailed

    var errorDescription: String? {
        switch self {
        case .lookupFailed: return "GitHub did not answer."
        case .noInstaller: return "The release has no install disk."
        case .untrustedURL: return "The download is not from the Show Bar release."
        case .untrustedApp: return "The new app is not signed as Show Bar."
        case .mountFailed: return "The install disk did not open."
        case .copyFailed: return "The new app could not replace this one."
        }
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, AppUpdate.acceptsDownload(url) else { return nil }
        return request
    }
}
