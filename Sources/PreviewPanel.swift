import AppKit
import QuartzCore

enum PreviewPreferences {
    private static let sizeKey = "ShowBar.previewSize"
    private static let countKey = "ShowBar.maxWindows"
    private static let titlesKey = "ShowBar.showTitles"

    static var sizeName: String {
        get { UserDefaults.standard.string(forKey: sizeKey) ?? "medium" }
        set {
            UserDefaults.standard.set(newValue, forKey: sizeKey)
            UserDefaults.standard.synchronize()
        }
    }

    static var scale: CGFloat {
        switch sizeName {
        case "small": return 0.72
        case "large": return 1.4
        default: return 1
        }
    }

    static var maxWindows: Int {
        get {
            if UserDefaults.standard.object(forKey: countKey) == nil { return 0 }
            return UserDefaults.standard.integer(forKey: countKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: countKey)
            UserDefaults.standard.synchronize()
        }
    }

    static func limit<T>(_ items: [T]) -> [T] {
        let cap = maxWindows == 0 ? 16 : max(maxWindows, 1)
        return Array(items.prefix(cap))
    }

    static var showTitles: Bool {
        get {
            if UserDefaults.standard.object(forKey: titlesKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: titlesKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: titlesKey)
            UserDefaults.standard.synchronize()
        }
    }
}

enum PreviewMetrics {
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 8
    static let titleGap: CGFloat = 6
    static let titleHeight: CGFloat = 16
    static let titleUnderline: CGFloat = 6
    static var maxCount: Int { PreviewPreferences.maxWindows }

    static func thumbSize() -> CGSize {
        let width: CGFloat
        switch PreviewPreferences.sizeName {
        case "small": width = 148
        case "large": width = 268
        default: width = 200
        }
        return CGSize(width: width, height: (width * 0.62).rounded())
    }

    static func grid(count: Int, screenWidth: CGFloat, showsFooter: Bool) -> (thumb: CGSize, columns: Int, panel: CGSize) {
        let count = max(count, 1)
        let thumb = thumbSize()
        let titles: CGFloat = PreviewPreferences.showTitles ? titleGap + titleHeight + titleUnderline : 0
        let cardHeight = thumb.height + titles
        let maxWidth = min(max(screenWidth - 24, 360), 1180)
        var columns = max(1, Int((maxWidth - inset * 2 + spacing) / (thumb.width + spacing)))
        columns = min(columns, count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let width = inset * 2 + thumb.width * CGFloat(columns) + spacing * CGFloat(max(columns - 1, 0))
        let footer: CGFloat = showsFooter ? 22 : 0
        let height = inset * 2 + cardHeight * CGFloat(rows) + spacing * CGFloat(max(rows - 1, 0)) + footer
        return (thumb, columns, CGSize(width: width.rounded(), height: height.rounded()))
    }
}

enum PreviewClickPart {
    case close, minimize, quit, desktop, snap, shot, body
}

struct PreviewClickBox {
    let id: CGWindowID
    let bounds: NSRect
    let close: NSRect
    let minimize: NSRect
    let quit: NSRect
    let desktop: NSRect
    let snap: NSRect
    let shot: NSRect

    func part(at point: NSPoint) -> PreviewClickPart? {
        guard bounds.contains(point) else { return nil }
        if !snap.isEmpty, snap.insetBy(dx: -4, dy: -4).contains(point) { return .snap }
        if !shot.isEmpty, shot.insetBy(dx: -4, dy: -4).contains(point) { return .shot }
        if !close.isEmpty, close.insetBy(dx: -4, dy: -4).contains(point) { return .close }
        if !minimize.isEmpty, minimize.insetBy(dx: -4, dy: -4).contains(point) { return .minimize }
        if !quit.isEmpty, quit.insetBy(dx: -6, dy: -6).contains(point) { return .quit }
        if !desktop.isEmpty, desktop.insetBy(dx: -6, dy: -6).contains(point) { return .desktop }
        return .body
    }
}

final class PreviewPanel {
    var onSelect: ((WindowCard) -> Void)?
    var onClose: ((WindowCard) -> Void)?
    var onMinimize: ((WindowCard) -> Void)?
    var onQuit: ((WindowCard) -> Void)?
    var onMove: ((WindowCard, UInt64) -> Void)?
    var onSnap: ((WindowCard) -> Void)?
    var onShot: ((WindowCard) -> Void)?
    private var menuHold = false

    private(set) var isShown = false
    private(set) var anchor = CGRect.zero
    private var edge: DockEdge = .bottom
    private var cards: [WindowCard] = []
    private var appIcon: NSImage?
    private var transitionTimer: Timer?
    private var outgoing: PreviewWindow?
    private var renderedSizeName = ""
    private var renderedTitles = false
    private var renderedFooter = false
    private let panel: PreviewWindow
    private let effect = PreviewBackdrop()
    private var pointerTimer: Timer?
    private let stack = ClickStack()
    private let footer = NSButton()
    private var cardViews: [CGWindowID: PreviewCardView] = [:]

    var frameAX: CGRect { Coordinates.flip(panel.frame) }

    init() {
        panel = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // The panel used to be fully clear, so the window server sent every click to the app underneath.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = NSAppearance(named: .darkAqua)

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.24, alpha: 0.38).cgColor
        effect.layer?.borderWidth = 1.2
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
        panel.contentView = effect

        stack.orientation = .vertical
        stack.spacing = PreviewMetrics.spacing
        stack.alignment = .top
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        footer.title = "Turn on Screen Recording to see the pages"
        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.isBordered = false
        footer.contentTintColor = .secondaryLabelColor
        footer.target = self
        footer.action = #selector(openScreenSettings)
        footer.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(footer)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: PreviewMetrics.inset),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -PreviewMetrics.inset),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: PreviewMetrics.inset),
            footer.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 2),
            footer.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: PreviewMetrics.inset),
            footer.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -PreviewMetrics.inset),
            footer.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -6),
        ])
    }

    @objc private func openScreenSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func containsAX(_ point: CGPoint) -> Bool {
        guard isShown else { return false }
        return frameAX.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// AppKit mouse location against the panel frame. This stays valid while the pointer is over our own window.
    func pointerInside() -> Bool {
        if menuHold && isShown { return true }
        guard isShown, panel.isVisible, panel.alphaValue > 0.2 else { return false }
        return panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    /// Pointer is on the panel itself, with no slack. The slack margins overlap Dock icons when the Dock is on a side.
    func pointerOnPanel(_ quartz: CGPoint) -> Bool {
        guard isShown else { return false }
        if menuHold { return true }
        guard panel.isVisible, panel.alphaValue > 0.2 else { return false }
        return frameAX.contains(quartz)
    }

    func holdOpen(_ hold: Bool) {
        menuHold = hold
    }

    func owns(_ window: NSWindow?) -> Bool {
        window === panel
    }

    func markCardUnderMouse() {
        guard isShown, panel.isVisible else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let mouse = NSEvent.mouseLocation
        var hovered: PreviewCardView?
        for card in cardViews.values where screenFrame(of: card).contains(mouse) {
            hovered = card
        }
        for card in cardViews.values {
            card.applyHover(card === hovered, dimmed: hovered != nil && card !== hovered)
        }
        ClickCatcher.shared.refresh(self)
    }

    /// The panel often never receives the click. Compare the pointer with each control's screen rectangle.
    @discardableResult
    func handleClick(at screenPoint: NSPoint) -> Bool {
        guard let box = clickBoxes().first(where: { $0.part(at: screenPoint) != nil }),
              let part = box.part(at: screenPoint) else { return false }
        return fire(box.id, part)
    }

    func clickBoxes() -> [PreviewClickBox] {
        guard isShown else { return [] }
        panel.contentView?.layoutSubtreeIfNeeded()
        return cardViews.map { id, card in
            card.clickBox(id: id) { self.screenFrame(of: $0) }
        }
    }

    @discardableResult
    func fire(_ id: CGWindowID, _ part: PreviewClickPart) -> Bool {
        cardViews[id]?.fire(part) ?? false
    }

    private func screenFrame(of view: NSView) -> NSRect {
        guard view.window != nil else { return .zero }
        return panel.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func startPointerTimer() {
        guard pointerTimer == nil else { return }
        // resource: active 0.033 — runs only while a window preview is visible.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.markCardUnderMouse()
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    func present(cards: [WindowCard], anchor: CGRect, edge: DockEdge, appIcon: NSImage) {
        stopTransition()
        let previous = snapshotWindow()
        outgoing = previous
        self.anchor = anchor
        self.edge = edge
        self.appIcon = appIcon
        self.cards = cards
        WindowCatalog.endReveal(committing: nil)
        renderedFooter = !CGPreflightScreenCaptureAccess()
        footer.isHidden = !renderedFooter
        rebuild(cards)

        // Lay out each image at its final size before showing it. Live window resizing
        // squeezes the fixed-width cards and makes their thumbnails flash during a switch.
        let target = placementFrame()
        let start = offsetTowardDock(target, distance: previous == nil ? 8 : 5)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        isShown = true
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        startPointerTimer()
        animate(from: start, to: target, alpha: 0, targetAlpha: 1, duration: 0.20)
    }

    func updateAnchor(_ anchor: CGRect, edge: DockEdge) {
        guard DockReader.isHoverable(anchor) else { return }
        let oldScreen = Coordinates.screen(containing: Coordinates.flip(self.anchor))
        let newScreen = Coordinates.screen(containing: Coordinates.flip(anchor))
        let movedDisplay = oldScreen?.frame != newScreen?.frame || self.edge != edge
        self.anchor = anchor
        self.edge = edge
        // Keep the panel still during Dock magnification, but keep the pointer bridge
        // attached to the live icon and reposition when the Dock changes displays.
        if movedDisplay, isShown, let appIcon {
            present(cards: cards, anchor: anchor, edge: edge, appIcon: appIcon)
        }
    }

    func sync(cards: [WindowCard]) {
        guard isShown else { return }
        let layoutChanged = cards.map(\.id) != self.cards.map(\.id)
            || renderedFooter != !CGPreflightScreenCaptureAccess()
        if layoutChanged, let appIcon {
            present(cards: cards, anchor: anchor, edge: edge, appIcon: appIcon)
            return
        }
        self.cards = cards
        for card in cards {
            if let view = cardViews[card.id] { configure(view, for: card) }
        }
        // Titles and screenshots never restart or reposition the opening animation.
    }

    func apply(_ thumbnails: [Thumbnail]) {
        guard isShown else { return }
        for thumbnail in thumbnails {
            cardViews[thumbnail.windowID]?.setScreenshot(thumbnail.image)
        }
    }

    func hide() {
        guard isShown else { return }
        WindowCatalog.endReveal(committing: nil)
        isShown = false
        stopPointerTimer()
        stopTransition()
        let start = panel.frame
        animate(from: start, to: offsetTowardDock(start, distance: 5),
                alpha: panel.alphaValue, targetAlpha: 0, duration: 0.14) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        }
    }

    private func stopTransition() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        outgoing?.orderOut(nil)
        outgoing = nil
    }

    private func offsetTowardDock(_ frame: CGRect, distance: CGFloat) -> CGRect {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return frame }
        switch edge {
        case .left: return frame.offsetBy(dx: -distance, dy: 0)
        case .right: return frame.offsetBy(dx: distance, dy: 0)
        case .bottom: return frame.offsetBy(dx: 0, dy: -distance)
        case .top: return frame.offsetBy(dx: 0, dy: distance)
        }
    }

    /// One cancellable driver owns the window animation, including a hide interrupted by a new hover.
    private func animate(from start: CGRect, to target: CGRect, alpha: CGFloat, targetAlpha: CGFloat,
                         duration: TimeInterval, completion: (() -> Void)? = nil) {
        let began = CACurrentMediaTime()
        let outgoingAlpha = outgoing?.alphaValue ?? 0
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.10 : duration
        // resource: active 0.017 — exists only for the 140–200ms preview transition.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - began) / duration)
            let eased = CGFloat(1 - pow(1 - progress, 3))
            let origin = CGPoint(x: start.minX + (target.minX - start.minX) * eased,
                                 y: start.minY + (target.minY - start.minY) * eased)
            self.panel.setFrameOrigin(origin)
            self.panel.alphaValue = alpha + (targetAlpha - alpha) * eased
            self.outgoing?.alphaValue = outgoingAlpha * (1 - eased)
            if progress >= 1 {
                self.stopTransition()
                completion?()
            }
            if self.isShown { self.markCardUnderMouse() }
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func snapshotWindow() -> PreviewWindow? {
        guard panel.isVisible, panel.alphaValue > 0.05,
              let bitmap = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { return nil }
        effect.cacheDisplay(in: effect.bounds, to: bitmap)
        let image = NSImage(size: effect.bounds.size)
        image.addRepresentation(bitmap)
        let snapshot = PreviewWindow(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        snapshot.level = panel.level
        snapshot.isOpaque = false
        snapshot.backgroundColor = .clear
        snapshot.hasShadow = true
        snapshot.hidesOnDeactivate = false
        snapshot.ignoresMouseEvents = true
        snapshot.collectionBehavior = panel.collectionBehavior
        snapshot.isReleasedWhenClosed = false
        let view = NSImageView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.image = image
        view.imageScaling = .scaleNone
        snapshot.contentView = view
        snapshot.alphaValue = panel.alphaValue
        snapshot.orderFrontRegardless()
        return snapshot
    }

    private func rebuild(_ cards: [WindowCard]) {
        let reusable = renderedSizeName == PreviewPreferences.sizeName && renderedTitles == PreviewPreferences.showTitles
            ? cardViews : [:]
        renderedSizeName = PreviewPreferences.sizeName
        renderedTitles = PreviewPreferences.showTitles
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cardViews.removeAll()
        let screenWidth = (Coordinates.screen(containing: Coordinates.flip(anchor)) ?? NSScreen.main)?.visibleFrame.width ?? 1200
        let grid = PreviewMetrics.grid(count: cards.count, screenWidth: screenWidth, showsFooter: false)
        var row: NSStackView?
        for (index, card) in cards.enumerated() {
            if index % grid.columns == 0 {
                let next = ClickStack()
                next.orientation = .horizontal
                next.spacing = PreviewMetrics.spacing
                next.alignment = .top
                stack.addArrangedSubview(next)
                row = next
            }
            let view = reusable[card.id] ?? PreviewCardView(card: card, icon: appIcon, thumb: grid.thumb)
            view.removeFromSuperview()
            configure(view, for: card)
            row?.addArrangedSubview(view)
            cardViews[card.id] = view
        }
    }

    private func configure(_ view: PreviewCardView, for card: WindowCard) {
        view.setTitle(card.title)
        view.setDesktop(DesktopSpaces.desk(for: card.id)?.title ?? "Desktop")
        view.onSelect = { [weak self] in self?.onSelect?(card) }
        view.onClose = { [weak self] in self?.onClose?(card) }
        view.onMinimize = { [weak self] in self?.onMinimize?(card) }
        view.onQuit = { [weak self] in self?.onQuit?(card) }
        view.onMove = { [weak self] space in self?.onMove?(card, space) }
        view.onSnap = { [weak self] in self?.onSnap?(card) }
        view.onShot = { [weak self] in self?.onShot?(card) }
        view.onHold = { [weak self] hold in self?.holdOpen(hold) }
        view.onPointerChanged = { [weak self] in self?.markCardUnderMouse() }
    }

    private func placementFrame() -> CGRect {
        let screen = Coordinates.screen(containing: Coordinates.flip(anchor)) ?? NSScreen.main
        let showsFooter = !CGPreflightScreenCaptureAccess()
        let size = PreviewMetrics.grid(
            count: cards.count,
            screenWidth: screen?.visibleFrame.width ?? 1200,
            showsFooter: showsFooter
        ).panel
        let icon = Coordinates.flip(anchor)

        var origin: CGPoint
        switch edge {
        case .left:
            origin = CGPoint(x: icon.maxX + 8, y: icon.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: icon.minX - size.width - 8, y: icon.midY - size.height / 2)
        case .bottom:
            origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + 8)
        case .top:
            origin = CGPoint(x: icon.midX - size.width / 2, y: icon.minY - size.height - 8)
        }
        if let screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
            origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        }
        return CGRect(origin: origin, size: size).integral
    }

    func approachContains(_ quartz: CGPoint) -> Bool {
        guard isShown else { return false }
        let point = NSPoint(x: quartz.x, y: Coordinates.primaryHeight - quartz.y)
        let iconFlipped = Coordinates.flip(anchor)
        return iconFlipped.union(panel.frame).insetBy(dx: -4, dy: -4).contains(point)
    }
}

final class PreviewWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PreviewBackdrop: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ClickStack: NSStackView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PreviewCardView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onQuit: (() -> Void)?
    var onMove: ((UInt64) -> Void)?
    var onSnap: (() -> Void)?
    var onShot: (() -> Void)?
    var onHold: ((Bool) -> Void)?
    var onPointerChanged: (() -> Void)?

    private let imageView = NSImageView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let underline = NSView()
    private var underlineWidth = NSLayoutConstraint()
    private let closeButton = NSButton()
    private let minimizeButton = NSButton()
    private let quitButton = NSButton()
    private let desktopButton = NSButton()
    private let snapButton = NSButton()
    private let shotButton = NSButton()
    private let windowID: CGWindowID
    private var screenshot: CGImage?

    init(card: WindowCard, icon: NSImage?, thumb: CGSize) {
        let titleBlock: CGFloat = PreviewPreferences.showTitles ? PreviewMetrics.titleGap + PreviewMetrics.titleHeight + PreviewMetrics.titleUnderline : 0
        windowID = card.id
        super.init(frame: NSRect(x: 0, y: 0, width: thumb.width, height: thumb.height + titleBlock))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        imageView.layer?.borderWidth = 2
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(iconView)

        if let cached = ThumbnailCache.shared.get(card.id) {
            let image = NSImage(cgImage: cached, size: NSSize(width: cached.width, height: cached.height))
            imageView.image = image
            screenshot = cached
            iconView.isHidden = true
        }

        titleField.stringValue = card.title
        titleField.isHidden = !PreviewPreferences.showTitles
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.textColor = .labelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleField)

        underline.wantsLayer = true
        underline.layer?.backgroundColor = NSColor.white.cgColor
        underline.layer?.cornerRadius = 1
        underline.alphaValue = 0
        underline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(underline)
        underlineWidth = underline.widthAnchor.constraint(equalToConstant: underlineWidth(for: card.title))

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        closeButton.isBordered = false
        closeButton.bezelStyle = .circular
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        closeButton.layer?.cornerRadius = 10
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 0
        addSubview(closeButton)

        minimizeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Minimize")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        minimizeButton.isBordered = false
        minimizeButton.bezelStyle = .circular
        minimizeButton.contentTintColor = .white
        minimizeButton.wantsLayer = true
        minimizeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        minimizeButton.layer?.cornerRadius = 10
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizePressed)
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false
        minimizeButton.alphaValue = 0
        addSubview(minimizeButton)

        quitButton.title = "Quit"
        quitButton.font = .systemFont(ofSize: 10, weight: .bold)
        quitButton.isBordered = false
        quitButton.contentTintColor = .white
        quitButton.wantsLayer = true
        quitButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        quitButton.layer?.cornerRadius = 7
        quitButton.target = self
        quitButton.action = #selector(quitPressed)
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.alphaValue = 0
        imageView.addSubview(quitButton)

        desktopButton.title = DesktopSpaces.desk(for: card.id)?.title ?? "Desktop"
        desktopButton.font = .systemFont(ofSize: 10, weight: .semibold)
        desktopButton.isBordered = false
        desktopButton.contentTintColor = .white
        desktopButton.wantsLayer = true
        desktopButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        desktopButton.layer?.cornerRadius = 7
        desktopButton.target = self
        desktopButton.action = #selector(desktopPressed)
        desktopButton.translatesAutoresizingMaskIntoConstraints = false
        desktopButton.alphaValue = 0
        desktopButton.isHidden = DesktopSpaces.desks().count <= 1
        imageView.addSubview(desktopButton)

        snapButton.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Snap left or right")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        snapButton.isBordered = false
        snapButton.bezelStyle = .circular
        snapButton.contentTintColor = .white
        snapButton.wantsLayer = true
        snapButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        snapButton.layer?.cornerRadius = 10
        snapButton.target = self
        snapButton.action = #selector(snapPressed)
        snapButton.translatesAutoresizingMaskIntoConstraints = false
        snapButton.alphaValue = 0
        addSubview(snapButton)

        shotButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Copy this window")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        shotButton.isBordered = false
        shotButton.bezelStyle = .circular
        shotButton.contentTintColor = .white
        shotButton.wantsLayer = true
        shotButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        shotButton.layer?.cornerRadius = 10
        shotButton.target = self
        shotButton.action = #selector(shotPressed)
        shotButton.translatesAutoresizingMaskIntoConstraints = false
        shotButton.alphaValue = 0
        addSubview(shotButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: thumb.width),
            heightAnchor.constraint(equalToConstant: thumb.height + titleBlock),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.heightAnchor.constraint(equalToConstant: thumb.height),
            iconView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleField.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: PreviewMetrics.titleGap),
            titleField.heightAnchor.constraint(equalToConstant: PreviewPreferences.showTitles ? PreviewMetrics.titleHeight : 0),
            underline.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: PreviewPreferences.showTitles ? 2 : 0),
            underline.centerXAnchor.constraint(equalTo: centerXAnchor),
            underline.heightAnchor.constraint(equalToConstant: PreviewPreferences.showTitles ? 2 : 0),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underlineWidth,
            closeButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            minimizeButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            minimizeButton.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),
            minimizeButton.widthAnchor.constraint(equalToConstant: 20),
            minimizeButton.heightAnchor.constraint(equalToConstant: 20),
            snapButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            snapButton.leadingAnchor.constraint(equalTo: minimizeButton.trailingAnchor, constant: 6),
            snapButton.widthAnchor.constraint(equalToConstant: 20),
            snapButton.heightAnchor.constraint(equalToConstant: 20),
            shotButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            shotButton.leadingAnchor.constraint(equalTo: snapButton.trailingAnchor, constant: 6),
            shotButton.widthAnchor.constraint(equalToConstant: 20),
            shotButton.heightAnchor.constraint(equalToConstant: 20),
            quitButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
            quitButton.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -6),
            quitButton.heightAnchor.constraint(equalToConstant: 16),
            quitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            desktopButton.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),
            desktopButton.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -6),
            desktopButton.heightAnchor.constraint(equalToConstant: 16),
            desktopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        guard titleField.stringValue != title else { return }
        titleField.stringValue = title
        underlineWidth.constant = underlineWidth(for: title)
    }

    private func underlineWidth(for title: String) -> CGFloat {
        let measured = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return min(bounds.width > 1 ? bounds.width - 16 : 120, max(28, measured))
    }

    func setDesktop(_ title: String) {
        desktopButton.title = title
    }

    func setScreenshot(_ image: CGImage) {
        guard screenshot !== image else { return }
        screenshot = image
        // Preserve the previous pixels until the replacement exists, then blend once.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageView.layer?.add(fade, forKey: "screenshot")
        }
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        iconView.isHidden = true
    }

    func setScreenshot(_ image: NSImage) {
        imageView.image = image
        iconView.isHidden = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerChanged?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        performAction(at: convert(event.locationInWindow, from: nil))
    }

    private var lastAction = 0.0

    func clickBox(id: CGWindowID, frameOf: (NSView) -> NSRect) -> PreviewClickBox {
        PreviewClickBox(
            id: id,
            bounds: frameOf(self),
            close: closeButton.alphaValue > 0.05 ? frameOf(closeButton) : .zero,
            minimize: minimizeButton.alphaValue > 0.05 ? frameOf(minimizeButton) : .zero,
            quit: quitButton.alphaValue > 0.05 && !quitButton.isHidden ? frameOf(quitButton) : .zero,
            desktop: desktopButton.alphaValue > 0.05 && !desktopButton.isHidden ? frameOf(desktopButton) : .zero,
            snap: snapButton.alphaValue > 0.05 ? frameOf(snapButton) : .zero,
            shot: shotButton.alphaValue > 0.05 ? frameOf(shotButton) : .zero
        )
    }

    func fire(_ part: PreviewClickPart) -> Bool {
        runAction {
            switch part {
            case .close: self.onClose?()
            case .minimize: self.onMinimize?()
            case .quit: self.onQuit?()
            case .desktop: self.desktopPressed()
            case .snap: self.onSnap?()
            case .shot: self.onShot?()
            case .body: self.onSelect?()
            }
        }
    }

    @discardableResult
    func performAction(at local: NSPoint) -> Bool {
        guard bounds.contains(local) else { return false }
        return runAction {
            if self.hits(self.snapButton, local: local, pad: 4) { self.onSnap?() }
            else if self.hits(self.shotButton, local: local, pad: 4) { self.onShot?() }
            else if self.hits(self.closeButton, local: local, pad: 4) { self.onClose?() }
            else if self.hits(self.minimizeButton, local: local, pad: 4) { self.onMinimize?() }
            else if self.hits(self.quitButton, local: local, pad: 6) { self.onQuit?() }
            else if self.hits(self.desktopButton, local: local, pad: 6) { self.desktopPressed() }
            else { self.onSelect?() }
        }
    }

    @discardableResult
    func performAction(atScreen point: NSPoint, frameOf: (NSView) -> NSRect) -> Bool {
        guard let part = clickBox(id: windowID, frameOf: frameOf).part(at: point) else { return false }
        return fire(part)
    }

    private func runAction(_ body: () -> Void) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastAction < 0.25 { return true }
        lastAction = now
        body()
        return true
    }

    private func hits(_ button: NSView, local: NSPoint, pad: CGFloat) -> Bool {
        guard !button.isHidden, button.alphaValue > 0.05 else { return false }
        return button.bounds.insetBy(dx: -pad, dy: -pad).contains(button.convert(local, from: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func minimizePressed() {
        onMinimize?()
    }

    @objc private func snapPressed() {
        onSnap?()
    }

    @objc private func shotPressed() {
        onShot?()
    }

    @objc private func quitPressed() {
        onQuit?()
    }

    private var showingMenu = false

    @objc private func desktopPressed() {
        guard !showingMenu else { return }
        showingMenu = true
        // popUp cannot run inside the click tap: that tap swallows the next click, so Desktop 2 never arrives.
        DispatchQueue.main.async { [weak self] in
            self?.presentDesktopMenu()
            self?.showingMenu = false
        }
    }

    private func presentDesktopMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = DesktopSpaces.desk(for: windowID)
        let desks = DesktopSpaces.desks()
        if desks.isEmpty {
            let empty = NSMenuItem(title: "No desktops found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for desk in desks {
            let item = NSMenuItem(title: desk.title, action: #selector(movePressed(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.state = desk.id == current?.id ? .on : .off
            item.representedObject = NSNumber(value: desk.id)
            menu.addItem(item)
        }
        onHold?(true)
        ClickCatcher.shared.setSuspended(true)
        window?.makeKey()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: desktopButton.bounds.height + 4), in: desktopButton)
        ClickCatcher.shared.setSuspended(false)
        onHold?(false)
    }

    @objc private func movePressed(_ sender: NSMenuItem) {
        guard let spaceID = (sender.representedObject as? NSNumber)?.uint64Value else { return }
        let current = DesktopSpaces.desk(for: windowID)
        guard spaceID != current?.id else { return }
        onMove?(spaceID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.desktopButton.title = DesktopSpaces.desk(for: self.windowID)?.title ?? sender.title
        }
    }

    private var hovered = false
    private var dimmed = false

    func applyHover(_ hovered: Bool, dimmed: Bool) {
        let changed = hovered != self.hovered || dimmed != self.dimmed
        self.hovered = hovered
        self.dimmed = dimmed
        guard changed else { return }
        // Hover changes the outline and controls, never the screenshot's brightness.
        alphaValue = 1
        imageView.layer?.borderWidth = 2
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(hovered ? 0.95 : 0.18).cgColor
        layer?.shadowOpacity = 0
        titleField.textColor = hovered ? .white : NSColor.white.withAlphaComponent(0.75)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            underline.animator().alphaValue = hovered ? 1 : 0
            let btnAlpha: CGFloat = hovered ? 1.0 : 0.0
            closeButton.animator().alphaValue = btnAlpha
            minimizeButton.animator().alphaValue = btnAlpha
            snapButton.animator().alphaValue = btnAlpha
            shotButton.animator().alphaValue = btnAlpha
            quitButton.animator().alphaValue = btnAlpha
            if !desktopButton.isHidden {
                desktopButton.animator().alphaValue = btnAlpha
            }
        }
    }
}
