import Foundation
import Network
import XCTest
@testable import ShowBarCompanion

@MainActor
final class CompanionIntegrationTests: XCTestCase {
    func testPairedConnectionTransmitsSelectedWindowCommandsAndScreenshotReplies() async throws {
        let mac = LoopbackMac()
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        XCTAssertEqual(mac.helloCount, 1)
        XCTAssertEqual(mac.helloDeviceID, client.deviceID)
        XCTAssertFalse(client.deviceID.isEmpty)
        XCTAssertEqual(client.snapshot?.hostName, "Loopback Mac")
        let window = try XCTUnwrap(client.snapshot?.windows.first)

        client.focus(window)
        client.snap("right")
        client.sendText("preserve this\n    indentation", paste: true)
        var receivedImage: Data?
        var imageCompletions = 0
        client.requestShot("shot-one") { data in
            receivedImage = data
            imageCompletions += 1
        }
        try await eventually { mac.commands.count == 4 && receivedImage != nil }

        XCTAssertEqual(mac.commands.map(\.action), [.focus, .snap, .pasteToMac, .requestShot])
        XCTAssertEqual(mac.commands[0].windowID, window.id)
        XCTAssertEqual(mac.commands[1].windowID, window.id)
        XCTAssertEqual(mac.commands[1].zone, "right")
        XCTAssertEqual(mac.commands[2].windowID, window.id)
        XCTAssertEqual(mac.commands[2].text, "preserve this\n    indentation")
        XCTAssertEqual(mac.commands[3].shotID, "shot-one")
        XCTAssertEqual(receivedImage, mac.image)
        XCTAssertEqual(imageCompletions, 1)

        client.disconnect()
        XCTAssertFalse(client.isConnected)
        XCTAssertNil(client.snapshot)
        XCTAssertNil(client.selectedWindowID)
        XCTAssertEqual(client.phase, .idle)
    }

    func testMalformedScreenshotReplyDoesNotReachImageConsumer() async throws {
        let mac = LoopbackMac()
        mac.imageMimeType = "text/plain"
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        var completed = false
        client.requestShot("shot-one") { data in
            XCTAssertNil(data)
            completed = true
        }
        try await eventually { completed }
        XCTAssertTrue(client.isConnected)
        XCTAssertNotNil(client.errorMessage)
    }

    func testCancellingScreenshotRequestsKeepsOtherActionsAndIgnoresLateReplies() async throws {
        let mac = LoopbackMac()
        mac.deferScreenshotReplies = true
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        var completions = 0
        for _ in 0..<2 {
            client.requestShot("shot-one") { data in
                XCTAssertNil(data)
                completions += 1
            }
        }
        client.sendText("explicitly copied", paste: false)
        try await eventually { mac.commands.count == 3 }
        client.cancelShotRequests()
        client.cancelShotRequests()
        XCTAssertEqual(completions, 2)
        mac.finishDeferredScreenshots()
        try await eventually { client.feedback == "Action completed" }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(completions, 2)
        XCTAssertTrue(client.isConnected)
        XCTAssertNil(client.errorMessage)
    }

    func testDisconnectMarksConnectionUnavailableBeforeCancellingImageConsumers() async throws {
        let mac = LoopbackMac()
        mac.deferScreenshotReplies = true
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        var completions = 0
        client.requestShot("shot-one") { data in
            XCTAssertNil(data)
            XCTAssertFalse(client.isConnected)
            client.requestShot("shot-one") { secondData in
                XCTAssertNil(secondData)
                completions += 1
            }
            completions += 1
        }
        try await eventually { mac.commands.count == 1 }
        client.disconnect()
        XCTAssertEqual(completions, 2)
        XCTAssertNil(client.snapshot)
        XCTAssertEqual(client.phase, .idle)
    }

    func testDeniedCapabilitiesBlockRemoteActionsAndAllowRefresh() async throws {
        let mac = LoopbackMac()
        mac.capabilities = BridgeCapabilities.none
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        let window = try XCTUnwrap(client.snapshot?.windows.first)
        client.focus(window)
        client.close(window)
        client.snap("left")
        client.sendText("copy", paste: false)
        client.sendText("paste", paste: true)
        var completions = 0
        client.requestShot("shot-one") { data in
            XCTAssertNil(data)
            completions += 1
        }
        client.requestClipImage("clip-image-one") { data in
            XCTAssertNil(data)
            completions += 1
        }
        XCTAssertEqual(client.capabilities, .none)
        XCTAssertEqual(completions, 2)
        XCTAssertNotNil(client.errorMessage)
        client.refresh()
        try await eventually { mac.commands.count == 1 }
        XCTAssertEqual(mac.commands.map(\.action), [.refresh])
    }

    func testMissingCapabilityMetadataFailsClosedWithUpdateGuidance() async throws {
        let mac = LoopbackMac()
        mac.capabilities = nil
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        client.sendText("must stay here", paste: false)
        XCTAssertEqual(client.capabilities, .none)
        XCTAssertEqual(client.errorMessage, "Update Show Bar on your Mac to manage companion permissions.")
        XCTAssertTrue(mac.commands.isEmpty)
        XCTAssertTrue(client.snapshot?.clips.isEmpty == true)
        XCTAssertTrue(client.snapshot?.shots.isEmpty == true)
        XCTAssertNil(client.snapshot?.windows.first?.thumbnail)
    }

    func testCapabilityRevocationCancelsImagesAndBlocksFurtherActionsImmediately() async throws {
        let mac = LoopbackMac()
        mac.deferScreenshotReplies = true
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        let window = try XCTUnwrap(client.snapshot?.windows.first)
        client.selectedWindowID = window.id
        XCTAssertNotNil(window.thumbnail)
        XCTAssertEqual(client.snapshot?.clips.count, 1)
        XCTAssertEqual(client.snapshot?.shots.count, 1)
        var completions = 0
        client.requestShot("shot-one") { data in
            XCTAssertNil(data)
            completions += 1
        }
        client.requestClipImage("clip-image-one") { data in
            XCTAssertNil(data)
            completions += 1
        }
        try await eventually { mac.commands.count == 2 }
        mac.capabilities = BridgeCapabilities.none
        mac.sendState()
        try await eventually { client.capabilities == .none && completions == 2 }
        XCTAssertTrue(client.snapshot?.clips.isEmpty == true)
        XCTAssertTrue(client.snapshot?.shots.isEmpty == true)
        XCTAssertNil(client.snapshot?.windows.first?.thumbnail)
        client.snap("right")
        client.sendText("not sent", paste: false)
        mac.finishDeferredScreenshots()
        client.refresh()
        try await eventually { mac.commands.count == 3 }
        XCTAssertEqual(mac.commands.map(\.action), [.requestShot, .requestClipImage, .refresh])
        XCTAssertEqual(completions, 2)
        XCTAssertTrue(client.isConnected)
    }

    func testClipboardImageRequestRoutesItsIDAndImageReply() async throws {
        let mac = LoopbackMac()
        let endpoint = try await mac.start()
        let client = CompanionClient()
        defer {
            client.forgetPairing()
            mac.stop()
        }
        client.connect(to: DiscoveredMac(id: UUID().uuidString, name: "Loopback Mac", endpoint: endpoint),
                       pairingCode: mac.code)
        try await eventually { client.isConnected }
        var receivedImage: Data?
        var completions = 0
        client.requestClipImage("clip-image-one") { data in
            receivedImage = data
            completions += 1
        }
        try await eventually { receivedImage != nil }
        XCTAssertEqual(receivedImage, mac.image)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(mac.commands.count, 1)
        XCTAssertEqual(mac.commands.first?.action, .requestClipImage)
        XCTAssertEqual(mac.commands.first?.clipID, "clip-image-one")
        XCTAssertNil(mac.commands.first?.shotID)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw FixtureError.timeout }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private enum FixtureError: Error { case timeout, missingPort, stopped }

/// A real paired TLS endpoint, rather than a mock of the client's state machine.
@MainActor
private final class LoopbackMac {
    let code = BridgePairingCode.generate()
    let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+rGrsAAAAASUVORK5CYII=") ?? Data()
    var imageMimeType = "image/png"
    var deferScreenshotReplies = false
    var capabilities: BridgeCapabilities? = .all
    private(set) var commands: [BridgeCommand] = []
    private(set) var helloCount = 0
    private(set) var helloDeviceID: String?
    private(set) var helloDeviceName: String?

    private let queue = DispatchQueue(label: "showbar.companion.test.mac")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = BridgeFrameDecoder()
    private var startContinuation: CheckedContinuation<NWEndpoint, Error>?
    private var startTimeout: Task<Void, Never>?
    private var deferredScreenshotIDs: [String] = []

    func start() async throws -> NWEndpoint {
        let parameters = try BridgeTransport.parameters(pairingCode: code)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener?.port {
                        self.finishStart(.success(.hostPort(host: "127.0.0.1", port: port)))
                    } else {
                        self.finishStart(.failure(FixtureError.missingPort))
                    }
                case .failed(let error): self.finishStart(.failure(error))
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            startTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.finishStart(.failure(FixtureError.timeout))
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        finishStart(.failure(FixtureError.stopped))
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    func finishDeferredScreenshots() {
        let ids = deferredScreenshotIDs
        deferredScreenshotIDs = []
        for id in ids {
            send(BridgeMessage(kind: .result, requestID: id, result: BridgeResult(
                success: true, message: "Screenshot ready", data: image, mimeType: imageMimeType
            )))
        }
    }

    func sendState() {
        send(BridgeMessage(kind: .state, snapshot: BridgeSnapshot(
            hostName: "Loopback Mac",
            windows: [BridgeWindow(id: 42, pid: 7, title: "Fixture window", appName: "Notes", isCurrent: true, thumbnail: image)],
            clips: [BridgeClip(id: "clip-image-one", kind: "image", text: "Image", date: Date(), thumbnail: image)],
            shots: [BridgeShot(id: "shot-one", date: Date())],
            permissions: BridgePermissions(accessibility: true, screenRecording: true), capabilities: capabilities
        )))
    }

    private func finishStart(_ result: Result<NWEndpoint, Error>) {
        let continuation = startContinuation
        startContinuation = nil
        startTimeout?.cancel()
        startTimeout = nil
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { @MainActor [weak self] in self?.receive() }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, let messages = try? self.decoder.append(data) {
                    messages.forEach(self.handle)
                }
                if !complete, error == nil { self.receive() }
            }
        }
    }

    private func handle(_ message: BridgeMessage) {
        switch message.kind {
        case .hello:
            helloCount += 1
            helloDeviceID = message.deviceID
            helloDeviceName = message.deviceName
            sendState()
        case .command:
            guard let command = message.command else { return }
            commands.append(command)
            let isImageRequest = command.action == .requestShot || command.action == .requestClipImage
            if isImageRequest, deferScreenshotReplies, let id = message.requestID {
                deferredScreenshotIDs.append(id)
                return
            }
            let result = isImageRequest
                ? BridgeResult(success: true, message: "Screenshot ready", data: image, mimeType: imageMimeType)
                : BridgeResult(success: true, message: "Action completed")
            send(BridgeMessage(kind: .result, requestID: message.requestID, result: result))
        case .ping:
            send(BridgeMessage(kind: .pong, requestID: message.requestID))
        default:
            break
        }
    }

    private func send(_ message: BridgeMessage) {
        guard let data = try? message.encodedFrame() else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}
