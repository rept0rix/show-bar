import AppKit
import CoreGraphics

final class HoverController: @unchecked Sendable {
    private var icons: [DockIcon] = []
    private var edge: DockEdge = .bottom
    private var monitor: Any?
    private var iconTimer: Timer?
    private var edgeRefresh: DispatchWorkItem?
    private var lastPoint = CGPoint.zero
    private var pendingID: String?
    private var shownID: String?
    private var emptyID: String?
    private var hoverTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private let panel = PreviewPanel()
    private(set) var isRunning = false
    var iconCount: Int { icons.count }

    init() {
        panel.onSelect = { [weak self] card in
            self?.hideNow()
            WindowCatalog.focus(card)
        }
        panel.onClose = { [weak self] card in
            WindowCatalog.close(card)
            self?.refreshAfterClose()
        }
    }

    func showSamplePreview() -> String? {
        guard AXIsProcessTrusted() else {
            return "Accessibility is off. Turn it on, then click Show a preview."
        }
        refreshIcons()
        let front = NSWorkspace.shared.frontmostApplication
        let preferred = icons.first { icon in
            if let bundleID = icon.bundleID, bundleID == front?.bundleIdentifier { return true }
            return icon.title.caseInsensitiveCompare(front?.localizedName ?? "") == .orderedSame
        }
        let icon = [preferred].compactMap { $0 }.first { !WindowCatalog.windows(for: $0).isEmpty }
            ?? icons.first { !WindowCatalog.windows(for: $0).isEmpty }
        guard let icon else {
            return "No open windows were found. Open an app from the Dock and try again."
        }
        show(icon)
        if !CGPreflightScreenCaptureAccess() {
            return "Showing \(icon.title) without pictures. Turn on Screen Recording to see the windows."
        }
        return nil
    }

    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true
        refreshIcons()
        installMonitor()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.refreshIcons()
        }
    }

    func stop() {
        isRunning = false
        iconTimer?.invalidate()
        iconTimer = nil
        hoverTask?.cancel()
        hideTask?.cancel()
        watchTask?.cancel()
        pendingID = nil
        shownID = nil
        panel.hide()
        edgeRefresh?.cancel()
        edgeRefresh = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func refreshIcons() {
        guard isRunning else { return }
        if leaveDockAlone() {
            scheduleEdgeRefresh()
            return
        }
        loadIcons()
    }

    private func loadIcons() {
        icons = DockReader.icons()
        edge = DockReader.edge(for: icons)
        guard panel.isShown else { return }
        guard let shownID, let icon = icons.first(where: { $0.id == shownID }), DockReader.isOnScreen(icon.frame) else {
            hideNow()
            return
        }
        panel.updateAnchor(icon.frame, edge: edge)
    }

    /// Auto-hide animates on the Dock process. AX queries at that moment freeze the bar.
    private func leaveDockAlone() -> Bool {
        let point = quartzMouse()
        var nearEdge = false
        for screen in NSScreen.screens {
            let frame = Coordinates.flip(screen.frame)
            if point.x - frame.minX < 8 || frame.maxX - point.x < 8 || point.y - frame.minY < 8 || frame.maxY - point.y < 8 {
                nearEdge = true
                break
            }
        }
        if !nearEdge { return false }
        for icon in icons where DockReader.isOnScreen(icon.frame) {
            return false
        }
        return true
    }

    private func scheduleEdgeRefresh() {
        guard edgeRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.edgeRefresh = nil
            guard let self, self.isRunning else { return }
            self.loadIcons()
        }
        edgeRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func quartzMouse() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: Coordinates.primaryHeight - mouse.y)
    }

    private func installMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            let appKit = event.locationInWindow
            let point = CGPoint(x: appKit.x, y: Coordinates.primaryHeight - appKit.y)
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.mouseDown(at: point)
            } else {
                self.mouseMoved(to: point)
            }
        }
    }

    private func mouseDown(at point: CGPoint) {
        lastPoint = point
        guard panel.isShown, !panel.containsAX(point) else { return }
        hideNow()
    }

    private func mouseMoved(to point: CGPoint) {
        guard isRunning, NSEvent.pressedMouseButtons == 0 else { return }
        lastPoint = point
        if let icon = icon(at: point) {
            cancelHide()
            if let shownID, let current = icons.first(where: { $0.id == shownID }) {
                panel.updateAnchor(current.frame, edge: edge)
            }
            consider(icon)
            return
        }
        emptyID = nil
        if panel.containsAX(point) || bridgeContains(point) {
            cancelHide()
            return
        }
        scheduleHide()
    }

    private func consider(_ icon: DockIcon) {
        if icon.id == emptyID {
            if shownID != nil { hideNow() }
            return
        }
        if icon.id == shownID {
            pendingID = nil
            hoverTask?.cancel()
            panel.updateAnchor(icon.frame, edge: edge)
            return
        }
        if icon.id == pendingID { return }
        pendingID = icon.id
        hoverTask?.cancel()
        let delay: UInt64 = shownID == nil ? 280_000_000 : 40_000_000
        let iconID = icon.id
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let controller = self
            await MainActor.run { controller?.commitHover(id: iconID) }
        }
    }

    private func commitHover(id: String) {
        let point = quartzMouse()
        guard let icon = icon(at: point), icon.id == id, DockReader.isOnScreen(icon.frame) else {
            if pendingID == id { pendingID = nil }
            return
        }
        pendingID = nil
        show(icon)
    }

    private func show(_ icon: DockIcon) {
        let cards = WindowCatalog.windows(for: icon)
        guard !cards.isEmpty else {
            emptyID = icon.id
            if shownID != nil { hideNow() }
            return
        }
        emptyID = nil
        let iconImage = WindowCatalog.appIcon(for: icon)
        panel.present(cards: cards, anchor: icon.frame, edge: edge, appIcon: iconImage)
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let same = shownID == icon.id
        shownID = icon.id
        if !same {
            watchTask?.cancel()
            watchTask = Task { [weak self] in
                await self?.watch(iconID: icon.id, cards: cards)
            }
        }
    }

    private func watch(iconID: String, cards: [WindowCard]) async {
        var current = cards
        while !Task.isCancelled {
            let refresh = await WindowCatalog.refresh(current)
            if Task.isCancelled { return }
            let titled = refresh.cards
            await MainActor.run {
                guard self.shownID == iconID else { return }
                self.panel.sync(cards: titled)
                self.panel.apply(refresh.thumbnails)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            let latest: [WindowCard]? = await MainActor.run {
                guard self.shownID == iconID, let icon = self.icons.first(where: { $0.id == iconID }) else { return nil }
                let cards = WindowCatalog.windows(for: icon).map { card in
                    guard let previous = titled.first(where: { $0.id == card.id }),
                          previous.title.count > card.title.count else { return card }
                    return WindowCard(id: card.id, pid: card.pid, title: previous.title, frame: card.frame)
                }
                if cards.isEmpty {
                    self.hideNow()
                    return nil
                }
                self.panel.sync(cards: cards)
                self.panel.updateAnchor(icon.frame, edge: self.edge)
                return cards
            }
            guard let latest else { return }
            current = latest
        }
    }

    private func refreshAfterClose() {
        guard let shownID, let icon = icons.first(where: { $0.id == shownID }) else { return }
        let cards = WindowCatalog.windows(for: icon)
        if cards.isEmpty {
            hideNow()
            return
        }
        panel.sync(cards: cards)
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            await self?.watch(iconID: icon.id, cards: cards)
        }
    }

    private func icon(at point: CGPoint) -> DockIcon? {
        let hits = icons.filter {
            DockReader.isOnScreen($0.frame) && DockReader.hitFrame($0.frame, edge: edge).contains(point)
        }
        return hits.min { lhs, rhs in
            hypot(lhs.frame.midX - point.x, lhs.frame.midY - point.y)
                < hypot(rhs.frame.midX - point.x, rhs.frame.midY - point.y)
        }
    }

    private func bridgeContains(_ point: CGPoint) -> Bool {
        guard panel.isShown, let shownID, let icon = icons.first(where: { $0.id == shownID }) else { return false }
        return icon.frame.union(panel.frameAX).insetBy(dx: -16, dy: -16).contains(point)
    }

    private func scheduleHide() {
        guard panel.isShown, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            let controller = self
            await MainActor.run { controller?.hideIfStillOutside() }
        }
    }

    private func hideIfStillOutside() {
        hideTask = nil
        let point = CGEvent(source: nil)?.location ?? lastPoint
        if icon(at: point) != nil || panel.containsAX(point) || bridgeContains(point) { return }
        hideNow()
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func hideNow() {
        cancelHide()
        hoverTask?.cancel()
        watchTask?.cancel()
        pendingID = nil
        shownID = nil
        panel.hide()
    }
}
