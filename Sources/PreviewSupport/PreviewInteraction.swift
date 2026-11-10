import Foundation
import CoreGraphics

enum DockEdge: CaseIterable, Sendable {
    case left, right, bottom, top
}

/// Geometry uses Window Server coordinates (the top of the primary display is y = 0).
enum PreviewInteraction {
    static let openDelay: UInt64 = 180_000_000
    static let switchDelay: UInt64 = 90_000_000
    static let closeDelay: UInt64 = 280_000_000

    static func lane(for icon: CGRect, neighbors: [CGRect], screen: CGRect, edge: DockEdge) -> CGRect {
        let vertical = edge == .left || edge == .right
        let center = vertical ? icon.midY : icon.midX
        let centers = neighbors.filter { $0.intersects(screen) }.map { vertical ? $0.midY : $0.midX }
        let before = centers.filter { $0 < center }.max()
        let after = centers.filter { $0 > center }.min()
        let lower = before.map { ($0 + center) / 2 } ?? ((vertical ? icon.minY : icon.minX) - 8)
        let upper = after.map { ($0 + center) / 2 } ?? ((vertical ? icon.maxY : icon.maxX) + 8)
        // Include the full magnified icon, rather than clipping it to a fixed strip.
        switch edge {
        case .left:
            return CGRect(x: screen.minX, y: lower, width: max(1, icon.maxX + 6 - screen.minX), height: upper - lower)
        case .right:
            return CGRect(x: icon.minX - 6, y: lower, width: max(1, screen.maxX - icon.minX + 6), height: upper - lower)
        case .bottom:
            return CGRect(x: lower, y: icon.minY - 6, width: upper - lower, height: max(1, screen.maxY - icon.minY + 6))
        case .top:
            return CGRect(x: lower, y: screen.minY, width: upper - lower, height: max(1, icon.maxY + 6 - screen.minY))
        }
    }

    static func target(at point: CGPoint, frames: [CGRect], lanes: [CGRect], current: Int?, edge: DockEdge) -> Int? {
        let vertical = edge == .left || edge == .right
        func closest(_ indices: [Int]) -> Int? {
            indices.min {
                abs((vertical ? frames[$0].midY : frames[$0].midX) - (vertical ? point.y : point.x)) <
                abs((vertical ? frames[$1].midY : frames[$1].midX) - (vertical ? point.y : point.x))
            }
        }
        // A real neighboring icon wins over the current icon's hysteresis margin.
        if let exact = closest(frames.indices.filter { frames[$0].contains(point) }) { return exact }
        if let current, lanes.indices.contains(current),
           lanes[current].insetBy(dx: vertical ? 0 : -4, dy: vertical ? -4 : 0).contains(point) {
            return current
        }
        return closest(lanes.indices.filter { lanes[$0].contains(point) })
    }

    /// Protect the gap toward the preview, not the entire rectangle around the Dock and panel.
    static func bridgeContains(_ point: CGPoint, icon: CGRect, panel: CGRect, edge: DockEdge) -> Bool {
        let start: CGFloat
        let end: CGFloat
        let along: CGFloat
        let across: CGFloat
        let iconLow: CGFloat
        let iconHigh: CGFloat
        let panelLow: CGFloat
        let panelHigh: CGFloat
        switch edge {
        case .left, .right:
            start = edge == .left ? icon.maxX : icon.minX
            end = edge == .left ? panel.minX : panel.maxX
            along = point.x
            across = point.y
            iconLow = icon.minY; iconHigh = icon.maxY
            panelLow = panel.minY; panelHigh = panel.maxY
        case .bottom, .top:
            start = edge == .bottom ? icon.minY : icon.maxY
            end = edge == .bottom ? panel.maxY : panel.minY
            along = point.y
            across = point.x
            iconLow = icon.minX; iconHigh = icon.maxX
            panelLow = panel.minX; panelHigh = panel.maxX
        }
        guard abs(end - start) > 0.5,
              along >= min(start, end) - 4, along <= max(start, end) + 4 else { return false }
        let progress = min(1, max(0, (along - start) / (end - start)))
        let lower = iconLow + (panelLow - iconLow) * progress - 6
        let upper = iconHigh + (panelHigh - iconHigh) * progress + 6
        return across >= lower && across <= upper
    }

    static func stableOrder<ID: Hashable>(_ latest: [ID], previous: [ID]) -> [ID] {
        let available = Set(latest)
        let existing = Set(previous)
        return previous.filter { available.contains($0) } + latest.filter { !existing.contains($0) }
    }
}
