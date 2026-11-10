import AppKit
import CoreGraphics

final class HoverController: @unchecked Sendable {
    private var icons: [DockIcon] = []
    private var edge: DockEdge = .bottom
    private var monitor: Any?
    private var localMonitor: Any?
    private var iconTimer: Timer?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var edgeRefresh: DispatchWorkItem?
    private var edgeAttempts = 0
    private var sawMouse = false
    private var lastPoint = CGPoint.zero
    private var pendingID: String?
    private var shownID: String?
    private var emptyID: String?
    private var emptyUntil = Date.distantPast
    private var lastIconRead = Date.distantPast
    private var hoverTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var watchGeneration = 0
    private var activeObserver: NSObjectProtocol?
    private var samplePreviewPinnedUntil: Date?
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
        panel.onMinimize = { [weak self] card in
            WindowCatalog.minimize(card)
            self?.refreshAfterClose()
        }
        panel.onQuit = { [weak self] card in
            WindowCatalog.quit(card)
            self?.refreshAfterClose()
        }
        panel.onMove = { [weak self] card, spaceID in
            DesktopSpaces.move(windowID: card.id, to: spaceID)
            self?.refreshAfterClose()
        }
        panel.onSnap = { card in
            WindowSnap.cycleHalf(pid: card.pid, id: card.id, frame: card.frame)
        }
        panel.onShot = { card in
            ShotShelf.shared.capture(window: card.id)
        }
        ClickCatcher.shared.onClick = { [weak self] id, part in
            _ = self?.panel.fire(id, part)
        }
    }

    func showSamplePreview() -> String? {
        guard AXIsProcessTrusted() else {
            return "Accessibility is off. Turn it on, then click Show a preview."
        }
        guard AppDelegate.shared.previewsAreEnabled else {
            return "Window previews are turned off. Turn them on in Settings → Dock to see previews."
        }
        // Preview must wake the same hover path as a normal launch.
        if !isRunning { start() }
        loadIcons()
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
        samplePreviewPinnedUntil = Date().addingTimeInterval(14.0)
        show(icon)
        if !CGPreflightScreenCaptureAccess() {
            return "Showing \(icon.title) without pictures. Turn on Screen Recording to see the windows."
        }
        return nil
    }

    func start() {
        guard AXIsProcessTrusted() else { return }
        if isRunning {
            wakeHover()
            return
        }
        isRunning = true
        // First load must not wait for a Preview click or a mouse-moved event.
        loadIcons()
        seedMouse()
        installMonitor()
        installPoll()
        watchActivation()
        // resource: idle 2.0 — Dock icons are read only while Show Bar is idle in the menu bar.
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshIcons()
        }
        // Global monitors sometimes stay quiet until the first RunLoop turn after launch.
        DispatchQueue.main.async { [weak self] in
            self?.wakeHover()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.wakeHover()
        }
    }

    func stop() {
        isRunning = false
        iconTimer?.invalidate()
        iconTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        hoverTask?.cancel()
        hideTask?.cancel()
        watchTask?.cancel()
        watchGeneration += 1
        pendingID = nil
        shownID = nil
        panel.hide()
        edgeRefresh?.cancel()
        edgeRefresh = nil
        edgeAttempts = 0
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        activeObserver = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        monitor = nil
        localMonitor = nil
    }

    /// Reload icons and check the pointer without waiting for a mouse-moved event.
    private func wakeHover() {
        guard isRunning else { return }
        if monitor == nil { installMonitor() }
        loadIcons()
        seedMouse()
        mouseMoved(to: lastPoint)
    }

    private func seedMouse() {
        lastPoint = quartzMouse()
        sawMouse = true
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
        lastIconRead = Date()
        let latest = DockReader.icons()
        // Dock animations can briefly return no AX children. Keep the last usable geometry.
        guard !latest.isEmpty else { return }
        icons = latest
        edge = DockReader.edge(for: icons)
        guard panel.isShown else {
            guard sawMouse, let icon = icon(at: lastPoint) else { return }
            consider(icon)
            return
        }
        if panel.pointerInside() {
            panel.markCardUnderMouse()
            if let shownID, let icon = icons.first(where: { $0.id == shownID }) {
                panel.updateAnchor(icon.frame, edge: edge)
            }
            return
        }
        guard let shownID, let icon = icons.first(where: { $0.id == shownID }), DockReader.isHoverable(icon.frame) else {
            hideNow()
            return
        }
        panel.updateAnchor(icon.frame, edge: edge)
    }

    /// Auto-hide animates on the Dock process. AX queries at that moment freeze the bar.
    private func leaveDockAlone() -> Bool {
        guard mouseNearScreenEdge() else { return false }
        for icon in icons where DockReader.isHoverable(icon.frame) {
            return false
        }
        return true
    }

    private func mouseNearScreenEdge() -> Bool {
        let point = quartzMouse()
        for screen in NSScreen.screens {
            let frame = Coordinates.flip(screen.frame)
            guard frame.contains(point) else { continue }
            if point.x - frame.minX < 24 || frame.maxX - point.x < 24 || point.y - frame.minY < 24 || frame.maxY - point.y < 24 {
                return true
            }
        }
        return false
    }

    private func scheduleEdgeRefresh() {
        guard edgeRefresh == nil else { return }
        let delay = edgeAttempts == 0 ? 0.12 : 0.08
        let work = DispatchWorkItem { [weak self] in
            self?.edgeRefresh = nil
            guard let self, self.isRunning else { return }
            self.loadIcons()
            let visible = self.icons.contains { DockReader.isHoverable($0.frame) }
            if visible || !self.mouseNearScreenEdge() {
                self.edgeAttempts = 0
                self.mouseMoved(to: self.quartzMouse())
                return
            }
            self.edgeAttempts += 1
            if self.edgeAttempts < 12 {
                self.scheduleEdgeRefresh()
            } else {
                self.edgeAttempts = 0
            }
        }
        edgeRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func quartzMouse() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: Coordinates.primaryHeight - mouse.y)
    }

    private func installMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let kind = event.type
            DispatchQueue.main.async {
                guard let self else { return }
                let mouse = NSEvent.mouseLocation
                let quartz = CGPoint(x: mouse.x, y: Coordinates.primaryHeight - mouse.y)
                if kind == .leftMouseDown || kind == .rightMouseDown {
                    self.mouseDown(screenPoint: mouse, quartzPoint: quartz)
                } else {
                    self.mouseMoved(to: quartz)
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let aimedAtPanel = event.window == nil || self.panel.owns(event.window)
                if aimedAtPanel, self.panel.handleClick(at: NSEvent.mouseLocation) { return nil }
                return event
            }
            guard self.panel.pointerInside() else { return event }
            self.cancelHide()
            self.panel.markCardUnderMouse()
            return event
        }
    }

    /// Backup for a quiet global monitor. Fast only while the pointer is at the Dock.
    private func installPoll() {
        schedulePoll(interval: 1.0)
    }

    private func schedulePoll(interval: TimeInterval) {
        guard abs(pollInterval - interval) > 0.01 || pollTimer == nil else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        // resource: idle 1.0 — 0.12 is used only while the pointer is on the Dock or a preview is open.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollHover() {
        guard isRunning, NSEvent.pressedMouseButtons == 0 else { return }
        let point = quartzMouse()
        let engaged = panel.isShown || pointerNearDock(point)
        if engaged {
            schedulePoll(interval: 0.12)
        } else {
            schedulePoll(interval: 1.0)
        }
        if point == lastPoint {
            if panel.pointerInside() {
                panel.markCardUnderMouse()
                return
            }
            // Recheck stationary pointers after Dock auto-hide, a Space change, or an empty app.
            if !engaged { return }
        }
        mouseMoved(to: point)
    }

    private func pointerNearDock(_ point: CGPoint) -> Bool {
        if mouseNearScreenEdge() { return true }
        let hoverable = icons.filter { DockReader.isHoverable($0.frame) }
        guard !hoverable.isEmpty else { return false }
        return hoverable.contains { laneHit($0, among: hoverable).insetBy(dx: -8, dy: -8).contains(point) }
    }

    private func watchActivation() {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.wakeHover()
        }
    }

    func reloadAppearance() {
        guard let shownID, let icon = icons.first(where: { $0.id == shownID }) else { return }
        show(icon)
    }

    func noteDockMoved() {
        hideNow()
        loadIcons()
        // The Dock slides after the position change. Read it again once it has settled.
        for delay in [0.45, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.loadIcons()
                self?.wakeHover()
            }
        }
    }

    private func mouseDown(screenPoint: NSPoint, quartzPoint: CGPoint) {
        lastPoint = quartzPoint
        if panel.handleClick(at: screenPoint) { return }
        guard panel.isShown, !panel.pointerInside(), !panel.containsAX(quartzPoint) else { return }
        hideNow()
    }

    private func mouseMoved(to point: CGPoint) {
        guard isRunning, NSEvent.pressedMouseButtons == 0 else { return }
        lastPoint = point
        sawMouse = true
        if panel.pointerOnPanel(point) {
            samplePreviewPinnedUntil = nil
            cancelPendingHover()
            cancelHide()
            panel.markCardUnderMouse()
            return
        }
        if pointerNearDock(point), Date().timeIntervalSince(lastIconRead) >= 0.12 {
            if leaveDockAlone() { scheduleEdgeRefresh() }
            else { loadIcons() }
        }
        // A Dock icon beats the panel's slack margin, or a side Dock can never switch apps.
        if let icon = icon(at: point) {
            if icon.id != emptyID || Date() >= emptyUntil { cancelHide() }
            if let shownID, let current = icons.first(where: { $0.id == shownID }) {
                panel.updateAnchor(current.frame, edge: edge)
            }
            if panel.pointerInside() { panel.markCardUnderMouse() }
            consider(icon)
            return
        }
        emptyID = nil
        cancelPendingHover()
        if panel.pointerInside() || panel.containsAX(point) || panel.approachContains(point) || bridgeContains(point) {
            cancelHide()
            panel.markCardUnderMouse()
            return
        }
        scheduleHide()
    }

    private func consider(_ icon: DockIcon) {
        if icon.id == emptyID, Date() < emptyUntil {
            if shownID != nil { scheduleHide() }
            return
        }
        if icon.id == shownID {
            pendingID = nil
            hoverTask?.cancel()
            cancelHide()
            panel.updateAnchor(icon.frame, edge: edge)
            return
        }
        if icon.id == pendingID { return }
        pendingID = icon.id
        hoverTask?.cancel()
        let delay = shownID == nil ? PreviewInteraction.openDelay : PreviewInteraction.switchDelay
        let iconID = icon.id
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let controller = self
            await MainActor.run {
                guard controller?.pendingID == iconID else { return }
                controller?.commitHover(id: iconID)
            }
        }
    }

    private func cancelPendingHover() {
        hoverTask?.cancel()
        hoverTask = nil
        pendingID = nil
    }

    private func commitHover(id: String) {
        let point = quartzMouse()
        guard let icon = icon(at: point), icon.id == id, DockReader.isHoverable(icon.frame) else {
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
            emptyUntil = Date().addingTimeInterval(0.6)
            if shownID != nil { scheduleHide() }
            return
        }
        watchTask?.cancel()
        watchGeneration += 1
        let generation = watchGeneration
        cancelHide()
        emptyID = nil
        DockAutohide.pin()
        let iconImage = WindowCatalog.appIcon(for: icon)
        panel.present(cards: cards, anchor: icon.frame, edge: edge, appIcon: iconImage)
        panel.markCardUnderMouse()
        ClickCatcher.shared.start()
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let same = shownID == icon.id
        shownID = icon.id
        if !same {
            Telemetry.shared.track("dock_preview_shown", params: ["app": icon.title, "window_count": "\(cards.count)"])
            NotificationCenter.default.post(name: NSNotification.Name("ShowBar.dockPreviewShown"), object: nil, userInfo: ["app": icon.title])
        }
        watchTask = Task { [weak self] in
            await self?.watch(iconID: icon.id, generation: generation, cards: cards)
        }
    }

    private func watch(iconID: String, generation: Int, cards: [WindowCard]) async {
        var current = cards
        while !Task.isCancelled {
            let refresh = await WindowCatalog.refresh(current) { [weak self] thumbnail in
                let controller = self
                Task { @MainActor in
                    guard controller?.shownID == iconID, controller?.watchGeneration == generation else { return }
                    controller?.panel.apply([thumbnail])
                }
            }
            guard !Task.isCancelled else { return }
            current = refresh.cards
            let titled = current
            await MainActor.run {
                guard self.shownID == iconID, self.watchGeneration == generation else { return }
                // Each image was already delivered above; applying the batch again restarts its fade.
                self.panel.sync(cards: titled)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            let previousIDs = current.map(\.id)
            let latest: [WindowCard]? = await MainActor.run {
                guard self.shownID == iconID, self.watchGeneration == generation,
                      let icon = self.icons.first(where: { $0.id == iconID }) else { return nil }
                let cards = WindowCatalog.windows(for: icon)
                guard !cards.isEmpty else {
                    self.hideNow()
                    return nil
                }
                // Window Server z-order changes must not shuffle cards under the pointer.
                let order = PreviewInteraction.stableOrder(cards.map(\.id), previous: previousIDs)
                let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
                let ordered = order.compactMap { byID[$0] }
                self.panel.sync(cards: ordered)
                return ordered
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
        watchGeneration += 1
        let generation = watchGeneration
        watchTask = Task { [weak self] in
            await self?.watch(iconID: icon.id, generation: generation, cards: cards)
        }
    }

    private func icon(at point: CGPoint) -> DockIcon? {
        let hoverable = icons.filter { DockReader.isHoverable($0.frame) }
        let index = PreviewInteraction.target(
            at: point,
            frames: hoverable.map(\.frame),
            lanes: hoverable.map { laneHit($0, among: hoverable) },
            current: hoverable.firstIndex { $0.id == shownID },
            edge: edge
        )
        return index.map { hoverable[$0] }
    }

    private func laneHit(_ icon: DockIcon, among icons: [DockIcon]) -> CGRect {
        let screen = Coordinates.screen(containing: Coordinates.flip(icon.frame)) ?? NSScreen.main
        let screenFrame = Coordinates.flip(screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        return PreviewInteraction.lane(for: icon.frame, neighbors: icons.map(\.frame), screen: screenFrame, edge: edge)
    }

    private func bridgeContains(_ point: CGPoint) -> Bool {
        panel.approachContains(point)
    }

    private func scheduleHide() {
        guard panel.isShown, hideTask == nil else { return }
        if let until = samplePreviewPinnedUntil, Date() < until {
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: PreviewInteraction.closeDelay)
            guard !Task.isCancelled else { return }
            let controller = self
            await MainActor.run { controller?.hideIfStillOutside() }
        }
    }

    private func hideIfStillOutside() {
        hideTask = nil
        if let until = samplePreviewPinnedUntil, Date() < until {
            return
        }
        let mouse = quartzMouse()
        if let target = icon(at: mouse), target.id == emptyID {
            hideNow()
            return
        }
        if panel.pointerInside() || icon(at: mouse) != nil || panel.containsAX(mouse) || bridgeContains(mouse) {
            panel.markCardUnderMouse()
            return
        }
        hideNow()
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    func dismissPreview() {
        samplePreviewPinnedUntil = nil
        hideNow()
    }

    private func hideNow() {
        samplePreviewPinnedUntil = nil
        WindowCatalog.endReveal(committing: nil)
        cancelHide()
        hoverTask?.cancel()
        watchTask?.cancel()
        watchGeneration += 1
        pendingID = nil
        shownID = nil
        ClickCatcher.shared.stop()
        panel.hide()
        DockAutohide.restore()
    }
}

/// Moves the real Dock. CoreDock orientation: top 1, bottom 2, left 3, right 4.
enum DockPlacement: String, CaseIterable, Hashable {
    case left, right, top, bottom

    private var code: Int32 {
        switch self {
        case .top: return 1
        case .bottom: return 2
        case .left: return 3
        case .right: return 4
        }
    }

    static var current: DockPlacement {
        get {
            var orientation = Int32(0)
            var pin = Int32(0)
            guard let read = reader() else { return .bottom }
            read(&orientation, &pin)
            switch orientation {
            case 1: return .top
            case 2: return .bottom
            case 3: return .left
            case 4: return .right
            default: return .bottom
            }
        }
        set {
            var orientation = Int32(0)
            var pin = Int32(2)
            reader()?(&orientation, &pin)
            if pin == 0 { pin = 2 }
            writer()?(newValue.code, pin)
        }
    }

    private static func reader() -> (@convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void)? {
        DockAutohide.symbol("CoreDockGetOrientationAndPinning")
    }

    private static func writer() -> (@convention(c) (Int32, Int32) -> Void)? {
        DockAutohide.symbol("CoreDockSetOrientationAndPinning")
    }
}

enum DockAutohide {
    private static let restoreKey = "ShowBar.restoreAutohide"
    private static var pinned = false

    static func pin() {
        // In modern macOS (Sonoma/Sequoia), repeatedly toggling CoreDockSetAutoHideEnabled
        // causes the Dock process to redraw and jitter. We preserve user preference.
    }

    static func restore() {
        guard UserDefaults.standard.bool(forKey: restoreKey) else {
            pinned = false
            return
        }
        setter()?(1)
        UserDefaults.standard.set(false, forKey: restoreKey)
        pinned = false
    }

    private static func getter() -> (@convention(c) () -> UInt8)? {
        symbol("CoreDockGetAutoHideEnabled")
    }

    private static func setter() -> (@convention(c) (UInt8) -> Void)? {
        symbol("CoreDockSetAutoHideEnabled")
    }

    private static let services: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        RTLD_LAZY
    )

    static func symbol<T>(_ name: String) -> T? {
        guard let services, let raw = dlsym(services, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}

/// Sees the click even when the preview window does not. Installed only while a preview is visible.
final class ClickCatcher {
    static let shared = ClickCatcher()
    var onClick: ((CGWindowID, PreviewClickPart) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    private var boxes: [PreviewClickBox] = []
    private var height: CGFloat = 0

    func refresh(_ panel: PreviewPanel) {
        let next = panel.clickBoxes()
        lock.lock()
        boxes = next
        height = Coordinates.primaryHeight
        lock.unlock()
    }

    func start() {
        guard tap == nil else { return }
        height = Coordinates.primaryHeight
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: previewClickCallback,
            userInfo: nil
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    /// The desktop menu is tracked by AppKit. While it is open the tap must not swallow those clicks.
    func setSuspended(_ suspended: Bool) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: !suspended)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        lock.lock()
        boxes = []
        lock.unlock()
    }

    fileprivate func screenPoint(from quartz: CGPoint) -> CGPoint {
        lock.lock()
        let height = self.height
        lock.unlock()
        return CGPoint(x: quartz.x, y: height - quartz.y)
    }

    fileprivate func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func claim(_ point: CGPoint) -> (CGWindowID, PreviewClickPart)? {
        lock.lock()
        let boxes = self.boxes
        lock.unlock()
        for box in boxes {
            if let part = box.part(at: point) {
                return (box.id, part)
            }
        }
        return nil
    }
}

private func previewClickCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        ClickCatcher.shared.enable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .leftMouseDown || type == .rightMouseDown else {
        return Unmanaged.passUnretained(event)
    }
    let screen = ClickCatcher.shared.screenPoint(from: event.location)
    guard let hit = ClickCatcher.shared.claim(screen) else {
        return Unmanaged.passUnretained(event)
    }
    if Thread.isMainThread {
        ClickCatcher.shared.onClick?(hit.0, hit.1)
    } else {
        DispatchQueue.main.async {
            ClickCatcher.shared.onClick?(hit.0, hit.1)
        }
    }
    return nil
}
