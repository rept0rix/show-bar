import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ShowBarStoreApp: App {
    @StateObject private var model = ShowBarStoreModel()

    var body: some Scene {
        Window("Show Bar", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 600, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            ShowBarWindowCommands()
        }
    }
}

private struct ShowBarWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Show Main Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}

@MainActor
final class ShowBarStoreModel: ObservableObject {
    @Published var image: NSImage?
    @Published var status = "Capture a screen, or add text from the clipboard."
    @Published var history: [String] = UserDefaults.standard.stringArray(forKey: "ShowBarStore.clipboardHistory") ?? []
    @Published var isCapturing = false

    func captureScreen() {
        guard !isCapturing else { return }
        isCapturing = true
        status = "Preparing screen capture…"
        Task {
            defer { isCapturing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let mainDisplayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
                    status = "No display is available."
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                let scale = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
                }?.backingScaleFactor ?? 1
                configuration.captureResolution = .best
                configuration.width = Int((CGFloat(display.width) * scale).rounded())
                configuration.height = Int((CGFloat(display.height) * scale).rounded())
                configuration.sourceRect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
                configuration.capturesAudio = false
                let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                image = NSImage(cgImage: captured, size: NSSize(width: captured.width, height: captured.height))
                status = "Screen captured. Copy it or save it as a PNG."
            } catch {
                status = "Screen capture failed: \(error.localizedDescription)"
            }
        }
    }

    func copyImage() {
        guard let image, let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        status = "Screenshot copied to the clipboard."
    }

    func saveImage() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Show Bar Screenshot.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url, options: .atomic)
            status = "Screenshot saved."
        } catch {
            status = "Could not save the screenshot: \(error.localizedDescription)"
        }
    }

    func addClipboardText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            status = "There is no text on the clipboard."
            return
        }
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        history = Array(history.prefix(30))
        UserDefaults.standard.set(history, forKey: "ShowBarStore.clipboardHistory")
        status = "Text added to your Show Bar history."
    }

    func copyHistoryItem(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Text copied to the clipboard."
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "ShowBarStore.clipboardHistory")
        status = "Clipboard history cleared."
    }
}

private struct ContentView: View {
    @ObservedObject var model: ShowBarStoreModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Bar").font(.title2.weight(.semibold))
                    Text("Screenshots and clipboard notes").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.captureScreen()
                } label: {
                    Label(model.isCapturing ? "Capturing…" : "Capture Screen", systemImage: "camera")
                }
                .disabled(model.isCapturing)
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            .padding(20)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Screenshot").font(.headline)
                    Group {
                        if let image = model.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            ContentUnavailableView("No Screenshot Yet", systemImage: "rectangle.dashed", description: Text("Capture a screen to preview, copy, or save it."))
                        }
                    }
                    HStack {
                        Button("Copy") { model.copyImage() }.disabled(model.image == nil)
                        Button("Save PNG…") { model.saveImage() }.disabled(model.image == nil)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Clipboard History").font(.headline)
                        Spacer()
                        Button("Add Current Text") { model.addClipboardText() }
                    }
                    Text("Show Bar reads the clipboard only when you press Add Current Text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.history.isEmpty {
                        ContentUnavailableView("No Saved Text", systemImage: "doc.on.clipboard", description: Text("Add text from the clipboard to keep it here."))
                    } else {
                        List {
                            ForEach(Array(model.history.enumerated()), id: \.offset) { _, text in
                                Button {
                                    model.copyHistoryItem(text)
                                } label: {
                                    Text(text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .help("Copy this text")
                            }
                        }
                        .listStyle(.inset)
                        Button("Clear History", role: .destructive) { model.clearHistory() }
                    }
                }
                .padding(20)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
            }

            Divider()
            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
    }
}
