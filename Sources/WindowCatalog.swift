import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

struct WindowCard: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect

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

        let axTitles = accessibilityTitles(pids: target.pids, appName: icon.title)
        let unique = dedupe(Array(listed.prefix(12)))
        var cards = unique.prefix(6).map { window in
            WindowCard(
                id: window.id,
                pid: window.pid,
                title: resolvedTitle(window: window, axTitles: axTitles, appName: icon.title),
                frame: window.frame
            )
        }

        if cards.isEmpty {
            cards = accessibilityWindows(pids: target.pids, appName: icon.title)
        }
        return cards
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

    static func refresh(_ cards: [WindowCard]) async -> (cards: [WindowCard], thumbnails: [Thumbnail]) {
        guard CGPreflightScreenCaptureAccess(), !cards.isEmpty else { return (cards, []) }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return (cards, [])
        }
        let wanted = Set(cards.map(\.id))
        let windows = content.windows.filter { wanted.contains($0.windowID) }
        var images: [Thumbnail] = []
        var titled = cards
        for window in windows {
            if Task.isCancelled { break }
            if let index = titled.firstIndex(where: { $0.id == window.windowID }) {
                let next = betterTitle(titled[index].title, window.title ?? "")
                titled[index] = WindowCard(id: titled[index].id, pid: titled[index].pid, title: next, frame: titled[index].frame)
            }
            if let image = try? await capture(window), !looksBlank(image) {
                images.append(Thumbnail(windowID: window.windowID, image: image))
            }
        }
        return (titled, images)
    }

    static func focus(_ card: WindowCard) {
        let app = NSRunningApplication(processIdentifier: card.pid)
        app?.unhide()
        app?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let element = match(card) else { return }
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
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
        let maxPixel: CGFloat = 720
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
            let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.04 else { continue }
            let pid = pid_t((dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? Int32(dict[kCGWindowOwnerPID as String] as? Int ?? 0))
            guard pid > 0, pid != getpid() else { continue }
            let rawID = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? UInt32(dict[kCGWindowNumber as String] as? Int ?? 0)
            guard rawID != 0 else { continue }
            guard let frame = quartzRect(dict[kCGWindowBounds as String]), frame.width >= 80, frame.height >= 52 else { continue }
            let sharing = (dict[kCGWindowSharingState as String] as? NSNumber)?.intValue
                ?? (dict[kCGWindowSharingState as String] as? Int ?? 1)
            guard sharing != 0 else { continue }
            let title = dict[kCGWindowName as String] as? String ?? ""
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            let onScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
                ?? (dict[kCGWindowIsOnscreen as String] as? Bool ?? false)
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

    private static func accessibilityTitles(pids: Set<pid_t>, appName: String) -> [(CGRect, String)] {
        var found: [(CGRect, String)] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.4)
            for window in AXValueReader.elements(app, kAXWindowsAttribute as String) {
                guard let frame = AXValueReader.rect(window), frame.width >= 80, frame.height >= 52 else { continue }
                let title = detailedTitle(window, appName: appName)
                guard !title.isEmpty else { continue }
                found.append((frame, title))
            }
        }
        return found
    }

    private static func detailedTitle(_ window: AXUIElement, appName: String) -> String {
        let direct = AXValueReader.string(window, kAXTitleAttribute as String) ?? ""
        if isUseful(direct, appName: appName) { return direct }
        if let web = webTitle(window, depth: 0) { return web }
        return direct
    }

    private static func webTitle(_ element: AXUIElement, depth: Int) -> String? {
        if depth > 4 { return nil }
        let role = AXValueReader.string(element, kAXRoleAttribute as String) ?? ""
        if role == "AXWebArea" || role == "AXDocument" {
            let title = AXValueReader.string(element, kAXTitleAttribute as String) ?? ""
            if !title.isEmpty { return title }
        }
        for child in AXValueReader.elements(element, kAXChildrenAttribute as String).prefix(8) {
            if let found = webTitle(child, depth: depth + 1) { return found }
        }
        return nil
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

    private static func resolvedTitle(window: ListedWindow, axTitles: [(CGRect, String)], appName: String) -> String {
        let usable = isUseful(window.title, appName: appName)
            && window.title.caseInsensitiveCompare(window.ownerName) != .orderedSame
        if usable { return window.title }
        let flipped = Coordinates.flip(window.frame)
        let ranked = axTitles.map { item -> (String, CGFloat) in
            let cover = max(overlap(item.0, window.frame), overlap(item.0, flipped))
            return (item.1, cover)
        }.sorted { $0.1 > $1.1 }
        if let match = ranked.first, match.1 > 0.4, isUseful(match.0, appName: appName) {
            return match.0
        }
        return window.title.isEmpty ? appName : window.title
    }

    private static func dedupe(_ windows: [ListedWindow]) -> [ListedWindow] {
        var kept: [ListedWindow] = []
        for window in windows {
            if let index = kept.firstIndex(where: { overlap($0.frame, window.frame) > 0.72 }) {
                if rank(window) > rank(kept[index]) { kept[index] = window }
            } else {
                kept.append(window)
            }
        }
        return kept
    }

    private static func rank(_ window: ListedWindow) -> Int {
        var score = window.onScreen ? 4 : 0
        if !window.title.isEmpty { score += 2 }
        if window.frame.width * window.frame.height > 200_000 { score += 1 }
        return score
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
        return Array(cards.prefix(6))
    }

    private static func match(_ card: WindowCard) -> AXUIElement? {
        let app = AXUIElementCreateApplication(card.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let windows = AXValueReader.elements(app, kAXWindowsAttribute as String)
        let flipped = Coordinates.flip(card.frame)
        if let exact = windows.first(where: { element in
            let title = AXValueReader.string(element, kAXTitleAttribute as String) ?? ""
            guard title == card.title || card.title.isEmpty else { return false }
            guard let frame = AXValueReader.rect(element) else { return title == card.title && !title.isEmpty }
            return framesClose(frame, card.frame) || framesClose(frame, flipped)
        }) {
            return exact
        }
        let sameTitle = windows.filter {
            let title = AXValueReader.string($0, kAXTitleAttribute as String) ?? ""
            return !title.isEmpty && title == card.title
        }
        if sameTitle.count == 1 { return sameTitle[0] }
        return windows.min { lhs, rhs in
            let left = AXValueReader.rect(lhs) ?? .zero
            let right = AXValueReader.rect(rhs) ?? .zero
            return distance(left, card.frame) < distance(right, card.frame)
        }
    }

    private static func framesClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 10
            && abs(lhs.origin.y - rhs.origin.y) < 10
            && abs(lhs.width - rhs.width) < 16
            && abs(lhs.height - rhs.height) < 16
    }

    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }

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
