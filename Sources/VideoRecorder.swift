import AppKit
import AVFoundation

final class VideoRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    static let shared = VideoRecorder()

    private var session: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var screenInput: AVCaptureScreenInput?
    private var recordingTimer: Timer?
    private(set) var isRecording = false
    private var outputURL: URL?
    private var onFinished: ((URL?) -> Void)?
    private var startTime: Date?

    var onStatusChanged: ((Bool, TimeInterval) -> Void)?

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording(on screen: NSScreen? = nil) {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high

        let targetScreen = screen ?? screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let displayID = (targetScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()

        guard let input = AVCaptureScreenInput(displayID: displayID) else { return }
        input.capturesCursor = true
        input.capturesMouseClicks = true
        input.minFrameDuration = CMTime(value: 1, timescale: 60)

        guard captureSession.canAddInput(input) else { return }
        captureSession.addInput(input)

        let output = AVCaptureMovieFileOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShowBarRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let fileURL = dir.appendingPathComponent("Screen Recording \(stamp).mp4")
        try? FileManager.default.removeItem(at: fileURL)

        self.session = captureSession
        self.screenInput = input
        self.movieOutput = output
        self.outputURL = fileURL
        self.isRecording = true
        self.startTime = Date()

        captureSession.startRunning()
        output.startRecording(to: fileURL, recordingDelegate: self)

        // resource: active 1.0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.onStatusChanged?(true, elapsed)
        }
        onStatusChanged?(true, 0)
    }

    func stopRecording(completion: ((URL?) -> Void)? = nil) {
        guard isRecording else {
            completion?(nil)
            return
        }
        self.onFinished = completion
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        onStatusChanged?(false, 0)
        movieOutput?.stopRecording()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        session?.stopRunning()
        session = nil
        screenInput = nil
        movieOutput = nil

        let finalURL = (error == nil && FileManager.default.fileExists(atPath: outputFileURL.path)) ? outputFileURL : nil
        let callback = onFinished
        onFinished = nil

        DispatchQueue.main.async {
            callback?(finalURL)
            if let finalURL {
                VideoEditorWindow.open(url: finalURL)
            }
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}
