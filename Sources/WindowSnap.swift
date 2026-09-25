import AppKit
import ApplicationServices
import Darwin

/// Puts the front window on a half, a corner, or the whole screen.
/// Control-Option and the arrows. The same shortcut again puts the window back.
enum SnapZone: String, CaseIterable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize

    var title: String {
        switch self {
        case .left: return "Left half    ⌃⌥←"
        case .right: return "Right half    ⌃⌥→"
        case .top: return "Top half    ⌃⌥↑"
        case .bottom: return "Bottom half    ⌃⌥↓"
        case .topLeft: return "Top left    ⌃⌥U"
        case .topRight: return "Top right    ⌃⌥I"
        case .bottomLeft: return "Bottom left    ⌃⌥J"
        case .bottomRight: return "Bottom right    ⌃⌥K"
        case .maximize: return "Whole screen    ⌃⌥↩"
        }
    }

    static func from(keycode: Int64) -> SnapZone? {
        switch keycode {
        case 123: return .left
        case 124: return .right
        case 126: return .top
        case 125: return .bottom
        case 32: return .topLeft
        case 34: return .topRight
        case 38: return .bottomLeft
        case 40: return .bottomRight
        case 36: return .maximize
        default: return nil
        }
    }
}

enum WindowSnap {
    private struct Memory {
        var original: CGRect
        var zone: SnapZone
    }

    private static var lastOtherPID: pid_t?
    private static var memory: [CGWindowID: Memory] = [:]

    static func rememberFront() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        lastOtherPID = pid
    }

    /// Each press sticks the window to the other half: left, then right, then left.
    static func cycleHalf(pid: pid_t, id: CGWindowID, frame: CGRect) {
        guard AXIsProcessTrusted(), pid > 0, pid != getpid() else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        guard let window = window(pid: pid, id: id) ?? window(pid: pid, frame: frame) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard let current = AXValueReader.rect(window) else { return }
        let screen = screen(forAXRect: current)
        let left = Coordinates.flip(SnapZone.left.frame(inside: screen.visibleFrame))
        apply(close(current, left) ? .right : .left, window: window, current: current, screen: screen)
    }

    static func apply(_ zone: SnapZone) {
        guard AXIsProcessTrusted() else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pid = (front != nil && front != getpid()) ? front! : lastOtherPID
        guard let pid, pid != getpid() else { return }
        guard let window = focusedWindow(pid: pid) else { return }
        guard let current = AXValueReader.rect(window) else { return }
        apply(zone, window: window, current: current, screen: screen(forAXRect: current))
    }

    private static func apply(_ zone: SnapZone, window: AXUIElement, current: CGRect, screen: NSScreen) {
        let target = Coordinates.flip(zone.frame(inside: screen.visibleFrame))
        let key = windowID(window) ?? 0

        if let saved = memory[key], saved.zone == zone, close(current, target) {
            place(window, saved.original)
            memory[key] = nil
            return
        }
        if memory[key] == nil {
            memory[key] = Memory(original: current, zone: zone)
        } else {
            memory[key]?.zone = zone
        }
        place(window, target)
    }

    private static func window(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return AXValueReader.elements(app, kAXWindowsAttribute as String).first { windowID($0) == id }
    }

    /// The window id from the window list does not always match Accessibility. The frame does.
    private static func window(pid: pid_t, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let flipped = Coordinates.flip(frame)
        let windows = AXValueReader.elements(app, kAXWindowsAttribute as String)
        var best: (AXUIElement, CGFloat)?
        for element in windows {
            guard let rect = AXValueReader.rect(element) else { continue }
            let score = max(areaOverlap(rect, frame), areaOverlap(rect, flipped))
            if best == nil || score > best!.1 { best = (element, score) }
        }
        if let best, best.1 > 0.35 { return best.0 }
        return windows.first
    }

    private static func areaOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let hit = lhs.intersection(rhs)
        guard !hit.isNull, hit.width > 0, hit.height > 0 else { return 0 }
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smaller > 1 else { return 0 }
        return (hit.width * hit.height) / smaller
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let focused = AXValueReader.attribute(app, kAXFocusedWindowAttribute as String),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        return AXValueReader.elements(app, kAXWindowsAttribute as String).first
    }

    private static func screen(forAXRect rect: CGRect) -> NSScreen {
        let appKit = Coordinates.flip(rect)
        let center = CGPoint(x: appKit.midX, y: appKit.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func place(_ window: AXUIElement, _ axRect: CGRect) {
        var origin = axRect.origin
        var size = axRect.size
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let box = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, box)
        }
        var originAgain = axRect.origin
        if let position = AXValueCreate(.cgPoint, &originAgain) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
    }

    private static func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 12
            && abs(lhs.minY - rhs.minY) < 12
            && abs(lhs.width - rhs.width) < 12
            && abs(lhs.height - rhs.height) < 12
    }

    private static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let get = windowIDGetter else { return nil }
        var identifier: UInt32 = 0
        guard get(element, &identifier) == 0, identifier != 0 else { return nil }
        return CGWindowID(identifier)
    }

    private static let windowIDGetter: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32)? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let raw = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(raw, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32).self)
    }()
}

private extension SnapZone {
    func frame(inside visible: CGRect) -> CGRect {
        let halfW = (visible.width / 2).rounded()
        let halfH = (visible.height / 2).rounded()
        switch self {
        case .left:
            return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: visible.height)
        case .right:
            return CGRect(x: visible.minX + halfW, y: visible.minY, width: visible.width - halfW, height: visible.height)
        case .bottom:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfH)
        case .top:
            return CGRect(x: visible.minX, y: visible.minY + halfH, width: visible.width, height: visible.height - halfH)
        case .bottomLeft:
            return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: visible.minX + halfW, y: visible.minY, width: visible.width - halfW, height: halfH)
        case .topLeft:
            return CGRect(x: visible.minX, y: visible.minY + halfH, width: halfW, height: visible.height - halfH)
        case .topRight:
            return CGRect(x: visible.minX + halfW, y: visible.minY + halfH, width: visible.width - halfW, height: visible.height - halfH)
        case .maximize:
            return visible
        }
    }
}
