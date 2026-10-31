import AppKit
import CoreGraphics
import ImageIO
import QuartzCore
import ScreenCaptureKit

/// What happens after a screenshot is taken.
enum ShotAfter: String, CaseIterable {
    /// The shelf stays open. Copy is a button, including Copy all.
    case keep
    /// Copy this picture and close the shelf. Nothing is written to disk.
    case copyClose
    /// Save to the Desktop and close the shelf.
    case saveClose
    /// Save to the Desktop and leave the shelf open.
    case saveKeep

    var title: String {
        switch self {
        case .keep: return "Keep open"
        case .copyClose: return "Copy and close"
        case .saveClose: return "Save and close"
        case .saveKeep: return "Save and keep open"
        }
    }

    var detail: String {
        switch self {
        case .keep: return "Shots collect in the corner. Copy one, or copy all of them together."
        case .copyClose: return "The picture is copied and the shelf closes. It is not saved."
        case .saveClose: return "The picture is saved to the Desktop and the shelf closes."
        case .saveKeep: return "Each picture is saved to the Desktop. The shelf stays open."
        }
    }
}

enum ShotPreferences {
    private static let key = "ShowBar.shotAfter"

    static var after: ShotAfter {
        get { ShotAfter(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .keep }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

private enum ShotShelfStyle {
    static let panelRadius: CGFloat = 20
    static let imageRadius: CGFloat = 12
    static let controlSize: CGFloat = 24
    static let gap: CGFloat = 8
    static let chromeHeight: CGFloat = 40
    static let showDuration: TimeInterval = 0.24
    static let hideDuration: TimeInterval = 0.17
    static let travel: CGFloat = 9
}

/// Screenshot shortcuts collect pictures in the corner shelf.
/// Save writes a picture to the Desktop.
final class ShotShelf {
    static let shared = ShotShelf()

    private let lock = NSLock()
    private var selecting = false
    private var selector: ShotSelector?
    private var preview: NSPanel?
    private var caption: NSTextField?
    private var shots: [CGImage] = []
    private var companionIDs: [ObjectIdentifier: (id: String, date: Date)] = [:]
    /// resource: memory 8 — full-screen images stay in RAM only until the shelf closes.
    private let shotLimit = 8
    private var saved: Set<ObjectIdentifier> = []
    private var shelfScreen: NSScreen?
    private var fileForShot: [ObjectIdentifier: URL] = [:]
    private var previousApp: NSRunningApplication?
    private var shutterSound: NSSound?
    private var markup: ShotMarkup?

    private init() {}

    /// Export only the live shelf, with bounded thumbnails and opaque IDs.
    /// Removing a picture also revokes future companion access to it.
    func companionShots() -> [BridgeShot] {
        let live = Set(shots.map(ObjectIdentifier.init))
        companionIDs = companionIDs.filter { live.contains($0.key) }
        return shots.reversed().map { image in
            let key = ObjectIdentifier(image)
            if companionIDs[key] == nil { companionIDs[key] = (UUID().uuidString, Date()) }
            let entry = companionIDs[key]!
            return BridgeShot(id: entry.id, date: entry.date,
                              thumbnail: Self.companionJPEG(image, longestEdge: 360, quality: 0.65))
        }
    }

    func companionImage(id: String) -> Data? {
        guard let pair = companionIDs.first(where: { $0.value.id == id }),
              let image = shots.first(where: { ObjectIdentifier($0) == pair.key }),
              let data = Self.companionJPEG(image, longestEdge: 2400, quality: 0.85),
              data.count <= 3 * 1024 * 1024 else { return nil }
        return data
    }

    static func companionJPEG(_ image: CGImage, longestEdge: Int, quality: Double) -> Data? {
        let scale = min(1, Double(longestEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: scaled)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Returns true when Show Bar handled the key and the system must not also take a screenshot.
    func consume(key: Int64, command: Bool, shift: Bool, option: Bool, isRepeat: Bool, keyDown: Bool) -> Bool {
        if isSelecting {
            if keyDown, !isRepeat {
                if key == 53 {
                    DispatchQueue.main.async { self.cancelSelection() }
                } else if key == 49 {
                    DispatchQueue.main.async { self.selector?.useWindowUnderPointer() }
                } else if key == 36 {
                    DispatchQueue.main.async { self.selector?.captureWholeScreen() }
                }
            }
            return true
        }
        guard command, shift, !option else { return false }
        // 3 is the whole screen. 4 is a dragged area. Control is ignored so both shortcuts copy.
        guard key == 20 || key == 21 else { return false }
        // The release and a held key must disappear too, or macOS opens its own save window.
        guard keyDown, !isRepeat else { return true }
        if key == 20 {
            DispatchQueue.main.async { self.captureScreen() }
        } else {
            setSelecting(true)
            DispatchQueue.main.async { self.beginSelection() }
        }
        return true
    }

    /// Copies the screen under the pointer, avoiding multi-monitor canvas merging.
    func captureScreen() {
        captureScreenUnderPointer()
    }

    /// Copies every display as individual screenshots.
    func captureAllScreens() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        grab(screens: screens, crop: nil)
    }

    func captureScreenUnderPointer() {
        guard let screen = screenUnderPointer() else { return }
        grab(screens: [screen], crop: nil)
    }

    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    func beginSelection() {
        guard selector == nil else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            setSelecting(false)
            return
        }
        let panel = ShotSelector(screen: screen)
        panel.onCancel = { [weak self] in self?.cancelSelection() }
        panel.onCrop = { [weak self] rect in self?.finishSelection(rect, on: screen) }
        panel.onFull = { [weak self] in
            guard let self else { return }
            self.tearDownSelector()
            self.grab(screens: [screen], crop: nil)
        }
        selector = panel
        setSelecting(true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finishSelection(_ crop: CGRect, on screen: NSScreen) {
        tearDownSelector()
        grab(screens: [screen], crop: crop)
    }

    func cancelSelection() {
        tearDownSelector()
    }

    private func tearDownSelector() {
        selector?.endCursor()
        selector?.orderOut(nil)
        selector = nil
        setSelecting(false)
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

    private func grab(screens: [NSScreen], crop: CGRect?) {
        Telemetry.shared.track("screenshot_captured", params: ["screens": "\(screens.count)", "has_crop": "\(crop != nil)"])
        let presentOn = screens.count == 1 ? screens[0] : (screenUnderPointer() ?? screens[0])
        let targets: [ShotTarget] = screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            return ShotTarget(
                displayID: displayID,
                width: screen.frame.width,
                height: screen.frame.height,
                crop: screens.count == 1 ? crop : nil,
                scale: max(screen.backingScaleFactor, 1),
                frame: screen.frame
            )
        }
        guard !targets.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            PermissionsState.promptScreenRecording()
            return
        }
        preview?.orderOut(nil)
        preview = nil
        playShutter()
        Task {
            do {
                var images: [CGImage] = []
                for target in targets {
                    let image = try await ShotGrab.capture(target)
                    images.append(image)
                }
                DispatchQueue.main.async { self.present(images, on: presentOn) }
            } catch {
                DispatchQueue.main.async {
                    if !CGPreflightScreenCaptureAccess() {
                        PermissionsState.promptScreenRecording()
                    }
                }
            }
        }
    }

    /// Copies one window, the same shelf as a normal screenshot.
    func capture(window id: CGWindowID) {
        guard CGPreflightScreenCaptureAccess() else {
            PermissionsState.promptScreenRecording()
            return
        }
        let screen = screenUnderPointer() ?? NSScreen.main
        playShutter()
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == id }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
                config.width = max(Int((window.frame.width * scale).rounded()), 2)
                config.height = max(Int((window.frame.height * scale).rounded()), 2)
                config.showsCursor = false
                config.capturesAudio = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let presentOn = screen ?? NSScreen.screens.first
                DispatchQueue.main.async {
                    guard let presentOn else { return }
                    self.present(image, on: presentOn)
                }
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
        present([image], on: screen)
    }

    private func present(_ images: [CGImage], on screen: NSScreen) {
        guard !images.isEmpty else { return }
        for image in images {
            shots.append(image)
            companionIDs[ObjectIdentifier(image)] = (UUID().uuidString, Date())
        }
        if shots.count > shotLimit {
            let removed = shots.prefix(shots.count - shotLimit)
            shots.removeFirst(shots.count - shotLimit)
            for old in removed {
                let key = ObjectIdentifier(old)
                companionIDs.removeValue(forKey: key)
                fileForShot.removeValue(forKey: key)
                saved.remove(key)
            }
        }
        // A screenshot replaces whatever was copied before it, including text.
        copy(images)
        switch ShotPreferences.after {
        case .copyClose:
            closePreview()
        case .saveClose:
            for image in images { _ = save(image) }
            closePreview()
        case .saveKeep:
            for image in images { _ = save(image) }
            showShelf(on: screen, animating: images)
        case .keep:
            showShelf(on: screen, animating: images)
        }
    }

    private func showShelf(on screen: NSScreen, animating newImages: [CGImage] = []) {
        let shown = shots
        let gap = ShotShelfStyle.gap
        let bar = ShotShelfStyle.chromeHeight
        let available = max(280, screen.visibleFrame.width - 32)
        let count = CGFloat(max(shown.count, 1))
        var thumbW = floor((available - 20 - gap * max(count - 1, 0)) / count)
        thumbW = min(shown.count == 1 ? 264 : 168, max(92, thumbW))
        let thumbH: CGFloat = shown.count == 1 ? 164 : max(62, floor(thumbW * 0.62))
        let width = min(available, thumbW * count + gap * max(count - 1, 0) + 20)
        let size = NSSize(width: max(width, 220), height: thumbH + bar + 10)
        let area = screen.visibleFrame
        let frame = NSRect(
            x: area.maxX - size.width - 14,
            y: area.minY + 14,
            width: size.width,
            height: size.height
        )
        let sameScreen = shelfScreen === screen
        let panel = preview ?? makeShelfPanel(frame: frame)
        let entering = !panel.isVisible
        if entering {
            panel.setFrame(frame.offsetBy(dx: 0, dy: -ShotShelfStyle.travel), display: false)
            panel.alphaValue = 0
        } else if !sameScreen {
            panel.setFrame(frame, display: false)
        }

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root.material = .hudWindow
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        root.layer?.cornerRadius = ShotShelfStyle.panelRadius
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        let animatedKeys = Set(newImages.map { ObjectIdentifier($0) })
        var enteringViews: [(NSView, NSRect)] = []

        for (index, image) in shown.enumerated() {
            let x = 10 + CGFloat(index) * (thumbW + gap)
            let targetFrame = NSRect(x: x, y: bar, width: thumbW, height: thumbH)
            let isNew = animatedKeys.contains(ObjectIdentifier(image))
            let imageView = ShotImageView(frame: isNew ? targetFrame.offsetBy(dx: 0, dy: -7) : targetFrame)
            imageView.alphaValue = isNew ? 0 : 1
            imageView.image = NSImage(cgImage: image, size: NSSize(width: thumbW, height: thumbH))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = ShotShelfStyle.imageRadius
            imageView.layer?.masksToBounds = true
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
            imageView.onOpen = { [weak self] in self?.openMarkup(index: index) }
            imageView.dragItemProvider = { [weak self] in
                guard let self else { return nil }
                guard let url = self.file(for: image) else { return nil }
                return (url, image)
            }
            root.addSubview(imageView)
            if isNew { enteringViews.append((imageView, targetFrame)) }
            let drop = barButton(
                symbol: "xmark",
                label: "Leave this screenshot out",
                frame: NSRect(x: x + 8, y: bar + thumbH - 32, width: ShotShelfStyle.controlSize, height: ShotShelfStyle.controlSize),
                action: #selector(dropOne(_:))
            )
            drop.tag = index
            root.addSubview(drop)
            let copyOne = barButton(
                symbol: "doc.on.clipboard",
                label: "Copy screenshot",
                frame: NSRect(x: x + thumbW - 32, y: bar + thumbH - 32, width: ShotShelfStyle.controlSize, height: ShotShelfStyle.controlSize),
                action: #selector(copyOne(_:))
            )
            copyOne.tag = index
            root.addSubview(copyOne)
            let edit = barButton(
                symbol: "pencil.tip",
                label: "Open this screenshot to edit",
                frame: NSRect(x: x + 8, y: bar + 8, width: ShotShelfStyle.controlSize, height: ShotShelfStyle.controlSize),
                action: #selector(openOne(_:))
            )
            edit.tag = index
            root.addSubview(edit)
        }

        let caption = NSTextField(labelWithString: shots.count == 1 ? "1 screenshot" : "\(shots.count) screenshots")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .white
        caption.frame = NSRect(x: 12, y: 10, width: size.width - 112, height: 18)
        caption.lineBreakMode = .byTruncatingTail
        root.addSubview(caption)
        self.caption = caption

        let copyAll = barButton(
            symbol: "doc.on.doc.fill",
            label: "Copy every screenshot",
            frame: NSRect(x: size.width - 90, y: 8, width: ShotShelfStyle.controlSize, height: ShotShelfStyle.controlSize),
            action: #selector(copyAll)
        )
        root.addSubview(copyAll)

        let save = barButton(
            symbol: "square.and.arrow.down",
            label: "Save screenshots to Desktop",
            frame: NSRect(x: size.width - 62, y: 8, width: ShotShelfStyle.controlSize, height: ShotShelfStyle.controlSize),
            action: #selector(savePreview)
        )
        root.addSubview(save)

        let close = barButton(
            symbol: "xmark",
            label: "Close screenshots",
            frame: NSRect(x: size.width - 34, y: 8, width: ShotShelfStyle.controlSize, height: ShotShelfStyle.controlSize),
            action: #selector(closePreview)
        )
        root.addSubview(close)

        panel.contentView = root
        preview = panel
        shelfScreen = screen
        presentShelf(panel, at: frame, entering: entering, animateFrame: sameScreen, enteringViews: enteringViews)
    }

    private func makeShelfPanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private func presentShelf(
        _ panel: NSPanel,
        at frame: NSRect,
        entering: Bool,
        animateFrame: Bool,
        enteringViews: [(NSView, NSRect)]
    ) {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : ShotShelfStyle.showDuration
        guard duration > 0 else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            for (view, targetFrame) in enteringViews {
                view.frame = targetFrame
                view.alphaValue = 1
            }
            panel.orderFrontRegardless()
            return
        }

        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            if entering { panel.animator().alphaValue = 1 }
            if entering || (animateFrame && panel.frame != frame) {
                panel.animator().setFrame(frame, display: true)
            } else if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            for (view, targetFrame) in enteringViews {
                view.animator().alphaValue = 1
                view.animator().frame = targetFrame
            }
        }, completionHandler: nil)
    }

    @objc private func closePreview() {
        markup?.window.close()
        markup = nil
        let panel = preview
        preview = nil
        caption = nil
        shots = []
        companionIDs.removeAll()
        saved = []
        fileForShot = [:]
        shelfScreen = nil
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : ShotShelfStyle.hideDuration
        guard duration > 0 else {
            panel.close()
            return
        }
        let frame = panel.frame.offsetBy(dx: 0, dy: -ShotShelfStyle.travel * 0.6)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            panel.close()
        })
    }

    @objc private func dropOne(_ sender: NSButton) {
        let index = sender.tag
        guard shots.indices.contains(index) else { return }
        let removed = shots.remove(at: index)
        let key = ObjectIdentifier(removed)
        companionIDs.removeValue(forKey: key)
        fileForShot.removeValue(forKey: key)
        saved.remove(key)
        guard !shots.isEmpty, let screen = shelfScreen ?? preview?.screen ?? NSScreen.main else {
            closePreview()
            return
        }
        showShelf(on: screen)
    }

    @objc private func openOne(_ sender: NSButton) {
        openMarkup(index: sender.tag)
    }

    /// Opens one picture large, in the Mac’s own markup editor. Done puts the edited picture back on the shelf.
    private func openMarkup(index: Int) {
        guard shots.indices.contains(index) else { return }
        if let markup {
            markup.reload()
            return
        }
        let original = shots[index]
        let editor = ShotMarkup(image: original)
        editor.onDone = { [weak self] edited in
            self?.applyEdit(original: original, edited: edited)
        }
        editor.onClose = { [weak self] in
            self?.markup = nil
            self?.preview?.orderFrontRegardless()
        }
        markup = editor
        editor.show(on: shelfScreen ?? preview?.screen ?? NSScreen.main ?? NSScreen.screens.first)
    }

    private func applyEdit(original: CGImage, edited: CGImage) {
        guard let index = shots.firstIndex(where: { $0 === original }) else { return }
        shots[index] = edited
        let oldKey = ObjectIdentifier(original)
        if let identity = companionIDs.removeValue(forKey: oldKey) {
            companionIDs[ObjectIdentifier(edited)] = identity
        }
        saved.remove(oldKey)
        fileForShot.removeValue(forKey: oldKey)
        guard let screen = shelfScreen ?? preview?.screen ?? NSScreen.main else { return }
        showShelf(on: screen, animating: [edited])
    }

    @objc private func copyOne(_ sender: NSButton) {
        let index = sender.tag
        guard shots.indices.contains(index) else { return }
        copy([shots[index]])
        caption?.stringValue = "Copied"
    }

    @objc private func copyAll() {
        copy(shots)
        caption?.stringValue = shots.count > 1 ? "Copied \(shots.count)" : "Copied"
    }

    @objc private func savePreview() {
        var wrote = 0
        for image in shots where !saved.contains(ObjectIdentifier(image)) {
            if save(image) { wrote += 1 }
        }
        caption?.stringValue = wrote > 0 ? "Saved" : "Saved already"
    }

    @discardableResult
    private func save(_ image: CGImage) -> Bool {
        let key = ObjectIdentifier(image)
        guard !saved.contains(key) else { return false }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              let url = Self.desktopScreenshotURL() else {
            caption?.stringValue = "Not saved"
            return false
        }
        do {
            try png.write(to: url, options: .atomic)
            saved.insert(key)
            fileForShot[key] = url
            return true
        } catch {
            caption?.stringValue = "Not saved"
            return false
        }
    }

    private func barButton(symbol: String, label: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(frame: frame)
        button.bezelStyle = .circular
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = frame.height / 2
        button.target = self
        button.action = action
        return button
    }

    private static func desktopScreenshotURL() -> URL? {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var url = desktop.appendingPathComponent("Screenshot \(stamp).png")
        var extra = 2
        while FileManager.default.fileExists(atPath: url.path), extra < 50 {
            url = desktop.appendingPathComponent("Screenshot \(stamp) \(extra).png")
            extra += 1
        }
        return url
    }

    private func file(for image: CGImage) -> URL? {
        let key = ObjectIdentifier(image)
        if let existing = fileForShot[key], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        guard let url = makeFile(for: image) else { return nil }
        fileForShot[key] = url
        return url
    }

    private func makeFile(for image: CGImage) -> URL? {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShowBarShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupOldTempFiles(in: dir)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var url = dir.appendingPathComponent("Screenshot \(stamp).png")
        var extra = 2
        while FileManager.default.fileExists(atPath: url.path), extra < 50 {
            url = dir.appendingPathComponent("Screenshot \(stamp) \(extra).png")
            extra += 1
        }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func cleanupOldTempFiles(in dir: URL) {
        Self.cleanupTempFiles(in: dir, olderThan: Date().addingTimeInterval(-300))
    }

    private static func cleanupTempFiles(in dir: URL, olderThan cutoff: Date) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        let clipboardFiles = Set(clipboardFileURLs().map(\.standardizedFileURL))
        for item in items {
            guard !clipboardFiles.contains(item.standardizedFileURL),
                  let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    private static func clipboardFileURLs() -> [URL] {
        let board = NSPasteboard.general
        var urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for item in board.pasteboardItems ?? [] {
            guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { continue }
            urls.append(url)
        }
        return urls
    }

    static func cleanupLaunchTempFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShowBarShots", isDirectory: true)
        cleanupTempFiles(in: dir, olderThan: .distantFuture)
    }

    /// Several pictures are copied as files. A chat paste then attaches every file, not only the first picture.
    private func copy(_ images: [CGImage]) {
        let files = images.compactMap { file(for: $0) }
        guard !files.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        if files.count == 1, let image = images.first,
           let rep = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setData(rep, forType: .png)
            if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            item.setString(files[0].absoluteString, forType: .fileURL)
            board.writeObjects([item])
            return
        }
        board.writeObjects(files as [NSURL])
    }

    private func playShutter() {
        let paths = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        ]
        for path in paths {
            guard let sound = NSSound(contentsOfFile: path, byReference: true) else { continue }
            shutterSound?.stop()
            shutterSound = sound
            sound.play()
            return
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
    let scale: CGFloat
    let frame: CGRect
}

private enum ShotGrab {
    static func capture(_ target: ShotTarget) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw ShotError.noDisplay
        }
        // Include Show Bar itself, so a screenshot can show the Dock preview and Command-Tab.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // display.width is in points. The output size is in pixels. Using points
        // keeps only the top-left piece of a Retina screen.
        let scale = max(target.scale, 1)
        config.captureResolution = .best
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.sourceRect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
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
    var onFull: (() -> Void)?
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
        canvas.onFull = { [weak self] in self?.onFull?() }
        canvas.screen = screen
        canvas.installHint()
        canvas.beginCropCursor()
    }

    func endCursor() {
        canvas.endCropCursor()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(canvas)
        canvas.beginCropCursor()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func useWindowUnderPointer() {
        canvas.armWindowMode()
    }

    func captureWholeScreen() {
        onFull?()
    }
}

private final class SelectionCanvas: NSView {
    var onCrop: ((CGRect) -> Void)?
    var onFull: (() -> Void)?
    var onCancel: (() -> Void)?
    weak var screen: NSScreen?
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var windowMode = false
    private var hoveredWindow: CGRect?
    private var pointer = CGPoint.zero
    private var cursorTimer: Timer?
    private var cursorHidden = false
    private let hint = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func installHint() {
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        hint.layer?.cornerRadius = 10
        addSubview(hint)
        refreshHint()
    }

    func beginCropCursor() {
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
        followPointer()
        guard cursorTimer == nil else { return }
        // resource: active 0.016 — runs only while a crop is being dragged.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.followPointer()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    func endCropCursor() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    deinit {
        endCropCursor()
    }

    private func followPointer() {
        let raw = window?.mouseLocationOutsideOfEventStream ?? .zero
        pointer = convert(raw, from: nil)
        if windowMode {
            hoveredWindow = window(at: pointer)
        }
        needsDisplay = true
    }

    func armWindowMode() {
        windowMode = true
        anchor = nil
        current = nil
        hoveredWindow = window(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        refreshHint()
        followPointer()
    }

    override func resetCursorRects() {
        discardCursorRects()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        followPointer()
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
        drawTarget(at: pointer)
    }

    /// A ring with crosshairs, drawn on the shade. The system plus is too small and does not stay.
    private func drawTarget(at point: CGPoint) {
        let arm: CGFloat = 18
        let radius: CGFloat = 11
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: point.x - arm, y: point.y))
        cross.line(to: CGPoint(x: point.x + arm, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - arm))
        cross.line(to: CGPoint(x: point.x, y: point.y + arm))
        let ring = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        NSColor.black.withAlphaComponent(0.9).setStroke()
        cross.lineWidth = 4
        cross.stroke()
        ring.lineWidth = 4
        ring.stroke()
        NSColor.white.setStroke()
        cross.lineWidth = 2
        cross.stroke()
        ring.lineWidth = 2
        ring.stroke()
    }

    private func refreshHint() {
        hint.stringValue = windowMode
            ? "Click a window to copy   ·   Return copies this whole screen   ·   Esc to cancel"
            : "Drag to copy a part   ·   Return copies this whole screen   ·   Space for a window   ·   Esc to cancel"
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
        pointer = current ?? pointer
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        followPointer()
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
    var onOpen: (() -> Void)?
    var dragItemProvider: (() -> (URL, CGImage)?)?
    private var press: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func mouseDown(with event: NSEvent) {
        press = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let current = convert(event.locationInWindow, from: nil)
        let distance = hypot(current.x - press.x, current.y - press.y)
        guard distance >= 3 else { return }
        self.press = nil
        guard let (url, fullImage) = dragItemProvider?() else { return }
        let writer = ShotPasteboardWriter(fileURL: url, image: fullImage)
        let item = NSDraggingItem(pasteboardWriter: writer)
        if let dragImage = image {
            item.setDraggingFrame(bounds, contents: dragImage)
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }
        press = nil
        let upLocation = convert(event.locationInWindow, from: nil)
        if bounds.contains(upLocation) {
            onOpen?()
        }
    }
}

private final class ShotPasteboardWriter: NSObject, NSPasteboardWriting {
    let fileURL: URL
    let image: CGImage

    init(fileURL: URL, image: CGImage) {
        self.fileURL = fileURL
        self.image = image
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        return [.fileURL, .png, .tiff]
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == .fileURL {
            return (fileURL as NSURL).writingOptions(forType: type, pasteboard: pasteboard)
        }
        return []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL {
            return (fileURL as NSURL).pasteboardPropertyList(forType: type)
        }
        if type == .png {
            if let data = try? Data(contentsOf: fileURL) {
                return data
            }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        if type == .tiff {
            return NSBitmapImageRep(cgImage: image).tiffRepresentation
        }
        return nil
    }
}

/// The Mac’s screenshot markup window. MarkupUI is private, so it is loaded by name.
private final class ShotMarkup: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let controller: NSViewController?
    private let image: CGImage
    var onDone: ((CGImage) -> Void)?
    var onClose: (() -> Void)?
    private var previousApp: NSRunningApplication?

    init(image: CGImage) {
        self.image = image
        _ = Bundle(path: "/System/Library/PrivateFrameworks/MarkupUI.framework")?.load()
        let controller = NSClassFromString("MarkupViewController") as? NSViewController.Type
        let markup = controller?.init()
        markup?.setValue(true, forKey: "cropToolEnabled")
        markup?.setValue(true, forKey: "wantsToolbarAndPadding")
        self.controller = markup
        let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Screenshot"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = markup ?? Self.plainPreview(image)
        installButtons()
    }

    func show(on screen: NSScreen?) {
        previousApp = NSWorkspace.shared.frontmostApplication
        fit(on: screen)
        loadImage(on: screen)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        fit(on: window.screen)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadImage(on screen: NSScreen?) {
        guard let controller else { return }
        let scale = max(screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        let points = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let picture = NSImage(cgImage: image, size: points)
        typealias SetImageFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let sel = NSSelectorFromString("setImage:withArchivedModelData:")
        if controller.responds(to: sel) {
            let fn = unsafeBitCast(controller.method(for: sel), to: SetImageFn.self)
            fn(controller, sel, picture, nil)
        }
    }

    private func fit(on screen: NSScreen?) {
        let area = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let limit = area.insetBy(dx: 48, dy: 56)
        let pixel = CGSize(width: image.width, height: image.height)
        let scale = min(limit.width / max(pixel.width, 1), limit.height / max(pixel.height, 1), 1)
        let size = NSSize(
            width: max(640, floor(pixel.width * scale)),
            height: max(420, floor(pixel.height * scale))
        )
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2
        ))
    }

    private func installButtons() {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(commit))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 146, height: 28))
        cancel.frame = NSRect(x: 0, y: 2, width: 68, height: 24)
        done.frame = NSRect(x: 74, y: 2, width: 64, height: 24)
        box.addSubview(cancel)
        box.addSubview(done)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = box
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func cancel() {
        window.close()
    }

    @objc private func commit() {
        let edited = flattened() ?? image
        onDone?(edited)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
        let previous = previousApp
        previousApp = nil
        guard let previous, previous.processIdentifier != getpid(), !previous.isTerminated else { return }
        previous.activate(from: .current, options: [])
    }

    private func flattened() -> CGImage? {
        guard let controller else { return nil }
        let sel = NSSelectorFromString("dataRepresentationWithError:")
        guard controller.responds(to: sel) else { return nil }
        typealias DataFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(controller.method(for: sel), to: DataFn.self)
        guard let data = fn(controller, sel, nil)?.takeUnretainedValue() as? Data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func plainPreview(_ image: CGImage) -> NSViewController {
        let controller = NSViewController()
        let view = NSImageView()
        view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        controller.view = view
        return controller
    }
}
