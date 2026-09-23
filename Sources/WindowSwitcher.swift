import AppKit
import CoreGraphics

/// Command-Tab shows the windows themselves, then releases Command to switch.
final class WindowSwitcher {
    static let shared = WindowSwitcher()
    var onWillShow: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let grid = SwitcherGrid()
    private let hint = NSTextField(labelWithString: "Arrows to move  ·  release ⌘ to switch")
    private var gridWidth = NSLayoutConstraint()
    private var gridHeight = NSLayoutConstraint()
    private var cards: [WindowCard] = []
    private var recentPIDs: [pid_t] = []
    private var activationObserver: NSObjectProtocol?
    private var thumbs: [NSImageView] = []
    private var titleFields: [NSTextField] = []
    private var bars: [NSView] = []
    private var index = 0
    private var columns = 1
    private var captureTask: Task<Void, Never>?
    private let lock = NSLock()
    private var visible = false

    private init() {
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
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

        grid.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(grid)

        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.55)
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hint)

        gridWidth = grid.widthAnchor.constraint(equalToConstant: 200)
        gridHeight = grid.heightAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            grid.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            gridWidth,
            gridHeight,
            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
        ])
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.remember(app.processIdentifier)
        }
    }

    /// Most recently used app first. Within an app, windows stay front to back.
    private func remember(_ pid: pid_t) {
        guard pid > 0, pid != getpid() else { return }
        recentPIDs.removeAll { $0 == pid }
        recentPIDs.insert(pid, at: 0)
    }

    private func orderedByRecency(_ cards: [WindowCard]) -> [WindowCard] {
        if let front = cards.first?.pid {
            remember(front)
        }
        for card in cards where !recentPIDs.contains(card.pid) {
            recentPIDs.append(card.pid)
        }
        var rank: [pid_t: Int] = [:]
        for (offset, pid) in recentPIDs.enumerated() where rank[pid] == nil {
            rank[pid] = offset
        }
        return cards.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.pid] ?? Int.max
            let right = rank[rhs.element.pid] ?? Int.max
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: switcherKeyCallback,
            userInfo: nil
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        hide()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func isVisible() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return visible
    }

    func cycle(backward: Bool) {
        if !isVisible() {
            show(backward: backward)
            return
        }
        guard !cards.isEmpty else { return }
        index = backward
            ? (index - 1 + cards.count) % cards.count
            : (index + 1) % cards.count
        applySelection()
    }

    fileprivate func move(_ direction: ArrowDirection) {
        guard isVisible(), !cards.isEmpty else { return }
        let span = max(columns, 1)
        switch direction {
        case .left:
            index = (index - 1 + cards.count) % cards.count
        case .right:
            index = (index + 1) % cards.count
        case .up:
            if index >= span {
                index -= span
            } else if span >= cards.count {
                index = (index - 1 + cards.count) % cards.count
            }
        case .down:
            if index + span < cards.count {
                index += span
            } else if span >= cards.count {
                index = (index + 1) % cards.count
            }
        }
        applySelection()
    }

    func commit() {
        guard isVisible(), cards.indices.contains(index) else {
            hide()
            return
        }
        let card = cards[index]
        hide()
        WindowCatalog.endReveal(committing: card)
        WindowCatalog.focus(card)
    }

    func cancel() {
        hide()
    }

    private func show(backward: Bool) {
        let next = orderedByRecency(WindowCatalog.switcherCards())
        guard !next.isEmpty else { return }
        onWillShow?()
        cards = next
        index = next.count == 1 ? 0 : (backward ? next.count - 1 : 1)
        rebuild()
        place()
        lock.lock()
        visible = true
        lock.unlock()
        panel.orderFrontRegardless()
        captureTask?.cancel()
        let shown = cards
        captureTask = Task { [weak self] in
            let refresh = await WindowCatalog.refresh(shown)
            if Task.isCancelled { return }
            await MainActor.run { self?.apply(refresh.thumbnails, titles: refresh.cards) }
        }
    }

    private func hide() {
        captureTask?.cancel()
        captureTask = nil
        lock.lock()
        visible = false
        lock.unlock()
        panel.orderOut(nil)
    }

    private func rebuild() {
        for view in grid.subviews {
            view.removeFromSuperview()
        }
        thumbs = []
        titleFields = []
        bars = []
        let screen = activeScreen()
        let metrics = gridMetrics(count: max(cards.count, 1), screen: screen)
        columns = metrics.columns
        let thumbW = metrics.thumbW
        let thumbH = metrics.thumbH
        let gap = metrics.gap
        let cardH = thumbH + metrics.label
        for (offset, card) in cards.enumerated() {
            let column = offset % columns
            let row = offset / columns
            let app = NSRunningApplication(processIdentifier: card.pid)
            let appName = app?.localizedName ?? card.title
            let cardView = SwitcherCard()
            cardView.translatesAutoresizingMaskIntoConstraints = false
            cardView.onClick = { [weak self] in
                self?.index = offset
                self?.commit()
            }

            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.imageAlignment = .alignCenter
            let placeholder = (app?.icon ?? NSWorkspace.shared.icon(for: .application))
            placeholder.size = NSSize(width: 72, height: 72)
            image.image = placeholder
            image.wantsLayer = true
            image.layer?.cornerRadius = 8
            image.layer?.masksToBounds = true
            image.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            image.translatesAutoresizingMaskIntoConstraints = false

            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.image = app?.icon ?? NSWorkspace.shared.icon(for: .application)
            icon.translatesAutoresizingMaskIntoConstraints = false

            let name = NSTextField(labelWithString: appName)
            name.font = .systemFont(ofSize: 12, weight: .semibold)
            name.textColor = .white
            name.lineBreakMode = .byTruncatingTail
            name.maximumNumberOfLines = 1
            name.translatesAutoresizingMaskIntoConstraints = false
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let title = NSTextField(labelWithString: card.title)
            title.font = .systemFont(ofSize: 11, weight: .regular)
            title.textColor = NSColor.white.withAlphaComponent(0.62)
            title.alignment = .center
            title.lineBreakMode = .byTruncatingTail
            title.maximumNumberOfLines = 1
            title.translatesAutoresizingMaskIntoConstraints = false
            if card.title.caseInsensitiveCompare(appName) == .orderedSame {
                title.stringValue = " "
                title.alphaValue = 0
            }

            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.white.cgColor
            bar.layer?.cornerRadius = 1
            bar.translatesAutoresizingMaskIntoConstraints = false

            cardView.addSubview(image)
            cardView.addSubview(icon)
            cardView.addSubview(name)
            cardView.addSubview(title)
            cardView.addSubview(bar)
            grid.addSubview(cardView)
            NSLayoutConstraint.activate([
                cardView.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: CGFloat(column) * (thumbW + gap)),
                cardView.topAnchor.constraint(equalTo: grid.topAnchor, constant: CGFloat(row) * (cardH + gap)),
                cardView.widthAnchor.constraint(equalToConstant: thumbW),
                cardView.heightAnchor.constraint(equalToConstant: cardH),
                image.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
                image.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
                image.topAnchor.constraint(equalTo: cardView.topAnchor),
                image.heightAnchor.constraint(equalToConstant: thumbH),
                icon.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 2),
                icon.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 8),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                name.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
                name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
                title.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
                title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
                title.heightAnchor.constraint(equalToConstant: 14),
                bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
                bar.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
                bar.widthAnchor.constraint(equalToConstant: max(8, min(thumbW - 16, 72))),
                bar.heightAnchor.constraint(equalToConstant: 2),
                bar.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            ])
            thumbs.append(image)
            titleFields.append(title)
            bars.append(bar)
        }
        applySelection()
        gridWidth.constant = metrics.grid.width
        gridHeight.constant = metrics.grid.height
        panelSize = metrics.panel
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Every card is sized from the visible screen, so the panel cannot extend past it.
    private func gridMetrics(count: Int, screen: NSScreen) -> (columns: Int, thumbW: CGFloat, thumbH: CGFloat, gap: CGFloat, label: CGFloat, grid: CGSize, panel: CGSize) {
        let bounds = screen.visibleFrame.insetBy(dx: 18, dy: 18)
        let count = max(count, 1)
        let gap: CGFloat = 8
        let padX: CGFloat = 28
        let label: CGFloat = 45
        let chromeY: CGFloat = 48
        let innerW = bounds.width - padX
        let innerH = bounds.height - chromeY
        guard innerW > 40, innerH > 40 else {
            return (1, 80, 48, gap, label, CGSize(width: 80, height: 93), CGSize(width: 108, height: 141))
        }
        var best: (columns: Int, thumbW: CGFloat, thumbH: CGFloat, grid: CGSize, panel: CGSize, score: CGFloat)?
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let maxThumbW = floor((innerW - gap * CGFloat(cols - 1)) / CGFloat(cols))
            let maxCardH = floor((innerH - gap * CGFloat(max(rows - 1, 0))) / CGFloat(rows))
            let maxThumbH = maxCardH - label
            guard maxThumbW >= 28, maxThumbH >= 20 else { continue }
            let thumbH = min(floor(min(maxThumbW, 200) * 0.62), maxThumbH)
            let thumbW = min(maxThumbW, min(200, floor(thumbH / 0.62)))
            guard thumbW >= 28, thumbH >= 20 else { continue }
            let grid = CGSize(
                width: thumbW * CGFloat(cols) + gap * CGFloat(cols - 1),
                height: (thumbH + label) * CGFloat(rows) + gap * CGFloat(max(rows - 1, 0))
            )
            let panel = CGSize(width: grid.width + padX, height: grid.height + chromeY)
            guard panel.width <= bounds.width + 0.5, panel.height <= bounds.height + 0.5 else { continue }
            let score = thumbW * thumbH
            if best == nil || score > best!.score {
                best = (cols, thumbW, thumbH, grid, panel, score)
            }
        }
        if let best {
            return (best.columns, best.thumbW, best.thumbH, gap, label, best.grid, best.panel)
        }
        let cols = max(1, min(count, Int(innerW / 36)))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let thumbW = max(24, floor((innerW - gap * CGFloat(cols - 1)) / CGFloat(cols)))
        let thumbH = max(16, floor((innerH - gap * CGFloat(max(rows - 1, 0))) / CGFloat(rows)) - label)
        let grid = CGSize(
            width: min(innerW, thumbW * CGFloat(cols) + gap * CGFloat(max(cols - 1, 0))),
            height: min(innerH, (thumbH + label) * CGFloat(rows) + gap * CGFloat(max(rows - 1, 0)))
        )
        return (cols, thumbW, thumbH, gap, label, grid, CGSize(width: grid.width + padX, height: min(bounds.height, grid.height + chromeY)))
    }

    private var panelSize = CGSize(width: 480, height: 220)

    private func place() {
        let screen = activeScreen().visibleFrame
        let size = CGSize(
            width: min(panelSize.width, screen.width - 8),
            height: min(panelSize.height, screen.height - 8)
        )
        var origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        origin.x = min(max(origin.x, screen.minX + 4), max(screen.minX + 4, screen.maxX - size.width - 4))
        origin.y = min(max(origin.y, screen.minY + 4), max(screen.minY + 4, screen.maxY - size.height - 4))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func applySelection() {
        for (offset, image) in thumbs.enumerated() {
            let selected = offset == index
            image.layer?.borderWidth = selected ? 2 : 1
            image.layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.92 : 0.18).cgColor
            bars[offset].alphaValue = selected ? 1 : 0
        }
    }

    private func apply(_ thumbnails: [Thumbnail], titles: [WindowCard]) {
        guard isVisible() else { return }
        for card in titles {
            guard let offset = cards.firstIndex(where: { $0.id == card.id }), titleFields.indices.contains(offset) else { continue }
            let appName = NSRunningApplication(processIdentifier: card.pid)?.localizedName ?? ""
            if card.title.caseInsensitiveCompare(appName) == .orderedSame {
                titleFields[offset].stringValue = " "
                titleFields[offset].alphaValue = 0
            } else {
                titleFields[offset].stringValue = card.title
                titleFields[offset].alphaValue = 1
            }
        }
        for thumbnail in thumbnails {
            guard let offset = cards.firstIndex(where: { $0.id == thumbnail.windowID }) else { continue }
            thumbs[offset].image = NSImage(
                cgImage: thumbnail.image,
                size: NSSize(width: thumbnail.image.width, height: thumbnail.image.height)
            )
        }
    }
}

private final class SwitcherGrid: NSView {
    override var isFlipped: Bool { true }
}

private final class SwitcherCard: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private enum ArrowDirection {
    case left, right, up, down
}

private func switcherKeyCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        WindowSwitcher.shared.enable()
        return Unmanaged.passUnretained(event)
    }
    let command = event.flags.contains(.maskCommand)
    if type == .flagsChanged {
        if WindowSwitcher.shared.isVisible(), !command {
            DispatchQueue.main.async { WindowSwitcher.shared.commit() }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let control = event.flags.contains(.maskControl)
    let option = event.flags.contains(.maskAlternate)
    let shift = event.flags.contains(.maskShift)
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if ShotShelf.shared.consume(key: key, command: command, shift: shift, option: option, isRepeat: isRepeat) {
        return nil
    }
    if control, option, !command, !shift, key == 9, !isRepeat, !WindowSwitcher.shared.isVisible() {
        DispatchQueue.main.async { ClipboardShelf.shared.show() }
        return nil
    }
    if control, option, !command, !WindowSwitcher.shared.isVisible(), let zone = SnapZone.from(keycode: key) {
        DispatchQueue.main.async { WindowSnap.apply(zone) }
        return nil
    }
    let extra = event.flags.contains(.maskControl) || event.flags.contains(.maskAlternate)
    if WindowSwitcher.shared.isVisible() {
        let direction: ArrowDirection?
        switch key {
        case 123: direction = .left
        case 124: direction = .right
        case 126: direction = .up
        case 125: direction = .down
        default: direction = nil
        }
        if let direction {
            DispatchQueue.main.async { WindowSwitcher.shared.move(direction) }
            return nil
        }
    }
    if key == 48, command, !extra {
        let backward = event.flags.contains(.maskShift)
        DispatchQueue.main.async { WindowSwitcher.shared.cycle(backward: backward) }
        return nil
    }
    if key == 53, WindowSwitcher.shared.isVisible() {
        DispatchQueue.main.async { WindowSwitcher.shared.cancel() }
        return nil
    }
    return Unmanaged.passUnretained(event)
}
