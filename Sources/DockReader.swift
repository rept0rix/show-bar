import AppKit
import ApplicationServices
import CoreGraphics

struct DockIcon: Equatable {
    let id: String
    let title: String
    let frame: CGRect
    let bundleURL: URL?
    let subrole: String?

    var bundleID: String? {
        guard let bundleURL else { return nil }
        return Bundle(url: bundleURL)?.bundleIdentifier
    }
}

enum Coordinates {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        let hits = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
            let area = screen.frame.intersection(rect)
            let size = area.width * area.height
            return size > 1 ? (screen, size) : nil
        }
        return hits.max(by: { $0.1 < $1.1 })?.0 ?? NSScreen.main
    }
}

enum AXValueReader {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        if let value = attribute(element, name) as? Bool { return value }
        if let number = attribute(element, name) as? NSNumber { return number.boolValue }
        return nil
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else { return [] }
        if let typed = value as? [AXUIElement] { return typed }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        let count = CFArrayGetCount(array)
        var items: [AXUIElement] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            items.append(Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue())
        }
        return items
    }

    static func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as String),
              let size = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &cgSize),
              cgSize.width > 1, cgSize.height > 1 else { return nil }
        return CGRect(origin: point, size: cgSize)
    }

    static func url(_ element: AXUIElement) -> URL? {
        guard let value = attribute(element, kAXURLAttribute as String) else { return nil }
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }
}

enum DockReader {
    private(set) static var debugSummary = ""

    static func icons() -> [DockIcon] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            debugSummary = AXIsProcessTrusted() ? "Dock not running" : "No accessibility access"
            return []
        }

        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var raw: [AXUIElement] = []
        collectDockItems(from: root, depth: 0, into: &raw)

        var notes: [String] = []
        var icons: [DockIcon] = []
        for item in raw {
            let title = AXValueReader.string(item, kAXTitleAttribute as String) ?? ""
            let subrole = AXValueReader.string(item, kAXSubroleAttribute as String)
            let itemURL = AXValueReader.url(item)
            notes.append("\(subrole ?? "-"):\(title)")
            guard let frame = AXValueReader.rect(item) else { continue }
            guard isApplication(title: title, subrole: subrole, url: itemURL) else { continue }
            if Bundle(url: itemURL ?? URL(fileURLWithPath: "/"))?.bundleIdentifier == "com.naoryanko.showbar" {
                continue
            }
            let id = itemURL?.path ?? title
            guard !id.isEmpty else { continue }
            icons.append(DockIcon(id: id, title: title, frame: frame, bundleURL: itemURL, subrole: subrole))
        }

        var seen = Set<String>()
        let unique = icons.filter { seen.insert($0.id).inserted }
        debugSummary = unique.isEmpty
            ? (notes.isEmpty ? "No Dock items" : notes.prefix(12).joined(separator: " · "))
            : "\(unique.count)"
        return unique
    }

    static func isOnScreen(_ frame: CGRect) -> Bool {
        let screens = NSScreen.screens.map { Coordinates.flip($0.frame) }
        guard let screen = screens.first(where: { $0.intersects(frame) }) else { return false }
        let hit = frame.intersection(screen)
        guard hit.width > 2, hit.height > 2 else { return false }
        return hit.width >= frame.width * 0.4 && hit.height >= frame.height * 0.4
    }

    /// Auto-hidden Dock icons sit off-screen.
    /// They should ONLY be treated as hover targets when they are actually visible on screen.
    static func isHoverable(_ frame: CGRect) -> Bool {
        isOnScreen(frame)
    }

    static func edge(for icons: [DockIcon]) -> DockEdge {
        guard let union = icons.map(\.frame).reduce(nil as CGRect?, { partial, rect in
            partial.map { $0.union(rect) } ?? rect
        }) else { return .bottom }
        let appKit = Coordinates.flip(union)
        guard let screen = Coordinates.screen(containing: appKit) else { return .bottom }
        let frame = screen.frame
        // A bottom Dock is wide, so it also touches the left edge. The long side says which edge it is.
        if union.width >= union.height {
            let toBottom = abs(appKit.minY - frame.minY)
            let toTop = abs(appKit.maxY - frame.maxY)
            return toBottom <= toTop ? .bottom : .top
        }
        let toLeft = abs(appKit.minX - frame.minX)
        let toRight = abs(appKit.maxX - frame.maxX)
        return toLeft <= toRight ? .left : .right
    }

    static func hitFrame(_ frame: CGRect, edge: DockEdge) -> CGRect {
        var rect = frame.insetBy(dx: -4, dy: -4)
        switch edge {
        case .left:
            rect.origin.x = min(rect.origin.x, 0)
            rect.size.width = min(max(rect.size.width + 8, frame.width + 8), 75)
        case .right:
            rect.origin.x = max(rect.origin.x - 8, rect.maxX - 75)
            rect.size.width = max(rect.size.width, 48)
        case .bottom:
            rect.origin.y = max(rect.origin.y - 8, rect.maxY - 75)
            rect.size.height = max(rect.size.height, 48)
        case .top:
            rect.origin.y = min(rect.origin.y, 0)
            rect.size.height = min(max(rect.size.height + 8, frame.height + 8), 75)
        }
        return rect
    }

    private static func isApplication(title: String, subrole: String?, url: URL?) -> Bool {
        let subrole = subrole ?? ""
        if subrole.contains("Trash") || subrole.contains("Folder") || subrole.contains("Separator") {
            return false
        }
        if subrole == "AXApplicationDockItem" || url?.pathExtension.lowercased() == "app" {
            return true
        }
        let lowered = title.lowercased()
        if lowered == "trash" || lowered == "פח" || lowered == "פח אשפה" { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(title) == .orderedSame
        }
    }

    private static func collectDockItems(from element: AXUIElement, depth: Int, into items: inout [AXUIElement]) {
        if depth > 7 { return }
        let role = AXValueReader.string(element, kAXRoleAttribute as String) ?? ""
        if role == "AXDockItem" {
            items.append(element)
            return
        }
        for child in AXValueReader.elements(element, kAXChildrenAttribute as String) {
            collectDockItems(from: child, depth: depth + 1, into: &items)
        }
    }
}
