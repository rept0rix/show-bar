import Combine
import Foundation
import Network
import UIKit

enum ConnectionPhase: Equatable {
    case idle
    case searching
    case connecting
    case connected
    case failed(String)
}

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Discovers nearby Macs and keeps every observable mutation on the main actor.
/// A transport connection is useful only after the paired Mac sends a valid state.
@MainActor
final class CompanionClient: ObservableObject {
    @Published private(set) var devices: [DiscoveredMac] = []
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var snapshot: BridgeSnapshot?
    @Published var errorMessage: String?
    @Published private(set) var feedback: String?
    @Published private(set) var isDemo = false
    @Published var selectedWindowID: UInt32?

    var isConnected: Bool { phase == .connected && !isDemo }
    var capabilities: BridgeCapabilities { snapshot?.capabilities ?? .none }
    var hasPairingToForget: Bool {
        guard let mac = selectedMac else { return false }
        return pairingCode != nil || hasSavedPairing(for: mac)
    }

    private static let deviceIDKey = "ShowBarCompanion.deviceID"
    var deviceID: String {
        if let stored = UserDefaults.standard.string(forKey: Self.deviceIDKey), !stored.isEmpty {
            return stored
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: Self.deviceIDKey)
        return newID
    }

    private struct PendingRequest {
        let action: BridgeCommand.Action
        let completion: ((Data?) -> Void)?
        let timeout: Task<Void, Never>
    }

    private let networkQueue = DispatchQueue(label: "com.naoryanko.showbar.companion.network")
    private let keychainService = "com.naoryanko.showbar.companion.pairing"
    private var browser: NWBrowser?
    private var browserGeneration = UUID()
    private var connection: NWConnection?
    private var connectionGeneration = UUID()
    private var decoder = BridgeFrameDecoder()
    private var selectedMac: DiscoveredMac?
    private var pairingCode: String?
    private var pending: [String: PendingRequest] = [:]
    private var handshakeTimeout: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var lastReceived = Date()
    private var active = true
    private var discoveryRequested = false
    private var shouldReconnect = false

    func startDiscovery() {
        discoveryRequested = true
        guard active, browser == nil, !isDemo else { return }
        let generation = UUID()
        browserGeneration = generation
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_showbar._tcp", domain: nil), using: parameters)
        self.browser = browser
        if connection == nil { phase = .searching }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.browserGeneration == generation else { return }
                switch state {
                case .failed(let error):
                    self.browser?.cancel()
                    self.browser = nil
                    if self.connection == nil {
                        let message = Self.discoveryError(error)
                        self.phase = .failed(message)
                        self.errorMessage = message
                    }
                case .waiting(let error):
                    if self.connection == nil {
                        self.errorMessage = Self.discoveryError(error)
                    }
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredMac? in
                guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                return DiscoveredMac(id: "\(name)|\(type)|\(domain)", name: name, endpoint: result.endpoint)
            }
            Task { @MainActor [weak self] in
                guard let self, self.browserGeneration == generation else { return }
                var unique: [String: DiscoveredMac] = [:]
                found.forEach { unique[$0.id] = $0 }
                self.devices = unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if let selected = self.selectedMac,
                   let refreshed = self.devices.first(where: { $0.id == selected.id }) {
                    self.selectedMac = refreshed
                }
            }
        }
        browser.start(queue: networkQueue)
    }

    func stopDiscovery() {
        browserGeneration = UUID()
        browser?.cancel()
        browser = nil
        devices = []
        if connection == nil, !isDemo { phase = .idle }
    }

    func hasSavedPairing(for mac: DiscoveredMac) -> Bool {
        guard let stored = try? BridgeKeychain.load(service: keychainService, account: mac.id) else { return false }
        return BridgePairingCode.isValid(stored)
    }

    /// An empty entry reuses the secret saved for this exact Bonjour service.
    func connect(to mac: DiscoveredMac, pairingCode enteredCode: String) {
        let entered = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code: String
        do {
            code = entered.isEmpty
                ? (try BridgeKeychain.load(service: keychainService, account: mac.id) ?? "")
                : entered
        } catch {
            errorMessage = "The saved pairing could not be read. Enter the code shown on your Mac."
            return
        }
        guard BridgePairingCode.isValid(code) else {
            errorMessage = "Enter the complete pairing code from Show Bar → Companion devices on your Mac."
            return
        }
        disconnect()
        isDemo = false
        selectedMac = mac
        pairingCode = BridgePairingCode.normalized(code)
        shouldReconnect = true
        reconnectAttempts = 0
        errorMessage = nil
        feedback = nil
        openConnection()
    }

    func disconnect() {
        shouldReconnect = false
        reconnect?.cancel()
        reconnect = nil
        cancelConnection()
        isDemo = false
        phase = .idle
    }

    func forgetPairing() {
        let mac = selectedMac
        disconnect()
        if let mac {
            do {
                try BridgeKeychain.delete(service: keychainService, account: mac.id)
                feedback = "Saved pairing removed."
            } catch {
                errorMessage = "The saved pairing could not be removed. Try again while the device is unlocked."
                return
            }
        }
        selectedMac = nil
        pairingCode = nil
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        guard !isDemo else { return }
        if active {
            if discoveryRequested { startDiscovery() }
            if shouldReconnect, !isDemo, selectedMac != nil {
                reconnectAttempts = 0
                openConnection()
            }
        } else {
            reconnect?.cancel()
            reconnect = nil
            stopDiscovery()
            cancelConnection()
            if !isDemo { phase = .idle }
        }
    }

    func refresh() { sendCommand(BridgeCommand(action: .refresh)) }

    func focus(_ window: BridgeWindow) {
        selectedWindowID = window.id
        sendCommand(BridgeCommand(action: .focus, windowID: window.id))
    }

    func close(_ window: BridgeWindow) {
        sendCommand(BridgeCommand(action: .close, windowID: window.id))
    }

    func snap(_ zone: String) {
        guard let id = selectedWindowID else {
            errorMessage = "Choose a Mac window first."
            return
        }
        sendCommand(BridgeCommand(action: .snap, windowID: id, zone: zone))
    }

    func sendText(_ text: String, paste: Bool) {
        guard !text.isEmpty, text.utf8.count <= 200_000 else {
            errorMessage = "Choose some text smaller than 200 KB to send."
            return
        }
        guard !paste || selectedWindowID != nil else {
            errorMessage = "Choose the Mac window that should receive the paste."
            return
        }
        sendCommand(BridgeCommand(action: paste ? .pasteToMac : .copyToMac,
                                  windowID: paste ? selectedWindowID : nil, text: text))
    }

    func requestShot(_ id: String, completion: @escaping (Data?) -> Void) {
        sendCommand(BridgeCommand(action: .requestShot, shotID: id), completion: completion)
    }

    func requestClipImage(_ id: String, completion: @escaping (Data?) -> Void) {
        sendCommand(BridgeCommand(action: .requestClipImage, clipID: id), completion: completion)
    }

    /// Leaving an image shelf releases awaiting image consumers quietly.
    /// Window and clipboard actions retain their own acknowledgement timeouts.
    func cancelAssetRequests() {
        let ids = pending.compactMap { $0.value.completion != nil ? $0.key : nil }
        let requests = ids.compactMap { pending.removeValue(forKey: $0) }
        for request in requests {
            request.timeout.cancel()
            request.completion?(nil)
        }
    }

    func cancelShotRequests() { cancelAssetRequests() }

    func clearError() { errorMessage = nil }

    func loadDemo() {
        disconnect()
        stopDiscovery()
        isDemo = true
        snapshot = BridgeSnapshot(
            hostName: "Demo Mac · sample content",
            windows: [
                BridgeWindow(id: 101, pid: 1, title: "Show Bar Companion", appName: "Xcode", isCurrent: true),
                BridgeWindow(id: 102, pid: 2, title: "Ideas for today", appName: "Notes", isCurrent: true),
                BridgeWindow(id: 103, pid: 3, title: "Apple Developer", appName: "Safari", isCurrent: true)
            ],
            clips: [
                BridgeClip(id: "demo-link", kind: "link", text: "https://developer.apple.com", date: Date()),
                BridgeClip(id: "demo-text", kind: "text", text: "A little less switching. A little more doing.", date: Date()),
                BridgeClip(id: "demo-color", kind: "text", text: "#D6F56A", date: Date())
            ], shots: [], permissions: BridgePermissions(accessibility: true, screenRecording: true),
            capabilities: .all
        )
        selectedWindowID = 101
        feedback = "Demo uses sample content. Connect to your Mac to control real windows."
        errorMessage = nil
    }

    private func openConnection() {
        guard active, shouldReconnect, let mac = selectedMac, let code = pairingCode else { return }
        cancelConnection()
        let parameters: NWParameters
        do {
            parameters = try BridgeTransport.parameters(pairingCode: code)
        } catch {
            fail("This pairing code is invalid. Copy a new code from your Mac.", allowReconnect: false)
            return
        }
        phase = .connecting
        let generation = connectionGeneration
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                switch state {
                case .ready:
                    self.lastReceived = Date()
                    self.send(BridgeMessage(kind: .hello, deviceName: UIDevice.current.name, deviceID: self.deviceID), generation: generation)
                    self.receiveNext(generation: generation)
                case .failed(let error):
                    self.fail(Self.connectionError(error), allowReconnect: !Self.isAuthenticationError(error))
                case .waiting(let error):
                    self.errorMessage = Self.connectionError(error)
                case .cancelled:
                    self.fail("The Mac disconnected. Check that Companion devices is still enabled.", allowReconnect: true)
                default:
                    break
                }
            }
        }
        handshakeTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.connectionGeneration == generation, !self.isConnected else { return }
            self.fail("The Mac did not respond. Check the pairing code, local network permission, and that both devices use the same network.", allowReconnect: true)
        }
        connection.start(queue: networkQueue)
    }

    private func receiveNext(generation: UUID) {
        guard let connection, connectionGeneration == generation else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try self.decoder.append(data) {
                            self.lastReceived = Date()
                            self.handle(message, generation: generation)
                            guard self.connectionGeneration == generation else { return }
                        }
                    } catch BridgeProtocolError.unsupportedVersion {
                        self.fail("These versions of Show Bar cannot connect. Update the Mac and companion apps.", allowReconnect: false)
                        return
                    } catch {
                        self.fail("The Mac sent an unreadable or oversized response. Update Show Bar on both devices.", allowReconnect: false)
                        return
                    }
                }
                if let error {
                    self.fail(Self.connectionError(error), allowReconnect: !Self.isAuthenticationError(error))
                } else if complete {
                    self.fail("The Mac closed the connection. Check that Companion devices is enabled.", allowReconnect: true)
                } else {
                    self.receiveNext(generation: generation)
                }
            }
        }
    }

    private func handle(_ message: BridgeMessage, generation: UUID) {
        guard message.version == BridgeMessage.currentVersion else {
            fail("These versions of Show Bar cannot connect. Update the Mac and companion apps.", allowReconnect: false)
            return
        }
        switch message.kind {
        case .hello:
            break
        case .state:
            guard let state = message.snapshot else {
                fail("The Mac sent an incomplete state. Update Show Bar on your Mac.", allowReconnect: false)
                return
            }
            snapshot = filteredSnapshot(state)
            cancelRevokedRequests()
            if let selected = selectedWindowID, !state.windows.contains(where: { $0.id == selected }) {
                selectedWindowID = nil
            }
            if phase != .connected {
                phase = .connected
                errorMessage = nil
                reconnectAttempts = 0
                handshakeTimeout?.cancel()
                handshakeTimeout = nil
                savePairing()
                beginHeartbeat(generation: generation)
            }
        case .result:
            guard let id = message.requestID, let request = pending.removeValue(forKey: id) else { return }
            request.timeout.cancel()
            guard let result = message.result else {
                errorMessage = "The Mac returned an incomplete reply. Try again."
                request.completion?(nil)
                return
            }
            if result.success {
                if request.completion != nil,
                   result.data?.isEmpty != false || !["image/png", "image/jpeg"].contains(result.mimeType ?? "") {
                    errorMessage = "The image could not be received. Refresh its shelf and try again."
                    request.completion?(nil)
                    return
                }
                feedback = result.message
                request.completion?(result.data)
            } else {
                errorMessage = result.message
                request.completion?(nil)
            }
        case .ping:
            send(BridgeMessage(kind: .pong, requestID: message.requestID), generation: generation)
        case .pong:
            break
        case .command:
            fail("The Mac sent an unexpected message. Update Show Bar on both devices.", allowReconnect: false)
        }
    }

    private func sendCommand(_ command: BridgeCommand, completion: ((Data?) -> Void)? = nil) {
        guard isConnected else {
            errorMessage = isDemo ? "Connect to your Mac to use this control. Demo content is read-only." : "Connect to your Mac first."
            completion?(nil)
            return
        }
        guard capabilities.permits(command.action) else {
            errorMessage = capabilityError(for: command.action)
            completion?(nil)
            return
        }
        guard pending.count < 24 else {
            errorMessage = "Your Mac is still processing the previous actions. Try again in a moment."
            completion?(nil)
            return
        }
        let id = UUID().uuidString
        let generation = connectionGeneration
        let timeout = Task { [weak self] in
            let seconds: UInt64 = command.action == .requestShot || command.action == .requestClipImage ? 20 : 10
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self, self.connectionGeneration == generation,
                  let request = self.pending.removeValue(forKey: id) else { return }
            self.errorMessage = "The Mac did not confirm the action. Refresh before trying again."
            request.completion?(nil)
        }
        pending[id] = PendingRequest(action: command.action, completion: completion, timeout: timeout)
        send(BridgeMessage(kind: .command, requestID: id, command: command), generation: generation)
    }

    private func filteredSnapshot(_ state: BridgeSnapshot) -> BridgeSnapshot {
        let allowed = state.capabilities ?? .none
        var filtered = state
        if !allowed.shareClipboard {
            filtered.clips = []
        } else if !allowed.shareClipboardImages {
            filtered.clips.removeAll { $0.kind == "image" }
        }
        if !allowed.shareScreenshots { filtered.shots = [] }
        if !allowed.shareWindowPreviews {
            filtered.windows = filtered.windows.map { window in
                var filtered = window
                filtered.thumbnail = nil
                return filtered
            }
        }
        return filtered
    }

    private func cancelRevokedRequests() {
        let ids = pending.compactMap { !capabilities.permits($0.value.action) ? $0.key : nil }
        let requests = ids.compactMap { pending.removeValue(forKey: $0) }
        for request in requests {
            request.timeout.cancel()
            request.completion?(nil)
        }
    }

    private func capabilityError(for action: BridgeCommand.Action) -> String {
        guard snapshot?.capabilities != nil else {
            return "Update Show Bar on your Mac to manage companion permissions."
        }
        switch action {
        case .focus: return "Enable window focusing in Show Bar → Companion devices on your Mac."
        case .snap: return "Enable window arrangement in Show Bar → Companion devices on your Mac."
        case .close: return "Enable closing windows in Show Bar → Companion devices on your Mac."
        case .copyToMac: return "Enable Copy to Mac in Show Bar → Companion devices on your Mac."
        case .pasteToMac: return "Enable Paste to Mac in Show Bar → Companion devices on your Mac."
        case .requestShot: return "Enable screenshot sharing in Show Bar → Companion devices on your Mac."
        case .requestClipImage:
            return "Enable clipboard sharing and clipboard images in Show Bar → Companion devices on your Mac."
        case .refresh: return "Refresh is unavailable. Reconnect to your Mac and try again."
        }
    }

    private func send(_ message: BridgeMessage, generation: UUID) {
        guard let connection, connectionGeneration == generation else { return }
        do {
            let frame = try message.encodedFrame()
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.fail(Self.connectionError(error), allowReconnect: !Self.isAuthenticationError(error))
                }
            })
        } catch {
            fail("This action could not be sent because its data is too large or invalid.", allowReconnect: false)
        }
    }

    private func beginHeartbeat(generation: UUID) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, self.connectionGeneration == generation, self.isConnected else { return }
                if Date().timeIntervalSince(self.lastReceived) > 45 {
                    self.fail("The Mac stopped responding. Reconnecting…", allowReconnect: true)
                    return
                }
                self.send(BridgeMessage(kind: .ping), generation: generation)
            }
        }
    }

    private func savePairing() {
        guard let mac = selectedMac, let code = pairingCode else { return }
        do {
            try BridgeKeychain.save(code, service: keychainService, account: mac.id)
        } catch {
            feedback = "Connected. The pairing could not be saved; you may need to enter the code next time."
        }
    }

    private func cancelConnection() {
        connectionGeneration = UUID()
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        heartbeat?.cancel()
        heartbeat = nil
        connection?.cancel()
        connection = nil
        // Consumers may synchronously react to their cancelled screenshot.
        // Mark the transport unavailable before invoking any of those callbacks.
        phase = .idle
        decoder = BridgeFrameDecoder()
        snapshot = nil
        selectedWindowID = nil
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.completion?(nil)
        }
    }

    private func fail(_ message: String, allowReconnect: Bool) {
        cancelConnection()
        errorMessage = message
        phase = .failed(message)
        guard allowReconnect, shouldReconnect, active, !isDemo, reconnectAttempts < 3 else {
            if !allowReconnect { shouldReconnect = false }
            return
        }
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let macID = selectedMac?.id
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 1_000_000_000) } catch { return }
            guard let self, self.shouldReconnect, self.active, self.selectedMac?.id == macID else { return }
            self.openConnection()
        }
    }

    private static func discoveryError(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 || code == -65555 {
            return "Allow Local Network access in Settings → Privacy & Security → Local Network, then search again."
        }
        return "Nearby Macs could not be found. Check Local Network permission, Wi-Fi, and Companion devices on your Mac."
    }

    private static func isAuthenticationError(_ error: NWError) -> Bool {
        if case .tls = error { return true }
        return false
    }

    private static func connectionError(_ error: NWError) -> String {
        if isAuthenticationError(error) {
            return "Pairing was rejected. Enter the current code from Companion devices on your Mac."
        }
        return "The Mac is unreachable. Keep both devices on the same network and enable Companion devices on your Mac."
    }
}
