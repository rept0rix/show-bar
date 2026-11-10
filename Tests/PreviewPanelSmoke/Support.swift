// Test doubles isolate OS window actions; the production PreviewPanel is compiled unchanged.
import AppKit
struct WindowCard {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect
}
struct Thumbnail {
    let windowID: CGWindowID
    let image: CGImage
}
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    func get(_ id: CGWindowID) -> CGImage? { nil }
}
enum WindowCatalog {
    static func endReveal(committing: WindowCard?) {}
}
enum Coordinates {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 900 }
    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    static func screen(containing rect: CGRect) -> NSScreen? { NSScreen.screens.first { $0.frame.intersects(rect) } }
}
enum DockReader { static func isHoverable(_ rect: CGRect) -> Bool { true } }
enum DesktopSpaces {
    struct Desk { let id: UInt64; let title: String }
    static func desk(for id: CGWindowID) -> Desk? { nil }
    static func desks() -> [Desk] { [] }
}
final class ClickCatcher {
    static let shared = ClickCatcher()
    func refresh(_ panel: PreviewPanel) {}
    func setSuspended(_ value: Bool) {}
}
