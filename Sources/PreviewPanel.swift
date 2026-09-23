import AppKit
import QuartzCore

enum PreviewMetrics {
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 8
    static let titleGap: CGFloat = 6
    static let titleHeight: CGFloat = 16
    static let maxCount = 6

    static func thumb(count: Int, screenWidth: CGFloat) -> CGSize {
        let count = max(count, 1)
        let maxPanel = min(max(screenWidth - 32, 340), 1080)
        let ideal: CGFloat = count == 1 ? 286 : (count == 2 ? 228 : 188)
        let chrome = inset * 2 + spacing * CGFloat(count - 1)
        let fitted = (maxPanel - chrome) / CGFloat(count)
        let width = min(ideal, max(124, fitted)).rounded(.down)
        let height = (width * 0.62).rounded(.down)
        return CGSize(width: width, height: height)
    }

    static func panelSize(count: Int, thumb: CGSize, showsFooter: Bool) -> CGSize {
        let count = CGFloat(max(count, 1))
        let width = inset * 2 + thumb.width * count + spacing * (count - 1)
        let footer: CGFloat = showsFooter ? 22 : 0
        let height = inset + thumb.height + titleGap + titleHeight + footer + inset
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

final class PreviewPanel {
    var onSelect: ((WindowCard) -> Void)?
    var onClose: ((WindowCard) -> Void)?

    private(set) var isShown = false
    private(set) var anchor = CGRect.zero
    private var edge: DockEdge = .bottom
    private var cards: [WindowCard] = []
    private var appIcon: NSImage?
    private var hideToken = UUID()
    private let panel: PreviewWindow
    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = NSAppearance(named: .darkAqua)

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        panel.contentView = effect

        stack.orientation = .horizontal
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

    func present(cards: [WindowCard], anchor: CGRect, edge: DockEdge, appIcon: NSImage) {
        hideToken = UUID()
        self.anchor = anchor
        self.edge = edge
        self.appIcon = appIcon
        self.cards = cards
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
    }

    func updateAnchor(_ anchor: CGRect, edge: DockEdge) {
        guard isShown else { return }
        guard !nearlyEqual(anchor, self.anchor) || edge != self.edge else { return }
        self.anchor = anchor
        self.edge = edge
        place()
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
        isShown = false
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
        let thumb = PreviewMetrics.thumb(count: cards.count, screenWidth: screenWidth)
        for card in cards {
            let view = PreviewCardView(card: card, icon: appIcon, thumb: thumb)
            view.onSelect = { [weak self] in self?.onSelect?(card) }
            view.onClose = { [weak self] in self?.onClose?(card) }
            stack.addArrangedSubview(view)
            cardViews[card.id] = view
        }
    }

    private func place() {
        let screen = Coordinates.screen(containing: Coordinates.flip(anchor)) ?? NSScreen.main
        let thumb = PreviewMetrics.thumb(count: cards.count, screenWidth: screen?.visibleFrame.width ?? 1200)
        let showsFooter = !CGPreflightScreenCaptureAccess()
        let size = PreviewMetrics.panelSize(count: cards.count, thumb: thumb, showsFooter: showsFooter)
        let icon = Coordinates.flip(anchor)
        var origin: CGPoint
        switch edge {
        case .left:
            origin = CGPoint(x: icon.maxX + 16, y: icon.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: icon.minX - size.width - 16, y: icon.midY - size.height / 2)
        case .bottom:
            origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + 16)
        case .top:
            origin = CGPoint(x: icon.midX - size.width / 2, y: icon.minY - size.height - 16)
        }
        var clamped = origin
        if let screen {
            let visible = screen.visibleFrame
            clamped.x = min(max(origin.x, visible.minX + 6), max(visible.minX + 6, visible.maxX - size.width - 6))
            clamped.y = min(max(origin.y, visible.minY + 6), max(visible.minY + 6, visible.maxY - size.height - 6))
            clamped = clearCorners(CGRect(origin: clamped, size: size), screen: screen).origin
        }
        let next = CGRect(origin: clamped, size: size)
        if panel.frame.integral != next.integral {
            panel.setFrame(next, display: true)
            panel.invalidateShadow()
        }
    }

    private func clearCorners(_ rect: CGRect, screen: NSScreen) -> CGRect {
        var rect = rect
        let margin: CGFloat = 36
        let frame = screen.frame
        let corners = [
            CGRect(x: frame.minX, y: frame.maxY - margin, width: margin, height: margin),
            CGRect(x: frame.maxX - margin, y: frame.maxY - margin, width: margin, height: margin),
            CGRect(x: frame.minX, y: frame.minY, width: margin, height: margin),
            CGRect(x: frame.maxX - margin, y: frame.minY, width: margin, height: margin),
        ]
        for corner in corners where rect.intersects(corner) {
            switch edge {
            case .left, .right:
                if corner.midY > frame.midY {
                    rect.origin.y = min(rect.origin.y, corner.minY - rect.height - 6)
                } else {
                    rect.origin.y = max(rect.origin.y, corner.maxY + 6)
                }
            case .bottom, .top:
                if corner.midX < frame.midX {
                    rect.origin.x = max(rect.origin.x, corner.maxX + 6)
                } else {
                    rect.origin.x = min(rect.origin.x, corner.minX - rect.width - 6)
                }
            }
        }
        let visible = screen.visibleFrame
        rect.origin.x = min(max(rect.origin.x, visible.minX + 6), max(visible.minX + 6, visible.maxX - rect.width - 6))
        rect.origin.y = min(max(rect.origin.y, visible.minY + 6), max(visible.minY + 6, visible.maxY - rect.height - 6))
        return rect
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

final class PreviewCardView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let imageView = NSImageView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init(card: WindowCard, icon: NSImage?, thumb: CGSize) {
        super.init(frame: NSRect(x: 0, y: 0, width: thumb.width, height: thumb.height + PreviewMetrics.titleGap + PreviewMetrics.titleHeight))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
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
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.textColor = .labelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleField)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "סגור")?
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
        closeButton.alphaValue = 0
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: thumb.width),
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
            titleField.heightAnchor.constraint(equalToConstant: PreviewMetrics.titleHeight),
            closeButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        titleField.stringValue = title
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
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return }
        let closeLocal = closeButton.convert(local, from: self)
        if closeButton.alphaValue > 0.5 && closeButton.bounds.contains(closeLocal) {
            onClose?()
            return
        }
        onSelect?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let closeLocal = closeButton.convert(local, from: self)
        if closeButton.alphaValue > 0.5 && closeButton.bounds.contains(closeLocal) {
            return closeButton
        }
        return self
    }

    @objc private func closePressed() {
        onClose?()
    }

    private func setHovered(_ hovered: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            closeButton.animator().alphaValue = hovered ? 1 : 0
        }
        imageView.layer?.borderColor = (hovered ? NSColor.white.withAlphaComponent(0.72) : NSColor.white.withAlphaComponent(0.16)).cgColor
    }
}
