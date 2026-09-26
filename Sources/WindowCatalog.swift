import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

struct WindowCard: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect
    /// Desktop 1 is 1, Desktop 2 is 2. The number does not change when the user switches.
    var desktopIndex: Int = 0
    /// True when this window is on the desktop in front of the user.
    var isCurrent: Bool = true

    static func == (lhs: WindowCard, rhs: WindowCard) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.title == rhs.title
    }
}

struct Thumbnail: @unchecked Sendable {
    let windowID: CGWindowID
    let image: CGImage
}

enum WindowCatalog {
    private struct ListedWindow {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let frame: CGRect
        let ownerName: String
        let onScreen: Bool
        let order: Int
    }

    static func windows(for icon: DockIcon) -> [WindowCard] {
        let target = resolve(icon)
        guard !target.pids.isEmpty else { return [] }

        let listed = listWindows().filter { window in
            target.pids.contains(window.pid)
                || window.ownerName.caseInsensitiveCompare(icon.title) == .orderedSame
        }
        .sorted { lhs, rhs in
            if lhs.onScreen != rhs.onScreen { return lhs.onScreen && !rhs.onScreen }
            return lhs.order < rhs.order
        }

        if !listed.isEmpty {
            let cards = listed.map { window in
                WindowCard(
                    id: window.id,
                    pid: window.pid,
                    title: listedTitle(window.title, appName: icon.title),
                    frame: window.frame
                )
            }
            return PreviewPreferences.limit(cards)
        }
        return PreviewPreferences.limit(accessibilityWindows(pids: target.pids, appName: icon.title))
    }

    static func appIcon(for icon: DockIcon) -> NSImage {
        if let url = icon.bundleURL ?? resolve(icon).bundleURL {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 64, height: 64)
            return image
        }
        let image = NSWorkspace.shared.icon(for: .applicationBundle)
        image.size = NSSize(width: 64, height: 64)
        return image
    }

    static func switcherCards() -> [WindowCard] {
        let desks = DesktopSpaces.desks()
        let currents = DesktopSpaces.currentIDs()
        let currentIndex = desks.first { currents.contains($0.id) }?.index ?? 1
        return listWindows().compactMap { window in
            guard belongsInSwitcher(window) else { return nil }
            let ids = Set(DesktopSpaces.spaceIDs(for: window.id))
            let home = desks.first { ids.contains($0.id) }
            let onCurrent = !ids.isEmpty && !ids.isDisjoint(with: currents)
            let isCurrent = ids.isEmpty ? window.onScreen : onCurrent
            return WindowCard(
                id: window.id,
                pid: window.pid,
                title: switcherTitle(window),
                frame: window.frame,
                desktopIndex: home?.index ?? currentIndex,
                isCurrent: isCurrent
            )
        }
    }

    /// Command-Tab is for switching to a real window. Password panels and Quick Look are not.
    /// Windows on other desktops are included even though they are not on this screen.
    private static func belongsInSwitcher(_ window: ListedWindow) -> Bool {
        guard window.frame.width >= 220, window.frame.height >= 140 else { return false }
        let owner = window.ownerName.lowercased()
        let blocked = [
            "autofill", "quicklook", "loginwindow", "window server", "systemuiserver",
            "control center", "notification center", "spotlight", "universal control",
            "wallpaper", "textinput", "dock"
        ]
        if blocked.contains(where: { owner.contains($0) }) { return false }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
        return app.activationPolicy == .regular
    }

    private static func switcherTitle(_ window: ListedWindow) -> String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.caseInsensitiveCompare(window.ownerName) == .orderedSame {
            return window.ownerName.isEmpty ? "Application" : window.ownerName
        }
        return title
    }

    static func refresh(
        _ cards: [WindowCard],
        onThumbnail: (@Sendable (Thumbnail) -> Void)? = nil
    ) async -> (cards: [WindowCard], thumbnails: [Thumbnail]) {
        guard CGPreflightScreenCaptureAccess(), !cards.isEmpty else { return (cards, []) }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return (cards, [])
        }
        let wanted = Set(cards.map(\.id))
        let windows = content.windows.filter { wanted.contains($0.windowID) }
        var titled = cards
        for window in windows {
            guard let index = titled.firstIndex(where: { $0.id == window.windowID }) else { continue }
            let next = betterTitle(titled[index].title, window.title ?? "")
            titled[index] = WindowCard(id: titled[index].id, pid: titled[index].pid, title: next, frame: titled[index].frame)
        }
        var images: [Thumbnail] = []
        let limit = 4
        await withTaskGroup(of: Thumbnail?.self) { group in
            var pending = Array(windows)
            func enqueue() {
                guard !pending.isEmpty else { return }
                let window = pending.removeFirst()
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let image = try? await capture(window), !looksBlank(image) else { return nil }
                    let thumbnail = Thumbnail(windowID: window.windowID, image: image)
                    onThumbnail?(thumbnail)
                    return thumbnail
                }
            }
            for _ in 0..<min(limit, pending.count) {
                enqueue()
            }
            for await item in group {
                if let item { images.append(item) }
                enqueue()
            }
        }
        return (titled, images)
    }

    /// Drops windows left floating above every desktop, and forgets a half-finished peek.
    static func resetSwitcherState() {
        endReveal(committing: nil)
        WindowLayer.releaseStuck()
    }

    static func focus(_ card: WindowCard) {
        endReveal(committing: card)
        WindowLayer.releaseStuck()

        let target = card.id
        if let space = DesktopSpaces.spaceToOpen(target) {
            DesktopSpaces.show(space)
        }

        let matched = match(card)
        if let matched {
            AXUIElementSetAttributeValue(matched, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        if let app = NSRunningApplication(processIdentifier: card.pid) {
            app.unhide()
            _ = app.activate()
        }

        bringForward(matched, pid: card.pid)

        if let app = NSRunningApplication(processIdentifier: card.pid), let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.promptsUserIfNeeded = false
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            bringForward(matched ?? match(card), pid: card.pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            bringForward(matched ?? match(card), pid: card.pid)
        }
    }

    /// Activating an app focuses whichever window it last used. This points it at the chosen one.
    private static func bringForward(_ element: AXUIElement?, pid: pid_t) {
        guard let element else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Shows the real window above other windows without activating its app.
    /// A later click commits that choice. Leaving without a click puts the window back.
    static func reveal(_ card: WindowCard) {
        if revealed?.cardID == card.id { return }
        endReveal(committing: nil)
        guard let element = match(card) else {
            guard knownWindow(card.id) else { return }
            raise(card.id, card: card, element: nil)
            return
        }
        raise(windowID(element) ?? card.id, card: card, element: element)
    }

    private static func raise(_ windowID: CGWindowID, card: WindowCard, element: AXUIElement?) {
        guard windowID != 0 else { return }
        let minimized = element.flatMap { AXValueReader.bool($0, kAXMinimizedAttribute as String) } ?? false
        let space = DesktopSpaces.space(of: windowID)
        let level = WindowLayer.level(of: windowID) ?? 0
        if minimized, let element {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        revealed = Reveal(cardID: card.id, windowID: windowID, pid: card.pid, level: level, minimized: minimized, space: space)
    }

    private static func knownWindow(_ id: CGWindowID) -> Bool {
        listWindows().contains { $0.id == id }
    }

    static func endReveal(committing card: WindowCard?) {
        guard let revealed else { return }
        self.revealed = nil
        WindowLayer.set(revealed.windowID, revealed.level)
        let tookFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier == revealed.pid
        guard card?.id != revealed.cardID, !tookFocus else { return }
        if let space = revealed.space, DesktopSpaces.space(of: revealed.windowID) != space {
            DesktopSpaces.move(windowID: revealed.windowID, to: space)
        }
        if revealed.minimized, let element = element(forWindowID: revealed.windowID) {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private struct Reveal {
        let cardID: CGWindowID
        let windowID: CGWindowID
        let pid: pid_t
        let level: Int32
        let minimized: Bool
        let space: UInt64?
    }

    private static var revealed: Reveal?

    private static func element(forWindowID id: CGWindowID) -> AXUIElement? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let owner = info.first(where: { windowNumber($0) == id }) else { return nil }
        let pid = windowPID(owner)
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return AXValueReader.elements(app, kAXWindowsAttribute as String).first { windowID($0) == id }
    }

    private static func windowPID(_ info: [String: Any]) -> pid_t {
        if let number = info[kCGWindowOwnerPID as String] as? NSNumber { return pid_t(number.int32Value) }
        if let number = info[kCGWindowOwnerPID as String] as? Int { return pid_t(number) }
        return 0
    }

    private static func windowNumber(_ info: [String: Any]) -> CGWindowID {
        if let number = info[kCGWindowNumber as String] as? NSNumber { return CGWindowID(number.uint32Value) }
        if let number = info[kCGWindowNumber as String] as? Int { return CGWindowID(number) }
        return 0
    }

    static func quit(_ card: WindowCard) {
        NSRunningApplication(processIdentifier: card.pid)?.terminate()
    }

    static func minimize(_ card: WindowCard) {
        guard let element = match(card) else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    static func close(_ card: WindowCard) {
        guard let element = match(card) else { return }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString)
    }

    private static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let aspect = window.frame.width / max(window.frame.height, 1)
        let maxPixel: CGFloat = 512
        var width = maxPixel
        var height = maxPixel / max(aspect, 0.15)
        if height > maxPixel {
            height = maxPixel
            width = maxPixel * aspect
        }
        config.width = max(Int(width.rounded()), 2)
        config.height = max(Int(height.rounded()), 2)
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .nominal
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private struct ResolvedApp {
        var pids: Set<pid_t>
        var bundleURL: URL?
    }

    private static func resolve(_ icon: DockIcon) -> ResolvedApp {
        var apps: [NSRunningApplication] = []
        if let bundleID = icon.bundleID {
            apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        if apps.isEmpty {
            apps = NSWorkspace.shared.runningApplications.filter { app in
                guard app.activationPolicy != .prohibited else { return false }
                if app.localizedName?.caseInsensitiveCompare(icon.title) == .orderedSame { return true }
                if let bundleURL = icon.bundleURL, app.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                    return true
                }
                return false
            }
        }
        let regular = apps.filter { $0.activationPolicy == .regular }
        let chosen = regular.isEmpty ? apps : regular
        return ResolvedApp(
            pids: Set(chosen.map(\.processIdentifier)),
            bundleURL: icon.bundleURL ?? chosen.first?.bundleURL
        )
    }

    private static func listWindows() -> [ListedWindow] {
        guard let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var windows: [ListedWindow] = []
        for (index, dict) in info.enumerated() {
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? (dict[kCGWindowLayer as String] as? Int ?? 0)
            guard layer == 0 else { continue }
            let pid = pid_t((dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? Int32(dict[kCGWindowOwnerPID as String] as? Int ?? 0))
            guard pid > 0, pid != getpid() else { continue }
            let rawID = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? UInt32(dict[kCGWindowNumber as String] as? Int ?? 0)
            guard rawID != 0 else { continue }
            guard let frame = quartzRect(dict[kCGWindowBounds as String]), frame.width >= 80, frame.height >= 52 else { continue }
            let onScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
                ?? (dict[kCGWindowIsOnscreen as String] as? Bool ?? false)
            let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if onScreen && alpha <= 0.04 { continue }
            let title = dict[kCGWindowName as String] as? String ?? ""
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            windows.append(ListedWindow(
                id: CGWindowID(rawID),
                pid: pid,
                title: title,
                frame: frame,
                ownerName: owner,
                onScreen: onScreen,
                order: index
            ))
        }
        return windows
    }

    private static func listedTitle(_ title: String, appName: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUseful(trimmed, appName: appName) { return trimmed }
        return appName
    }

    private static func isUseful(_ title: String, appName: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return false }
        if trimmed.caseInsensitiveCompare(appName) == .orderedSame { return false }
        return true
    }

    private static func betterTitle(_ current: String, _ candidate: String) -> String {
        let next = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return current }
        if current.isEmpty || next.count > current.count { return next }
        return current
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let hit = lhs.intersection(rhs)
        guard !hit.isNull, hit.width > 0, hit.height > 0 else { return 0 }
        let area = hit.width * hit.height
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smaller > 1 else { return 0 }
        return area / smaller
    }

    private static func looksBlank(_ image: CGImage) -> Bool {
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0
        var sumSquares = 0.0
        let count = width * height
        for index in 0..<count {
            let offset = index * 4
            let luminance = (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / 255
            sum += luminance
            sumSquares += luminance * luminance
        }
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        return mean < 0.12 && variance < 0.004
    }

    private static func accessibilityWindows(pids: Set<pid_t>, appName: String) -> [WindowCard] {
        var cards: [WindowCard] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            for window in AXValueReader.elements(app, kAXWindowsAttribute as String) {
                let subrole = AXValueReader.string(window, kAXSubroleAttribute as String) ?? ""
                if subrole == "AXUnknown" { continue }
                let minimized = AXValueReader.bool(window, kAXMinimizedAttribute as String) ?? false
                let frame = AXValueReader.rect(window) ?? .zero
                if !minimized && (frame.width < 80 || frame.height < 52) { continue }
                let title = AXValueReader.string(window, kAXTitleAttribute as String) ?? ""
                cards.append(WindowCard(
                    id: syntheticID(pid: pid, title: title, frame: frame),
                    pid: pid,
                    title: title.isEmpty ? appName : title,
                    frame: frame
                ))
            }
        }
        return PreviewPreferences.limit(cards)
    }

    private static func match(_ card: WindowCard) -> AXUIElement? {
        let app = AXUIElementCreateApplication(card.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var windows = AXValueReader.elements(app, kAXWindowsAttribute as String)
        if windows.isEmpty {
            windows = AXValueReader.elements(app, kAXChildrenAttribute as String).filter {
                AXValueReader.string($0, kAXRoleAttribute as String) == (kAXWindowRole as String)
            }
        }
        if let exact = windows.first(where: { windowID($0) == card.id }) {
            return exact
        }
        let wanted = plain(card.title)
        let titled = windows.filter {
            let title = plain(AXValueReader.string($0, kAXTitleAttribute as String) ?? "")
            return !wanted.isEmpty && title.caseInsensitiveCompare(wanted) == .orderedSame
        }
        if titled.count == 1 { return titled[0] }
        let pool = titled.isEmpty ? windows : titled
        let flipped = Coordinates.flip(card.frame)
        let scored = pool.map { element -> (AXUIElement, CGFloat) in
            guard let frame = AXValueReader.rect(element) else { return (element, 0) }
            return (element, max(overlap(frame, card.frame), overlap(frame, flipped)))
        }.sorted { $0.1 > $1.1 }
        if let best = scored.first, best.1 > 0.4 {
            return best.0
        }
        return pool.first
    }

    private static func plain(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x200E && $0.value != 0x200F }
            .map(String.init)
            .joined()
    }

    private static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let get = windowIDGetter else { return nil }
        var identifier: UInt32 = 0
        guard get(element, &identifier) == 0, identifier != 0 else { return nil }
        return CGWindowID(identifier)
    }

    private static let windowIDGetter: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32)? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let raw = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(raw, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32).self)
    }()

    private static func syntheticID(pid: pid_t, title: String, frame: CGRect) -> CGWindowID {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(title)
        hasher.combine(Int(frame.origin.x.rounded()))
        hasher.combine(Int(frame.origin.y.rounded()))
        hasher.combine(Int(frame.width.rounded()))
        return CGWindowID(truncatingIfNeeded: hasher.finalize())
    }

    private static func quartzRect(_ value: Any?) -> CGRect? {
        let dict = value as? [String: Any]
        func number(_ key: String) -> CGFloat? {
            if let number = dict?[key] as? NSNumber { return CGFloat(number.doubleValue) }
            if let number = dict?[key] as? Double { return CGFloat(number) }
            return nil
        }
        guard let x = number("X"), let y = number("Y"), let width = number("Width"), let height = number("Height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private enum WindowLayer {
    static func level(of windowID: CGWindowID) -> Int32? {
        guard let connection = connectionID(),
              let get: @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32 = symbol("SLSGetWindowLevel") else { return nil }
        var level: Int32 = 0
        guard get(connection, windowID, &level) == 0 else { return nil }
        return level
    }

    static func set(_ windowID: CGWindowID, _ level: Int32) {
        guard let connection = connectionID(),
              let set: @convention(c) (Int32, UInt32, Int32) -> Int32 = symbol("SLSSetWindowLevel") else { return }
        _ = set(connection, windowID, level)
    }

    /// A window left above normal level stays painted on top of every desktop.
    static func releaseStuck() {
        let floating = Int32(CGWindowLevelForKey(.floatingWindow))
        guard let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        for dict in info {
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let windowID = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            guard windowID != 0 else { continue }
            guard let level = Self.level(of: CGWindowID(windowID)), level >= floating else { continue }
            set(CGWindowID(windowID), 0)
        }
    }

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func connectionID() -> Int32? {
        guard let main: @convention(c) () -> Int32 = symbol("CGSMainConnectionID") else { return nil }
        let connection = main()
        return connection == 0 ? nil : connection
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let sky, let raw = dlsym(sky, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}
