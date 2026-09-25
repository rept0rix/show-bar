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
        if snap.insetBy(dx: -4, dy: -4).contains(point) { return .snap }
        if shot.insetBy(dx: -4, dy: -4).contains(point) { return .shot }
        if close.insetBy(dx: -4, dy: -4).contains(point) { return .close }
        if minimize.insetBy(dx: -4, dy: -4).contains(point) { return .minimize }
        if quit.insetBy(dx: -6, dy: -6).contains(point) { return .quit }
        if desktop.insetBy(dx: -6, dy: -6).contains(point) { return .desktop }
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
    private var hideToken = UUID()
    private let panel: PreviewWindow
    private let effect = PreviewBackdrop()
    private var pointerTimer: Timer?
    private var peekToken = UUID()
    private var peekCardID: CGWindowID?
    private var peekLeave: DispatchWorkItem?
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
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
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
        return frameAX.insetBy(dx: -10, dy: -10).contains(point)
    }

    /// AppKit mouse location against the panel frame. This stays valid while the pointer is over our own window.
    func pointerInside() -> Bool {
        if menuHold && isShown { return true }
        guard isShown, panel.isVisible, panel.alphaValue > 0.2 else { return false }
        return panel.frame.insetBy(dx: -18, dy: -18).contains(NSEvent.mouseLocation)
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
        let hoveredID = cardViews.first { $0.value === hovered }?.key
        if hoveredID == peekCardID {
            peekLeave?.cancel()
            peekLeave = nil
        } else if hoveredID == nil {
            if peekLeave == nil, peekCardID != nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.peekLeave = nil
                    self?.schedulePeek(nil)
                }
                peekLeave = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        } else {
            peekLeave?.cancel()
            peekLeave = nil
            schedulePeek(hoveredID)
        }
        ClickCatcher.shared.refresh(self)
    }

    private func schedulePeek(_ id: CGWindowID?) {
        peekToken = UUID()
        let token = peekToken
        if peekCardID != nil {
            WindowCatalog.endReveal(committing: nil)
        }
        peekCardID = id
        guard let id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.peekToken == token, self.isShown, self.peekCardID == id,
                  let card = self.cards.first(where: { $0.id == id }) else { return }
            WindowCatalog.reveal(card)
        }
    }

    private func cancelPeek() {
        peekToken = UUID()
        peekCardID = nil
        WindowCatalog.endReveal(committing: nil)
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
        hideToken = UUID()
        self.anchor = anchor
        self.edge = edge
        self.appIcon = appIcon
        self.cards = cards
        lockedCenter = nil
        cancelPeek()
        rebuild(cards)
        place()
        let appearing = !panel.isVisible || panel.alphaValue < 0.2
        isShown = true
        footer.isHidden = CGPreflightScreenCaptureAccess()
        if appearing {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        startPointerTimer()
        markCardUnderMouse()
    }

    func updateAnchor(_ anchor: CGRect, edge: DockEdge) {
        // The Dock icon frame keeps shifting while magnification animates.
        // Following it makes the preview bounce. The position is chosen once in present().
        _ = anchor
        _ = edge
    }

    func sync(cards: [WindowCard]) {
        guard isShown else { return }
        footer.isHidden = CGPreflightScreenCaptureAccess()
        let idsChanged = cards.map(\.id) != self.cards.map(\.id)
        self.cards = cards
        if idsChanged {
            rebuild(cards)
        } else {
            for card in cards {
                cardViews[card.id]?.setTitle(card.title)
                cardViews[card.id]?.setDesktop(DesktopSpaces.desk(for: card.id)?.title ?? "Desktop")
            }
        }
        place()
    }

    func apply(_ thumbnails: [Thumbnail]) {
        for thumbnail in thumbnails {
            let image = NSImage(cgImage: thumbnail.image, size: NSSize(width: thumbnail.image.width, height: thumbnail.image.height))
            cardViews[thumbnail.windowID]?.setScreenshot(image)
        }
    }

    func hide() {
        guard isShown || panel.isVisible else { return }
        cancelPeek()
        isShown = false
        lockedCenter = nil
        stopPointerTimer()
        let token = UUID()
        hideToken = token
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    private func rebuild(_ cards: [WindowCard]) {
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
            let view = PreviewCardView(card: card, icon: appIcon, thumb: grid.thumb)
            view.onSelect = { [weak self] in self?.onSelect?(card) }
            view.onClose = { [weak self] in self?.onClose?(card) }
            view.onMinimize = { [weak self] in self?.onMinimize?(card) }
            view.onQuit = { [weak self] in self?.onQuit?(card) }
            view.onMove = { [weak self] space in self?.onMove?(card, space) }
            view.onSnap = { [weak self] in self?.onSnap?(card) }
            view.onShot = { [weak self] in self?.onShot?(card) }
            view.onHold = { [weak self] hold in self?.holdOpen(hold) }
            row?.addArrangedSubview(view)
            cardViews[card.id] = view
        }
    }

    private var lockedCenter: CGPoint?

    private func place() {
        let screen = Coordinates.screen(containing: Coordinates.flip(anchor)) ?? NSScreen.main
        let showsFooter = !CGPreflightScreenCaptureAccess()
        let size = PreviewMetrics.grid(
            count: cards.count,
            screenWidth: screen?.visibleFrame.width ?? 1200,
            showsFooter: showsFooter
        ).panel
        let icon = Coordinates.flip(anchor)
        if lockedCenter != nil, panel.frame.size.equalTo(size) {
            return
        }
        let pointer = lockedCenter ?? NSEvent.mouseLocation
        var origin: CGPoint
        switch edge {
        case .left:
            origin = CGPoint(x: icon.maxX + 8, y: pointer.y - size.height / 2)
        case .right:
            origin = CGPoint(x: icon.minX - size.width - 8, y: pointer.y - size.height / 2)
        case .bottom:
            origin = CGPoint(x: pointer.x - size.width / 2, y: icon.maxY + 8)
        case .top:
            origin = CGPoint(x: pointer.x - size.width / 2, y: icon.minY - size.height - 8)
        }
        if let screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 6), max(visible.minX + 6, visible.maxX - size.width - 6))
            origin.y = min(max(origin.y, visible.minY + 6), max(visible.minY + 6, visible.maxY - size.height - 6))
        }
        let next = CGRect(origin: origin, size: size)
        if lockedCenter == nil {
            lockedCenter = CGPoint(x: next.midX, y: next.midY)
        }
        if panel.frame.integral != next.integral {
            panel.setFrame(next, display: true)
            panel.invalidateShadow()
        }
    }

    /// The strip from the Dock icon across to the preview. Moving through it should not retarget another icon.
    func approachContains(_ quartz: CGPoint) -> Bool {
        guard isShown, let screen = panel.screen ?? NSScreen.main else { return false }
        let point = NSPoint(x: quartz.x, y: Coordinates.primaryHeight - quartz.y)
        var band = panel.frame
        if let lockedCenter {
            band = band.union(CGRect(x: panel.frame.minX, y: lockedCenter.y - 24, width: panel.frame.width, height: 48))
        }
        band = band.insetBy(dx: 0, dy: -8)
        switch edge {
        case .left:
            band.origin.x = screen.frame.minX
            band.size.width = panel.frame.maxX - screen.frame.minX
        case .right:
            band.origin.x = panel.frame.minX
            band.size.width = screen.frame.maxX - panel.frame.minX
        case .bottom:
            band.origin.y = screen.frame.minY
            band.size.height = panel.frame.maxY - screen.frame.minY
        case .top:
            band.origin.y = panel.frame.minY
            band.size.height = screen.frame.maxY - panel.frame.minY
        }
        return band.contains(point)
    }

    private func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
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
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(iconView)

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
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        closeButton.layer?.cornerRadius = 9
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 1
        addSubview(closeButton)

        minimizeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Minimize")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        minimizeButton.isBordered = false
        minimizeButton.bezelStyle = .circular
        minimizeButton.contentTintColor = .white
        minimizeButton.wantsLayer = true
        minimizeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        minimizeButton.layer?.cornerRadius = 9
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizePressed)
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false
        minimizeButton.alphaValue = 1
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
        imageView.addSubview(quitButton)

        desktopButton.title = DesktopSpaces.desk(for: card.id)?.title ?? "Desktop"
        desktopButton.font = .systemFont(ofSize: 10, weight: .semibold)
        desktopButton.isBordered = false
        desktopButton.contentTintColor = .white
        desktopButton.wantsLayer = true
        desktopButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        desktopButton.layer?.cornerRadius = 7
        desktopButton.target = self
        desktopButton.action = #selector(desktopPressed)
        desktopButton.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(desktopButton)

        snapButton.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Snap left or right")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        snapButton.isBordered = false
        snapButton.bezelStyle = .circular
        snapButton.contentTintColor = .white
        snapButton.wantsLayer = true
        snapButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        snapButton.layer?.cornerRadius = 13
        snapButton.target = self
        snapButton.action = #selector(snapPressed)
        snapButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(snapButton)

        shotButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Copy this window")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        shotButton.isBordered = false
        shotButton.bezelStyle = .circular
        shotButton.contentTintColor = .white
        shotButton.wantsLayer = true
        shotButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        shotButton.layer?.cornerRadius = 13
        shotButton.target = self
        shotButton.action = #selector(shotPressed)
        shotButton.translatesAutoresizingMaskIntoConstraints = false
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
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            minimizeButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            minimizeButton.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),
            minimizeButton.widthAnchor.constraint(equalToConstant: 18),
            minimizeButton.heightAnchor.constraint(equalToConstant: 18),
            snapButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            snapButton.leadingAnchor.constraint(equalTo: minimizeButton.trailingAnchor, constant: 8),
            snapButton.widthAnchor.constraint(equalToConstant: 26),
            snapButton.heightAnchor.constraint(equalToConstant: 26),
            shotButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            shotButton.leadingAnchor.constraint(equalTo: snapButton.trailingAnchor, constant: 8),
            shotButton.widthAnchor.constraint(equalToConstant: 26),
            shotButton.heightAnchor.constraint(equalToConstant: 26),
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
        applyHover(true, dimmed: false)
    }

    override func mouseExited(with event: NSEvent) {
        applyHover(false, dimmed: false)
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
            close: frameOf(closeButton),
            minimize: frameOf(minimizeButton),
            quit: frameOf(quitButton),
            desktop: frameOf(desktopButton),
            snap: frameOf(snapButton),
            shot: frameOf(shotButton)
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
        guard frameOf(self).contains(point) else { return false }
        return runAction {
            if frameOf(self.snapButton).insetBy(dx: -4, dy: -4).contains(point) { self.onSnap?() }
            else if frameOf(self.shotButton).insetBy(dx: -4, dy: -4).contains(point) { self.onShot?() }
            else if frameOf(self.closeButton).insetBy(dx: -4, dy: -4).contains(point) { self.onClose?() }
            else if frameOf(self.minimizeButton).insetBy(dx: -4, dy: -4).contains(point) { self.onMinimize?() }
            else if frameOf(self.quitButton).insetBy(dx: -6, dy: -6).contains(point) { self.onQuit?() }
            else if frameOf(self.desktopButton).insetBy(dx: -6, dy: -6).contains(point) { self.desktopPressed() }
            else { self.onSelect?() }
        }
    }

    private func runAction(_ body: () -> Void) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastAction < 0.25 { return true }
        lastAction = now
        body()
        return true
    }

    private func hits(_ button: NSView, local: NSPoint, pad: CGFloat) -> Bool {
        button.bounds.insetBy(dx: -pad, dy: -pad).contains(button.convert(local, from: self))
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
        alphaValue = dimmed ? 0.82 : 1
        imageView.layer?.borderWidth = hovered ? 2 : 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(hovered ? 0.92 : 0.18).cgColor
        layer?.shadowOpacity = 0
        titleField.textColor = hovered ? .white : NSColor.white.withAlphaComponent(0.72)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        underline.alphaValue = hovered ? 1 : 0
    }
}
