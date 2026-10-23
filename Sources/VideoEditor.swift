import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

final class VideoEditorWindow: NSObject, NSWindowDelegate {
    private static var current: VideoEditorWindow?

    static func open(url: URL) {
        let editor = VideoEditorWindow(url: url)
        current = editor
        editor.show()
    }

    private let url: URL
    private let player: AVPlayer
    private let playerView: AVPlayerView
    private let window: NSWindow
    private var duration: Double = 0
    private var trimStart: Double = 0
    private var trimEnd: Double = 0

    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let exportButton = NSButton()
    private let copyButton = NSButton()

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        self.playerView = AVPlayerView()

        let rect = NSRect(x: 0, y: 0, width: 840, height: 600)
        self.window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Show Bar — Video Editor (\(url.lastPathComponent))"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        setupUI()
        loadDuration()
    }

    private func setupUI() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        window.contentView = content

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)

        let controlBar = NSView()
        controlBar.wantsLayer = true
        controlBar.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1.0).cgColor
        controlBar.layer?.cornerRadius = 8
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controlBar)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(timeLabel)

        let startLabel = NSTextField(labelWithString: "Trim In:")
        startLabel.font = .systemFont(ofSize: 11, weight: .bold)
        startLabel.textColor = .secondaryLabelColor
        startLabel.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(startLabel)

        startSlider.minValue = 0
        startSlider.maxValue = 1
        startSlider.doubleValue = 0
        startSlider.target = self
        startSlider.action = #selector(startSliderChanged)
        startSlider.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(startSlider)

        let endLabel = NSTextField(labelWithString: "Trim Out:")
        endLabel.font = .systemFont(ofSize: 11, weight: .bold)
        endLabel.textColor = .secondaryLabelColor
        endLabel.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(endLabel)

        endSlider.minValue = 0
        endSlider.maxValue = 1
        endSlider.doubleValue = 1
        endSlider.target = self
        endSlider.action = #selector(endSliderChanged)
        endSlider.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(endSlider)

        copyButton.title = "Copy Video"
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyVideo)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(copyButton)

        exportButton.title = "Save Trimmed"
        exportButton.bezelStyle = .rounded
        exportButton.contentTintColor = .systemBlue
        exportButton.target = self
        exportButton.action = #selector(exportVideo)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(exportButton)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: -10),

            controlBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controlBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            controlBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            controlBar.heightAnchor.constraint(equalToConstant: 72),

            startLabel.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 12),
            startLabel.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: 12),
            startLabel.widthAnchor.constraint(equalToConstant: 60),

            startSlider.leadingAnchor.constraint(equalTo: startLabel.trailingAnchor, constant: 4),
            startSlider.centerYAnchor.constraint(equalTo: startLabel.centerYAnchor),
            startSlider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -12),

            endLabel.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 12),
            endLabel.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 12),
            endLabel.widthAnchor.constraint(equalToConstant: 60),

            endSlider.leadingAnchor.constraint(equalTo: endLabel.trailingAnchor, constant: 4),
            endSlider.centerYAnchor.constraint(equalTo: endLabel.centerYAnchor),
            endSlider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -12),

            timeLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -16),
            timeLabel.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),

            exportButton.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -12),
            exportButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
        ])
    }

    private func loadDuration() {
        Task {
            let asset = AVURLAsset(url: url)
            if let dur = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(dur)
                await MainActor.run {
                    self.duration = seconds > 0 ? seconds : 1
                    self.trimStart = 0
                    self.trimEnd = self.duration
                    self.startSlider.maxValue = self.duration
                    self.endSlider.maxValue = self.duration
                    self.endSlider.doubleValue = self.duration
                    self.updateTimeLabel()
                }
            }
        }
    }

    private func updateTimeLabel() {
        let s = formatTime(trimStart)
        let e = formatTime(trimEnd)
        let total = formatTime(duration)
        timeLabel.stringValue = "\(s) - \(e) / \(total)"
    }

    private func formatTime(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }

    @objc private func startSliderChanged() {
        trimStart = min(startSlider.doubleValue, trimEnd - 0.5)
        startSlider.doubleValue = trimStart
        player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))
        updateTimeLabel()
    }

    @objc private func endSliderChanged() {
        trimEnd = max(endSlider.doubleValue, trimStart + 0.5)
        endSlider.doubleValue = trimEnd
        player.seek(to: CMTime(seconds: trimEnd, preferredTimescale: 600))
        updateTimeLabel()
    }

    @objc private func copyVideo() {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        copyButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "Copy Video"
        }
    }

    @objc private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Trimmed " + url.lastPathComponent
        if panel.runModal() == .OK, let dest = panel.url {
            exportTrimmed(to: dest)
        }
    }

    private func exportTrimmed(to destination: URL) {
        exportButton.isEnabled = false
        exportButton.title = "Exporting…"

        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            exportButton.isEnabled = true
            exportButton.title = "Save Trimmed"
            return
        }

        export.outputURL = destination
        export.outputFileType = .mp4
        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let durationTime = CMTime(seconds: max(0.2, trimEnd - trimStart), preferredTimescale: 600)
        export.timeRange = CMTimeRange(start: startTime, duration: durationTime)

        export.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                self?.exportButton.isEnabled = true
                self?.exportButton.title = "Save Trimmed"
                if export.status == .completed {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        VideoEditorWindow.current = nil
    }
}
