import AppKit
import SwiftUI

struct Clip: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text, link, image
    }

    let id: UUID
    let date: Date
    let kind: Kind
    var text: String
    var imageName: String?
}

/// Keeps what you copy: text, links, and pictures. Hidden passwords are skipped.
final class ClipboardShelf: ObservableObject {
    static let shared = ClipboardShelf()

    @Published private(set) var clips: [Clip] = []
    private var timer: Timer?
    private var lastSeen = -1
    private var suppressChange = -1
    private var returnTo: pid_t?
    private var window: NSWindow?
    private var thumbs: [UUID: NSImage] = [:]
    private let limit = 100
    private let folder: URL
    private let indexURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Show Bar/Clipboard", isDirectory: true)
        folder = base
        indexURL = base.appendingPathComponent("index.json")
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.45, repeats: true) { _ in
            ClipboardShelf.shared.captureIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        captureIfNeeded()
    }

    func rememberTarget() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        returnTo = pid
    }

    func show() {
        rememberTarget()
        let panel = window ?? makeWindow()
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(from: .current, options: [])
    }

    func paste(id: String) {
        guard let clip = clips.first(where: { $0.id.uuidString == id }) else { return }
        put(clip)
        window?.orderOut(nil)
        guard let returnTo, let app = NSRunningApplication(processIdentifier: returnTo), !app.isTerminated else { return }
        app.activate(from: .current, options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.sendPaste()
        }
    }

    func remove(_ clip: Clip) {
        if let name = clip.imageName {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        thumbs[clip.id] = nil
        clips.removeAll { $0.id == clip.id }
        save()
    }

    func clear() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Copied text, links, and pictures saved by Show Bar will be removed from this Mac."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for clip in clips {
            if let name = clip.imageName {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        thumbs.removeAll()
        clips = []
        save()
    }

    func thumbnail(for clip: Clip) -> NSImage? {
        if let cached = thumbs[clip.id] { return cached }
        guard let name = clip.imageName else { return nil }
        guard let image = NSImage(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        let thumb = NSImage(size: NSSize(width: 72, height: 48))
        thumb.lockFocus()
        NSColor.black.withAlphaComponent(0.08).setFill()
        NSRect(origin: .zero, size: thumb.size).fill()
        let fitted = fit(image.size, into: thumb.size)
        image.draw(in: NSRect(
            x: (thumb.size.width - fitted.width) / 2,
            y: (thumb.size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        ))
        thumb.unlockFocus()
        thumbs[clip.id] = thumb
        return thumb
    }

    func menuTitle(for clip: Clip) -> String {
        if clip.kind == .image, clip.text.isEmpty || clip.text == "Image" { return "Image" }
        let line = clip.text.replacingOccurrences(of: "\n", with: " ")
        if line.count > 64 { return String(line.prefix(64)) + "…" }
        return line.isEmpty ? "Image" : line
    }

    private func captureIfNeeded() {
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastSeen else { return }
        lastSeen = count
        guard count != suppressChange else { return }
        guard let clip = read(board) else { return }
        if let newest = clips.first, newest.kind == clip.kind, newest.text == clip.text, newest.imageName == nil, clip.imageName == nil {
            return
        }
        clips.insert(clip, at: 0)
        if clips.count > limit {
            for dropped in clips.suffix(from: limit) {
                if let name = dropped.imageName {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
                thumbs[dropped.id] = nil
            }
            clips = Array(clips.prefix(limit))
        }
        save()
    }

    private func read(_ board: NSPasteboard) -> Clip? {
        let types = board.types ?? []
        if types.contains(.init("org.nspasteboard.ConcealedType")) || types.contains(.init("org.nspasteboard.TransientType")) {
            return nil
        }
        if let image = board.data(forType: .png) ?? board.data(forType: .tiff), let png = pngData(from: image), png.count > 32 {
            let name = UUID().uuidString + ".png"
            try? png.write(to: folder.appendingPathComponent(name))
            let caption = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Clip(id: UUID(), date: Date(), kind: .image, text: caption.isEmpty ? "Image" : caption, imageName: name)
        }
        let raw = board.string(forType: .string)
            ?? (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.absoluteString
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let stored = text.count > 200_000 ? String(text.prefix(200_000)) : text
        return Clip(id: UUID(), date: Date(), kind: kind(of: stored), text: stored, imageName: nil)
    }

    private func kind(of text: String) -> Clip.Kind {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return .text }
        if scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "file" { return .link }
        return .text
    }

    private func put(_ clip: Clip) {
        let board = NSPasteboard.general
        board.clearContents()
        if clip.kind == .image, let name = clip.imageName, let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
            board.declareTypes([.png], owner: nil)
            board.setData(data, forType: .png)
        } else {
            board.declareTypes([.string], owner: nil)
            board.setString(clip.text, forType: .string)
        }
        suppressChange = board.changeCount
        lastSeen = board.changeCount
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingView(rootView: ClipboardView(shelf: self))
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Clipboard"
        panel.contentView = host
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([Clip].self, from: data) else { return }
        clips = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 1, image.size.height > 1 else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2000 / longest)
        let size = NSSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func fit(_ size: NSSize, into limit: NSSize) -> NSSize {
        guard size.width > 1, size.height > 1 else { return limit }
        let scale = min(limit.width / size.width, limit.height / size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    private static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

struct ClipboardView: View {
    @ObservedObject var shelf: ClipboardShelf
    @State private var query = ""

    private var shown: [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return shelf.clips }
        return shelf.clips.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search copies", text: $query)
                .textFieldStyle(.roundedBorder)
            if shown.isEmpty {
                Text(shelf.clips.isEmpty ? "Nothing copied yet." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { clip in
                    HStack(spacing: 10) {
                        Button {
                            shelf.paste(id: clip.id.uuidString)
                        } label: {
                            row(clip)
                        }
                        .buttonStyle(.plain)
                        Button {
                            shelf.remove(clip)
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                }
            }
            HStack {
                Text("Control-Option-V opens this list. A click pastes into the app you were using.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear…") { shelf.clear() }
                    .disabled(shelf.clips.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: 520)
    }

    private func row(_ clip: Clip) -> some View {
        HStack(spacing: 10) {
            if let thumb = shelf.thumbnail(for: clip) {
                Image(nsImage: thumb)
                    .resizable()
                    .frame(width: 72, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: clip.kind == .link ? "link" : "doc.text")
                    .frame(width: 28)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(clip.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
