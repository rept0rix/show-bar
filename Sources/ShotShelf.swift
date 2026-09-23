import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Screenshot shortcuts copy the picture and leave no file.
/// The preview stays in the bottom corner until its close button is pressed.
final class ShotShelf {
    static let shared = ShotShelf()

    private let lock = NSLock()
    private var selecting = false
    private var selector: ShotSelector?
    private var preview: NSPanel?
    private var previousApp: NSRunningApplication?

    private init() {}

    /// Returns true when Show Bar handled the key and the system must not also take a screenshot.
    func consume(key: Int64, command: Bool, shift: Bool, option: Bool, isRepeat: Bool) -> Bool {
        if isSelecting {
            if key == 53, !isRepeat {
                DispatchQueue.main.async { self.cancelSelection() }
            } else if key == 49, !isRepeat {
                DispatchQueue.main.async { self.selector?.useWindowUnderPointer() }
            }
            return true
        }
        guard command, shift, !option, !isRepeat, !WindowSwitcher.shared.isVisible() else { return false }
        // 3 is the whole screen. 4 is a dragged area. Control is ignored so both shortcuts copy.
        if key == 20 {
            DispatchQueue.main.async { self.captureScreen() }
            return true
        }
        if key == 21 {
            setSelecting(true)
            DispatchQueue.main.async { self.beginSelection() }
            return true
        }
        return false
    }

    func captureScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        grab(screen: screen, crop: nil)
    }

    func beginSelection() {
        guard selector == nil else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            setSelecting(false)
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = ShotSelector(screen: screen)
        panel.onCancel = { [weak self] in self?.cancelSelection() }
        panel.onCrop = { [weak self] rect in self?.finishSelection(rect, on: screen) }
        selector = panel
        setSelecting(true)
        NSRunningApplication.current.activate(from: .current, options: [])
        panel.makeKeyAndOrderFront(nil)
    }

    private func finishSelection(_ crop: CGRect, on screen: NSScreen) {
        tearDownSelector()
        grab(screen: screen, crop: crop)
        restoreFrontApp()
    }

    func cancelSelection() {
        tearDownSelector()
        restoreFrontApp()
    }

    private func tearDownSelector() {
        selector?.orderOut(nil)
        selector = nil
        setSelecting(false)
    }

    private func restoreFrontApp() {
        let previous = previousApp
        previousApp = nil
        guard let previous, previous.processIdentifier != getpid(), !previous.isTerminated else { return }
        previous.activate(from: .current, options: [])
    }

    private var isSelecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return selecting
    }

    private func setSelecting(_ value: Bool) {
        lock.lock()
        selecting = value
        lock.unlock()
    }

    private func grab(screen: NSScreen, crop: CGRect?) {
        guard let displayID = screen.displayID else { return }
        guard CGPreflightScreenCaptureAccess() else {
            PermissionsState.promptScreenRecording()
            return
        }
        let target = ShotTarget(
            displayID: displayID,
            width: screen.frame.width,
            height: screen.frame.height,
            crop: crop
        )
        Task {
            do {
                let image = try await ShotGrab.capture(target)
                DispatchQueue.main.async { self.present(image, on: screen) }
            } catch {
                DispatchQueue.main.async {
                    if !CGPreflightScreenCaptureAccess() {
                        PermissionsState.promptScreenRecording()
                    }
                }
            }
        }
    }

    private func present(_ image: CGImage, on screen: NSScreen) {
        copy(image)
        playShutter()
        preview?.orderOut(nil)

        let scale = max(screen.backingScaleFactor, 1)
        let points = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let fitted = fit(points, max: NSSize(width: 248, height: 156))
        let bar: CGFloat = 32
        let size = NSSize(width: max(fitted.width, 148), height: fitted.height + bar)
        let area = screen.visibleFrame
        let frame = NSRect(
            x: area.maxX - size.width - 14,
            y: area.minY + 14,
            width: size.width,
            height: size.height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        let imageView = ShotImageView(frame: NSRect(x: 0, y: bar, width: size.width, height: fitted.height))
        imageView.image = NSImage(cgImage: image, size: points)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        root.addSubview(imageView)

        let caption = NSTextField(labelWithString: "Copied")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .white
        caption.frame = NSRect(x: 12, y: 7, width: size.width - 52, height: 18)
        root.addSubview(caption)

        let close = NSButton(frame: NSRect(x: size.width - 30, y: 5, width: 22, height: 22))
        close.bezelStyle = .circular
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close screenshot")
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .white
        close.wantsLayer = true
        close.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        close.layer?.cornerRadius = 11
        close.target = self
        close.action = #selector(closePreview)
        root.addSubview(close)

        panel.contentView = root
        preview = panel
        panel.orderFrontRegardless()
    }

    @objc private func closePreview() {
        preview?.orderOut(nil)
        preview = nil
    }

    private func copy(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.png]
        let tiff = rep.tiffRepresentation
        if tiff != nil { types.append(.tiff) }
        board.declareTypes(types, owner: nil)
        board.setData(png, forType: .png)
        if let tiff {
            board.setData(tiff, forType: .tiff)
        }
    }

    private func playShutter() {
        let paths = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/ScreenCapture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        ]
        for path in paths {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.play()
                return
            }
        }
    }

    private func fit(_ size: NSSize, max limit: NSSize) -> NSSize {
        guard size.width > 1, size.height > 1 else { return limit }
        let scale = min(limit.width / size.width, limit.height / size.height, 1)
        return NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }
}

private struct ShotTarget: Sendable {
    let displayID: CGDirectDisplayID
    let width: CGFloat
    let height: CGFloat
    let crop: CGRect?
}

private enum ShotGrab {
    static func capture(_ target: ShotTarget) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw ShotError.noDisplay
        }
        let mine = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let crop = target.crop else { return image }
        return cropImage(image, points: crop, screen: target) ?? image
    }

    private static func cropImage(_ image: CGImage, points: CGRect, screen: ShotTarget) -> CGImage? {
        guard screen.width > 1, screen.height > 1 else { return nil }
        let scaleX = CGFloat(image.width) / screen.width
        let scaleY = CGFloat(image.height) / screen.height
        let rect = CGRect(
            x: points.origin.x * scaleX,
            y: points.origin.y * scaleY,
            width: points.width * scaleX,
            height: points.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        return image.cropping(to: rect)
    }
}

private enum ShotError: Error {
    case noDisplay
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private final class ShotSelector: NSPanel {
    var onCrop: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private let canvas: SelectionCanvas

    init(screen: NSScreen) {
        canvas = SelectionCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = canvas
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        canvas.onCrop = { [weak self] rect in self?.onCrop?(rect) }
        canvas.screen = screen
        canvas.installHint()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(canvas)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func useWindowUnderPointer() {
        canvas.armWindowMode()
    }
}

private final class SelectionCanvas: NSView {
    var onCrop: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    weak var screen: NSScreen?
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var windowMode = false
    private var hoveredWindow: CGRect?
    private let hint = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    func installHint() {
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        hint.layer?.cornerRadius = 8
        addSubview(hint)
        refreshHint()
    }

    func armWindowMode() {
        windowMode = true
        anchor = nil
        current = nil
        hoveredWindow = window(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        refreshHint()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hole = activeRect
        let shade = NSBezierPath(rect: bounds)
        if hole.width > 1, hole.height > 1 {
            shade.appendRect(hole)
            shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        shade.fill()
        if hole.width > 1, hole.height > 1 {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: hole)
            border.lineWidth = 2
            border.stroke()
        }
    }

    private func refreshHint() {
        hint.stringValue = windowMode
            ? "Click a window to copy   ·   drag to choose   ·   Esc to cancel"
            : "Drag to copy   ·   Space for a window   ·   Esc to cancel"
        hint.sizeToFit()
        let size = NSSize(width: hint.frame.width + 20, height: hint.frame.height + 10)
        hint.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - size.height - 28,
            width: size.width,
            height: size.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if windowMode, let hoveredWindow, hoveredWindow.contains(point) {
            onCrop?(hoveredWindow)
            return
        }
        windowMode = false
        hoveredWindow = nil
        anchor = point
        current = point
        refreshHint()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard windowMode else { return }
        hoveredWindow = window(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if windowMode { return }
        current = convert(event.locationInWindow, from: nil)
        let rect = draggedRect
        if rect.width < 8 || rect.height < 8 {
            onCancel?()
        } else {
            onCrop?(rect)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    private var activeRect: CGRect {
        if windowMode, let hoveredWindow { return hoveredWindow }
        return draggedRect
    }

    private var draggedRect: CGRect {
        guard let anchor, let current else { return .zero }
        return CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(anchor.x - current.x),
            height: abs(anchor.y - current.y)
        )
    }

    private func window(at mouse: CGPoint) -> CGRect? {
        guard let screen, let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let top = Coordinates.primaryHeight - screen.frame.maxY
        for dict in info {
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let pid = pid_t((dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            guard pid > 0, pid != getpid() else { continue }
            guard let frame = Self.quartzRect(dict[kCGWindowBounds as String]) else { continue }
            guard frame.width >= 80, frame.height >= 52 else { continue }
            let local = CGRect(
                x: frame.origin.x - screen.frame.origin.x,
                y: frame.origin.y - top,
                width: frame.width,
                height: frame.height
            )
            if local.contains(mouse) { return local }
        }
        return nil
    }

    private static func quartzRect(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? {
            if let number = dict[key] as? NSNumber { return CGFloat(number.doubleValue) }
            if let number = dict[key] as? Double { return CGFloat(number) }
            return nil
        }
        guard let x = number("X"), let y = number("Y"), let width = number("Width"), let height = number("Height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private final class ShotImageView: NSImageView, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func mouseDragged(with event: NSEvent) {
        guard let image else { return }
        let item = NSDraggingItem(pasteboardWriter: image)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
}
