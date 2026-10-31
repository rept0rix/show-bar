import AppKit
import ApplicationServices
import Foundation
import Network
import SwiftUI
import Darwin

/// Opt-in, paired LAN control. Transport state lives on `queue`; AppKit,
/// preferences and published UI state are only touched on the main thread.
final class RemoteBridge: ObservableObject, @unchecked Sendable {
    static let shared = RemoteBridge()
    private static let enabledKey = "ShowBar.companion.enabled"
    private static let clipsKey = "ShowBar.companion.shareClipboard"
    private static let shotsKey = "ShowBar.companion.shareScreenshots"
    private static let previewsKey = "ShowBar.companion.shareWindowPreviews"
    private static let clipImagesKey = "ShowBar.companion.shareClipboardImages"
    private static let pairedDevicesKey = "ShowBar.companion.pairedDevices"
    private let keychainService = "com.naoryanko.showbar.companion"
    private let keychainAccount = "pairing-v1"

    struct PairedDevice: Identifiable, Codable, Equatable {
        let id: String
        var name: String
        var firstSeen: Date
        var lastSeen: Date
        var isRevoked: Bool
        var customCapabilities: BridgeCapabilities?

        init(id: String, name: String, firstSeen: Date = Date(), lastSeen: Date = Date(),
             isRevoked: Bool = false, customCapabilities: BridgeCapabilities? = nil) {
            self.id = id; self.name = name; self.firstSeen = firstSeen
            self.lastSeen = lastSeen; self.isRevoked = isRevoked
            self.customCapabilities = customCapabilities
        }
    }

    struct ConnectedDevice: Identifiable {
        let id: UUID
        let deviceID: String
        let name: String
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var shareClipboard: Bool
    @Published private(set) var shareScreenshots: Bool
    @Published private(set) var shareWindowPreviews: Bool
    @Published private(set) var shareClipboardImages: Bool
    @Published private(set) var allowFocus: Bool
    @Published private(set) var allowSnap: Bool
    @Published private(set) var allowClose: Bool
    @Published private(set) var allowCopyToMac: Bool
    @Published private(set) var allowPasteToMac: Bool
    @Published private(set) var pairingCode = ""
    @Published private(set) var status = "Companion is off"
    @Published private(set) var connectedCount = 0
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    @Published private(set) var pairedDevices: [PairedDevice] = []

    private let pairedDevicesLock = NSLock()
    private var cachedPairedDevices: [PairedDevice] = []

    var capabilities: BridgeCapabilities {
        if isolatedTestHost { return .none }
        return BridgeCapabilities(allowFocus: allowFocus, allowSnap: allowSnap,
                                  allowClose: allowClose, allowCopyToMac: allowCopyToMac,
                                  allowPasteToMac: allowPasteToMac,
                                  shareClipboard: shareClipboard,
                                  shareClipboardImages: shareClipboard && shareClipboardImages,
                                  shareWindowPreviews: shareWindowPreviews,
                                  shareScreenshots: shareScreenshots)
    }

    private let queue = DispatchQueue(label: "com.naoryanko.showbar.companion", qos: .utility)
    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var snapshotPending = false
    private var panel: NSWindow?
    private var lastThumbnailRefresh = Date.distantPast
    private var refreshingThumbnails = false
    private let commandAuthorization = AuthorizationEpoch()
    private let sharingAuthorization = AuthorizationEpoch()
    private let isolatedTestHost: Bool
    #if DEBUG
    private var testPairingCode: String?
    private static var testInstance: RemoteBridge?
    #endif

    /// Revocation takes effect immediately on the calling thread, including for
    /// work already queued between the network queue and the main run loop.
    private final class AuthorizationEpoch {
        private let lock = NSLock()
        private var value = UUID()
        func token() -> UUID { lock.lock(); defer { lock.unlock() }; return value }
        func invalidate() { lock.lock(); value = UUID(); lock.unlock() }
        func matches(_ token: UUID) -> Bool { self.token() == token }
    }

    private final class Session {
        let id = UUID()
        let connection: NWConnection
        let authorization: UUID
        private let validityLock = NSLock()
        private var active = true
        var decoder = BridgeFrameDecoder()
        var ready = false
        var deviceID = ""
        var deviceName = "Companion"
        var lastReceived = Date()
        var commandWindow = Date()
        var commandCount = 0
        var pending: [PendingPacket] = []
        var pendingState: PendingPacket?
        var sending = false
        var lastShotRequest = Date.distantPast
        init(_ connection: NWConnection, authorization: UUID) {
            self.connection = connection; self.authorization = authorization
        }
        func invalidate() { validityLock.lock(); active = false; validityLock.unlock() }
        var isActive: Bool { validityLock.lock(); defer { validityLock.unlock() }; return active }
    }

    private struct PendingPacket {
        let data: Data
        let sharingEpoch: UUID?
        let revokedResult: BridgeMessage?
    }

    private init() {
        isolatedTestHost = false
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        shareClipboard = UserDefaults.standard.bool(forKey: Self.clipsKey)
        shareScreenshots = UserDefaults.standard.bool(forKey: Self.shotsKey)
        shareWindowPreviews = UserDefaults.standard.bool(forKey: Self.previewsKey)
        shareClipboardImages = UserDefaults.standard.bool(forKey: Self.clipImagesKey)
        allowFocus = Self.actionPreference("allowFocus", fallback: true)
        allowSnap = Self.actionPreference("allowSnap", fallback: true)
        allowClose = Self.actionPreference("allowClose", fallback: false)
        allowCopyToMac = Self.actionPreference("allowCopyToMac", fallback: false)
        allowPasteToMac = Self.actionPreference("allowPasteToMac", fallback: false)
        if let data = UserDefaults.standard.data(forKey: Self.pairedDevicesKey),
           let saved = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            cachedPairedDevices = saved
            pairedDevices = saved
        } else {
            cachedPairedDevices = []
            pairedDevices = []
        }
    }

    private func savePairedDevices(_ list: [PairedDevice]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.pairedDevicesKey)
        }
    }

    private func recordDeviceSeen(id: String, name: String) {
        pairedDevicesLock.lock()
        var current = cachedPairedDevices
        if let idx = current.firstIndex(where: { $0.id == id }) {
            current[idx].name = name
            current[idx].lastSeen = Date()
        } else {
            current.append(PairedDevice(id: id, name: name, firstSeen: Date(), lastSeen: Date()))
        }
        cachedPairedDevices = current
        pairedDevicesLock.unlock()
        savePairedDevices(current)
        DispatchQueue.main.async { self.pairedDevices = current }
    }

    func isDeviceRevoked(_ id: String) -> Bool {
        pairedDevicesLock.lock()
        defer { pairedDevicesLock.unlock() }
        return cachedPairedDevices.first(where: { $0.id == id })?.isRevoked ?? false
    }

    func effectiveCapabilities(for deviceID: String) -> BridgeCapabilities {
        if isolatedTestHost { return .none }
        pairedDevicesLock.lock()
        let device = cachedPairedDevices.first(where: { $0.id == deviceID })
        pairedDevicesLock.unlock()
        if let device {
            if device.isRevoked { return .none }
            if let custom = device.customCapabilities {
                return BridgeCapabilities(
                    allowFocus: allowFocus && custom.allowFocus,
                    allowSnap: allowSnap && custom.allowSnap,
                    allowClose: allowClose && custom.allowClose,
                    allowCopyToMac: allowCopyToMac && custom.allowCopyToMac,
                    allowPasteToMac: allowPasteToMac && custom.allowPasteToMac,
                    shareClipboard: shareClipboard && custom.shareClipboard,
                    shareClipboardImages: shareClipboard && shareClipboardImages && custom.shareClipboardImages,
                    shareWindowPreviews: shareWindowPreviews && custom.shareWindowPreviews,
                    shareScreenshots: shareScreenshots && custom.shareScreenshots
                )
            }
        }
        return capabilities
    }

    func revokeDevice(id: String) {
        pairedDevicesLock.lock()
        var current = cachedPairedDevices
        if let idx = current.firstIndex(where: { $0.id == id }) {
            current[idx].isRevoked = true
        } else {
            current.append(PairedDevice(id: id, name: "Companion", isRevoked: true))
        }
        cachedPairedDevices = current
        pairedDevicesLock.unlock()
        savePairedDevices(current)
        DispatchQueue.main.async { self.pairedDevices = current }
        queue.async {
            for session in Array(self.sessions.values) where session.deviceID == id {
                self.remove(session)
            }
        }
    }

    func unrevokeDevice(id: String) {
        pairedDevicesLock.lock()
        var current = cachedPairedDevices
        if let idx = current.firstIndex(where: { $0.id == id }) {
            current[idx].isRevoked = false
        }
        cachedPairedDevices = current
        pairedDevicesLock.unlock()
        savePairedDevices(current)
        DispatchQueue.main.async { self.pairedDevices = current }
    }

    func removePairedDevice(id: String) {
        pairedDevicesLock.lock()
        var current = cachedPairedDevices
        current.removeAll { $0.id == id }
        cachedPairedDevices = current
        pairedDevicesLock.unlock()
        savePairedDevices(current)
        DispatchQueue.main.async { self.pairedDevices = current }
        queue.async {
            for session in Array(self.sessions.values) where session.deviceID == id {
                self.remove(session)
            }
        }
    }

    func disconnectSession(sessionID: UUID) {
        queue.async {
            if let session = self.sessions[sessionID] {
                self.remove(session)
            }
        }
    }

    func setCustomCapabilities(for id: String, capabilities: BridgeCapabilities?) {
        pairedDevicesLock.lock()
        var current = cachedPairedDevices
        if let idx = current.firstIndex(where: { $0.id == id }) {
            current[idx].customCapabilities = capabilities
        }
        cachedPairedDevices = current
        pairedDevicesLock.unlock()
        savePairedDevices(current)
        DispatchQueue.main.async { self.pairedDevices = current }
        settingsDidChange()
    }

    private static func actionPreference(_ name: String, fallback: Bool) -> Bool {
        let key = "ShowBar.companion." + name
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    #if DEBUG
    private init(testCode: String) {
        isolatedTestHost = true
        enabled = true
        shareClipboard = false
        shareScreenshots = false
        shareWindowPreviews = false
        shareClipboardImages = false
        allowFocus = false
        allowSnap = false
        allowClose = false
        allowCopyToMac = false
        allowPasteToMac = false
        testPairingCode = testCode
        cachedPairedDevices = []
        pairedDevices = []
    }

    /// Used by the integration harness only. Bypasses the normal app lifecycle,
    /// persistent preferences, Keychain, Bonjour, capture and all Mac mutations.
    static func runIsolatedTestHost() -> Never {
        guard let code = ProcessInfo.processInfo.environment["SHOWBAR_COMPANION_TEST_CODE"],
              BridgePairingCode.isValid(code) else {
            fputs("Provide a valid SHOWBAR_COMPANION_TEST_CODE.\n", stderr)
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = RemoteBridge(testCode: code)
        testInstance = host
        host.start()
        NSApplication.shared.run()
        exit(0)
    }
    #endif

    func start() {
        guard enabled else { return }
        #if DEBUG
        if let code = testPairingCode {
            queue.async { self.startListener(code: code) }
            return
        }
        #endif
        do {
            try ensurePairingCode()
            let code = pairingCode
            queue.async { self.startListener(code: code) }
        } catch {
            status = "Could not access the pairing key. Try again from Companion devices."
        }
    }

    func stop() {
        commandAuthorization.invalidate()
        queue.async { self.stopListener() }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if value { start() } else { stop(); status = "Companion is off" }
    }

    func setShareClipboard(_ value: Bool) {
        shareClipboard = value
        UserDefaults.standard.set(value, forKey: Self.clipsKey)
        settingsDidChange()
    }

    func setShareScreenshots(_ value: Bool) {
        shareScreenshots = value
        UserDefaults.standard.set(value, forKey: Self.shotsKey)
        settingsDidChange()
    }

    func setShareWindowPreviews(_ value: Bool) {
        shareWindowPreviews = value
        UserDefaults.standard.set(value, forKey: Self.previewsKey)
        settingsDidChange()
    }

    func setShareClipboardImages(_ value: Bool) {
        shareClipboardImages = value
        UserDefaults.standard.set(value, forKey: Self.clipImagesKey)
        settingsDidChange()
    }

    func setAllowFocus(_ value: Bool) { allowFocus = value; saveActionSetting("allowFocus", value) }
    func setAllowSnap(_ value: Bool) { allowSnap = value; saveActionSetting("allowSnap", value) }
    func setAllowClose(_ value: Bool) { allowClose = value; saveActionSetting("allowClose", value) }
    func setAllowCopyToMac(_ value: Bool) { allowCopyToMac = value; saveActionSetting("allowCopyToMac", value) }
    func setAllowPasteToMac(_ value: Bool) { allowPasteToMac = value; saveActionSetting("allowPasteToMac", value) }

    private func saveActionSetting(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "ShowBar.companion." + name)
        settingsDidChange()
    }

    private func settingsDidChange() {
        sharingAuthorization.invalidate()
        queue.async { self.discardQueuedSnapshots(); self.publishSnapshot() }
    }

    func disconnectAll() {
        // This closes current sessions; it deliberately does not claim to revoke
        // the shared pairing credential. Reset pairing revokes that credential.
        commandAuthorization.invalidate()
        queue.async {
            for session in Array(self.sessions.values) { self.remove(session) }
        }
    }

    func rotatePairingCode() {
        do {
            let code = BridgePairingCode.generate()
            try BridgeKeychain.save(code, service: keychainService, account: keychainAccount)
            pairingCode = code
            commandAuthorization.invalidate()
            let restart = enabled
            queue.async {
                self.stopListener()
                if restart { self.startListener(code: code) }
            }
            status = enabled ? "Starting with a new pairing code…" : "Companion is off"
        } catch {
            status = "Could not save a new pairing key. Existing pairing was kept."
        }
    }

    private func ensurePairingCode() throws {
        if !pairingCode.isEmpty { return }
        if let stored = try BridgeKeychain.load(service: keychainService, account: keychainAccount),
           BridgePairingCode.isValid(stored) {
            pairingCode = stored
        } else {
            let code = BridgePairingCode.generate()
            try BridgeKeychain.save(code, service: keychainService, account: keychainAccount)
            pairingCode = code
        }
    }

    func showPairing() {
        do { try ensurePairingCode() } catch { status = "Keychain access is required to pair a device." }
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Companion devices"
            window.minSize = NSSize(width: 480, height: 440)
            window.contentView = NSHostingView(rootView: CompanionPairingView(bridge: self))
            window.isReleasedWhenClosed = false
            window.center()
            panel = window
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func startListener(code: String) {
        guard listener == nil else { return }
        do {
            let params = try BridgeTransport.parameters(pairingCode: code)
            if isolatedTestHost {
                params.includePeerToPeer = false
                params.requiredInterfaceType = .loopback
            }
            let server = try NWListener(using: params, on: .any)
            let epoch = UUID()
            generation = epoch
            if !isolatedTestHost {
                server.service = NWListener.Service(name: "Show Bar — \(Host.current().localizedName ?? "Mac")", type: "_showbar._tcp")
            }
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self, self.generation == epoch else { return }
                switch state {
                case .ready:
                    #if DEBUG
                    if self.isolatedTestHost, let port = server?.port {
                        print("SHOWBAR_TEST_PORT=\(port.rawValue)")
                        fflush(stdout)
                    }
                    #endif
                    self.updateStatus("Ready to pair on your local network")
                case .failed:
                    self.stopListener()
                    self.updateStatus("Could not start. Check Local Network permission and try enabling Companion again.")
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == epoch else { connection.cancel(); return }
                self.accept(connection)
            }
            listener = server
            // resource: idle 3 — no timer exists until LAN companion is enabled;
            // snapshots and ScreenCaptureKit work run only with paired clients.
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now() + 3, repeating: 3)
            clock.setEventHandler { [weak self] in self?.tick() }
            timer = clock
            clock.resume()
            server.start(queue: queue)
        } catch {
            updateStatus("Could not start the encrypted connection. Try enabling Companion again.")
        }
    }

    private func stopListener() {
        generation = UUID()
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        for session in sessions.values { session.invalidate(); session.connection.cancel() }
        sessions.removeAll()
        snapshotPending = false
        DispatchQueue.main.async { self.connectedCount = 0; self.connectedDevices = [] }
    }

    private func updateStatus(_ value: String) {
        DispatchQueue.main.async { self.status = self.enabled ? value : "Companion is off" }
    }

    private func accept(_ connection: NWConnection) {
        guard sessions.count < 3 else { connection.cancel(); return }
        let session = Session(connection, authorization: commandAuthorization.token())
        sessions[session.id] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session, self.sessions[session.id] != nil else { return }
            switch state {
            case .ready: self.receive(session)
            case .failed, .cancelled: self.remove(session)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ session: Session) {
        session.invalidate()
        sessions.removeValue(forKey: session.id)
        session.connection.cancel()
        publishConnectedDevices()
    }

    private func publishConnectedDevices() {
        let devices = sessions.values.filter(\.ready).map { ConnectedDevice(id: $0.id, deviceID: $0.deviceID, name: $0.deviceName) }
            .sorted { $0.name < $1.name }
        let count = devices.count
        DispatchQueue.main.async {
            self.connectedCount = count
            self.connectedDevices = devices
            if self.enabled { self.status = count == 0 ? "Ready to pair on your local network" : "\(count) device\(count == 1 ? "" : "s") connected" }
        }
    }

    private static func safeDeviceName(_ raw: String?) -> String {
        let scalars = (raw ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Companion" : String(trimmed.prefix(60))
    }

    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak session] data, _, complete, error in
            guard let self, let session, self.sessions[session.id] != nil else { return }
            do {
                if let data, !data.isEmpty {
                    for message in try session.decoder.append(data) {
                        guard self.sessions[session.id] != nil else { break }
                        self.process(message, session: session)
                    }
                }
            } catch { self.remove(session); return }
            if complete || error != nil { self.remove(session) } else { self.receive(session) }
        }
    }

    private func process(_ message: BridgeMessage, session: Session) {
        guard message.version == BridgeMessage.currentVersion else { remove(session); return }
        session.lastReceived = Date()
        if !session.ready {
            guard message.kind == .hello else { remove(session); return }
            let rawID = message.deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceID = (rawID?.isEmpty == false) ? rawID! : session.id.uuidString
            if self.isDeviceRevoked(deviceID) {
                remove(session)
                return
            }
            session.ready = true
            session.deviceID = deviceID
            session.deviceName = Self.safeDeviceName(message.deviceName)
            recordDeviceSeen(id: deviceID, name: session.deviceName)
            publishConnectedDevices()
            send(BridgeMessage(kind: .hello, deviceName: isolatedTestHost ? "Show Bar Test Host" : (Host.current().localizedName ?? "Mac")), to: session)
            publishSnapshot()
            return
        }
        if message.kind == .ping { send(BridgeMessage(kind: .pong, requestID: message.requestID), to: session); return }
        guard message.kind == .command, let command = message.command else { return }
        if Date().timeIntervalSince(session.commandWindow) >= 1 {
            session.commandWindow = Date(); session.commandCount = 0
        }
        session.commandCount += 1
        guard session.commandCount <= 12 else { remove(session); return }
        if command.action == .requestShot || command.action == .requestClipImage {
            guard Date().timeIntervalSince(session.lastShotRequest) >= 1 else {
                send(BridgeMessage(kind: .result, requestID: message.requestID,
                                   result: BridgeResult(success: false, message: "Wait a moment before downloading another image.")), to: session)
                return
            }
            session.lastShotRequest = Date()
        }
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, self.enabled, session.isActive,
                  self.commandAuthorization.matches(session.authorization) else { return }
            self.execute(command, requestID: message.requestID, session: session)
        }
    }

    private func tick() {
        let now = Date()
        for session in Array(sessions.values) {
            if now.timeIntervalSince(session.lastReceived) > (session.ready ? 90 : 12) { remove(session) }
        }
        publishSnapshot()
    }

    private func publishSnapshot() {
        guard !snapshotPending, sessions.values.contains(where: \.ready) else { return }
        snapshotPending = true
        let epoch = generation
        let sharingEpoch = sharingAuthorization.token()
        DispatchQueue.main.async {
            let capabilities = self.capabilities
            let screenRecording = self.isolatedTestHost ? false : CGPreflightScreenCaptureAccess()
            let allowShots = capabilities.shareScreenshots
            let allowPreviews = capabilities.shareWindowPreviews && screenRecording
            let cards = self.isolatedTestHost ? [] : Array(WindowCatalog.switcherCards().prefix(40))
            let windows = cards.map { card in
                BridgeWindow(id: card.id, pid: card.pid, title: String(card.title.prefix(512)),
                             appName: NSRunningApplication(processIdentifier: card.pid)?.localizedName ?? "App",
                             isCurrent: card.isCurrent,
                             thumbnail: allowPreviews ? ThumbnailCache.shared.get(card.id).flatMap {
                                ShotShelf.companionJPEG($0, longestEdge: 360, quality: 0.6)
                             } : nil)
            }
            let clips = capabilities.shareClipboard ? ClipboardShelf.shared.clips.prefix(20).filter {
                $0.kind != .image || capabilities.shareClipboardImages
            }.map { clip in
                BridgeClip(id: clip.id.uuidString, kind: clip.kind.rawValue,
                           text: String(clip.text.prefix(8192)), date: clip.date,
                           thumbnail: clip.kind == .image ? ClipboardShelf.shared.companionThumbnail(for: clip) : nil,
                           isTruncated: clip.text.count > 8192)
            } : []
            let snapshot = BridgeSnapshot(hostName: self.isolatedTestHost ? "Show Bar Test Host" : (Host.current().localizedName ?? "Mac"), windows: windows,
                                          clips: clips, shots: allowShots ? ShotShelf.shared.companionShots() : [],
                                          permissions: BridgePermissions(accessibility: self.isolatedTestHost ? false : AXIsProcessTrusted(),
                                                                         screenRecording: screenRecording),
                                          capabilities: capabilities)
            if allowPreviews, !self.refreshingThumbnails,
               Date().timeIntervalSince(self.lastThumbnailRefresh) > 12 {
                self.lastThumbnailRefresh = Date()
                self.refreshingThumbnails = true
                Task {
                    _ = await WindowCatalog.refresh(Array(cards.prefix(8)))
                    await MainActor.run { self.refreshingThumbnails = false }
                }
            }
            self.queue.async {
                self.snapshotPending = false
                guard self.generation == epoch, self.sharingAuthorization.matches(sharingEpoch) else {
                    self.publishSnapshot(); return
                }
                for session in self.sessions.values where session.ready {
                    if self.isDeviceRevoked(session.deviceID) {
                        self.remove(session)
                        continue
                    }
                    let devCaps = self.effectiveCapabilities(for: session.deviceID)
                    var tailored = snapshot
                    tailored.capabilities = devCaps
                    if !devCaps.shareScreenshots { tailored.shots = [] }
                    if !devCaps.shareClipboard { tailored.clips = [] }
                    else if !devCaps.shareClipboardImages {
                        tailored.clips = tailored.clips.filter { $0.kind != "image" }
                    }
                    if !devCaps.shareWindowPreviews {
                        tailored.windows = tailored.windows.map {
                            var w = $0; w.thumbnail = nil; return w
                        }
                    }
                    self.send(BridgeMessage(kind: .state, snapshot: tailored), to: session, isState: true,
                              sharingEpoch: sharingEpoch)
                }
            }
        }
    }

    private func discardQueuedSnapshots() {
        for session in sessions.values { session.pendingState = nil }
    }

    private func execute(_ command: BridgeCommand, requestID: String?, session: Session) {
        let sharingEpoch = sharingAuthorization.token()
        let devCaps = effectiveCapabilities(for: session.deviceID)
        func result(_ success: Bool, _ text: String, data: Data? = nil, mimeType: String? = nil) {
            let response = BridgeMessage(kind: .result, requestID: requestID,
                                         result: BridgeResult(success: success, message: text, data: data, mimeType: mimeType))
            queue.async {
                self.send(response, to: session, sharingEpoch: data == nil ? nil : sharingEpoch)
                self.publishSnapshot()
            }
        }
        guard devCaps.permits(command.action) else {
            result(false, "This action is disabled for your device. Review Companion devices on your Mac.")
            return
        }
        if isolatedTestHost, command.action != .refresh {
            result(false, "Mac changes are disabled in the isolated test host.")
            return
        }
        switch command.action {
        case .refresh:
            queue.async { self.publishSnapshot() }
            result(true, "Updated")
        case .focus, .close, .snap:
            guard AXIsProcessTrusted() else { result(false, "Enable Accessibility for Show Bar on your Mac."); return }
            guard let id = command.windowID,
                  let card = WindowCatalog.switcherCards().first(where: { $0.id == id }) else {
                result(false, "That window is no longer available. Refresh and select another window."); return
            }
            switch command.action {
            case .focus: WindowCatalog.focus(card); result(true, "Window selected")
            case .close: WindowCatalog.close(card); result(true, "Close requested. Your Mac may ask you to save changes.")
            case .snap:
                guard let raw = command.zone, let zone = SnapZone(rawValue: raw) else { result(false, "Choose a supported window layout."); return }
                let ok = WindowSnap.apply(zone, to: card)
                result(ok, ok ? "Window layout requested" : "That window cannot be arranged.")
            default: break
            }
        case .copyToMac, .pasteToMac:
            guard let text = command.text, !text.isEmpty, text.utf8.count <= 200_000 else {
                result(false, "Send text between 1 and 200,000 bytes."); return
            }
            if command.action == .copyToMac {
                let ok = ClipboardShelf.shared.receiveRemoteText(text, paste: false, targetPID: nil)
                result(ok, ok ? "Copied to your Mac" : "Could not copy to your Mac")
                return
            }
            guard AXIsProcessTrusted() else { result(false, "Enable Accessibility to paste into a Mac app."); return }
            guard let id = command.windowID else {
                result(false, "Choose a Mac window before pasting."); return
            }
            guard let target = WindowCatalog.switcherCards().first(where: { $0.id == id }) else {
                result(false, "The selected window is no longer available."); return
            }
            WindowCatalog.focus(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.enabled, session.isActive,
                      self.commandAuthorization.matches(session.authorization) else { return }
                guard self.effectiveCapabilities(for: session.deviceID).permits(.pasteToMac) else {
                    result(false, "Paste permission was turned off on your Mac."); return
                }
                guard WindowSnap.isFocused(target) else {
                    result(false, "The target window changed. Select your window and try again."); return
                }
                let ok = ClipboardShelf.shared.receiveRemoteText(text, paste: true, targetPID: target.pid)
                result(ok, ok ? "Paste requested" : "The target app changed. Select your window and try again.")
            }
        case .requestShot:
            guard devCaps.shareScreenshots else { result(false, "Enable screenshot sharing in Companion devices on your Mac."); return }
            guard let id = command.shotID, let data = ShotShelf.shared.companionImage(id: id) else {
                result(false, "That screenshot has left the Mac shelf, or is too large to transfer."); return
            }
            result(true, "Screenshot ready", data: data, mimeType: "image/jpeg")
        case .requestClipImage:
            guard devCaps.shareClipboard, devCaps.shareClipboardImages else {
                result(false, "Enable clipboard and clipboard image sharing on your Mac."); return
            }
            guard let id = command.clipID, let data = ClipboardShelf.shared.companionImage(id: id),
                  data.count <= 3 * 1024 * 1024 else {
                result(false, "That clipboard image is no longer available, or is too large to transfer."); return
            }
            result(true, "Clipboard image ready", data: data, mimeType: "image/png")
        }
    }

    private func send(_ message: BridgeMessage, to session: Session, isState: Bool = false,
                      sharingEpoch: UUID? = nil) {
        guard sessions[session.id] != nil, let data = try? message.encodedFrame() else { return }
        let revoked = message.result?.data == nil ? nil : BridgeMessage(kind: .result, requestID: message.requestID,
            result: BridgeResult(success: false, message: "Sharing settings changed. Review permissions and try again."))
        let packet = PendingPacket(data: data, sharingEpoch: sharingEpoch, revokedResult: revoked)
        if isState { session.pendingState = packet } else {
            guard session.pending.count < 16,
                  session.pending.reduce(0, { $0 + $1.data.count }) + data.count <= 8 * 1024 * 1024 else {
                remove(session); return
            }
            session.pending.append(packet)
        }
        flush(session)
    }

    private func flush(_ session: Session) {
        guard !session.sending, sessions[session.id] != nil else { return }
        let packet: PendingPacket
        if !session.pending.isEmpty { packet = session.pending.removeFirst() }
        else if let snapshot = session.pendingState { packet = snapshot; session.pendingState = nil }
        else { return }
        if let epoch = packet.sharingEpoch, !sharingAuthorization.matches(epoch) {
            if let revoked = packet.revokedResult { send(revoked, to: session) }
            flush(session)
            return
        }
        session.sending = true
        session.connection.send(content: packet.data, completion: .contentProcessed { [weak self, weak session] error in
            guard let self, let session, self.sessions[session.id] != nil else { return }
            session.sending = false
            if error != nil { self.remove(session) } else { self.flush(session) }
        })
    }
}

private struct CompanionPairingView: View {
    @ObservedObject var bridge: RemoteBridge
    @State private var confirmReset = false
    @State private var accessibilityAllowed = false
    @State private var screenRecordingAllowed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                connectionSection
                pairingSection
                actionsSection
                sharingSection
                permissionsSection
                devicesSection
                Text("Encrypted connection • Same local network • No cloud account")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .alert("Reset pairing for every device?", isPresented: $confirmReset) {
            Button("Reset pairing", role: .destructive) { bridge.rotatePairingCode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current code will stop working and every connected device will disconnect. Pair each device again with the new code.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ipad.and.iphone").font(.largeTitle).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Mac, within reach").font(.title2.bold())
                Text("Set up Show Bar Companion for iPhone and iPad.").foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Allow companion devices on this network", isOn: Binding(get: { bridge.enabled }, set: bridge.setEnabled))
                .toggleStyle(.switch)
            Label(bridge.status, systemImage: bridge.connectedCount > 0 ? "checkmark.shield" : "network")
                .font(.callout).foregroundStyle(.secondary)
            Text("Connected devices can see Mac window titles and app names. Choose their controls and shared content below. Settings stay available when Companion is off.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        GroupBox("Pairing code") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select this Mac in the companion app, then enter this code. Treat it like a password.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(bridge.pairingCode.isEmpty ? "Keychain unavailable" : bridge.pairingCode)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Copy code", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bridge.pairingCode, forType: .string)
                        NSPasteboard.general.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
                    }.disabled(bridge.pairingCode.isEmpty)
                    Spacer()
                    Button("Reset pairing…") { confirmReset = true }
                }
            }.padding(8)
        }
    }

    private var actionsSection: some View {
        GroupBox("What connected devices may do") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Select and focus Mac windows", isOn: Binding(get: { bridge.allowFocus }, set: bridge.setAllowFocus))
                Toggle("Arrange selected Mac windows", isOn: Binding(get: { bridge.allowSnap }, set: bridge.setAllowSnap))
                Toggle("Close selected Mac windows", isOn: Binding(get: { bridge.allowClose }, set: bridge.setAllowClose))
                Toggle("Copy text to the Mac clipboard", isOn: Binding(get: { bridge.allowCopyToMac }, set: bridge.setAllowCopyToMac))
                Toggle("Paste text into a selected Mac window", isOn: Binding(get: { bridge.allowPasteToMac }, set: bridge.setAllowPasteToMac))
                Text("Closing windows and receiving copied or pasted text start off. Paste selects the chosen Mac window and requires Accessibility permission. Changes apply to current connections immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sharingSection: some View {
        GroupBox("What leaves this Mac") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Share recent clipboard text and links", isOn: Binding(get: { bridge.shareClipboard }, set: bridge.setShareClipboard))
                Toggle("Include clipboard images", isOn: Binding(get: { bridge.shareClipboardImages }, set: bridge.setShareClipboardImages))
                    .disabled(!bridge.shareClipboard)
                Toggle("Share live window previews", isOn: Binding(get: { bridge.shareWindowPreviews }, set: bridge.setShareWindowPreviews))
                Toggle("Share pictures in the screenshot shelf", isOn: Binding(get: { bridge.shareScreenshots }, set: bridge.setShareScreenshots))
                Text("Each kind of sharing starts off. Clipboard images require clipboard sharing too. Window previews require Screen Recording permission. Text previews are limited to 8,192 characters; image transfers are limited to 3 MB.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionsSection: some View {
        GroupBox("macOS permissions") {
            VStack(alignment: .leading, spacing: 12) {
                permissionRow("Accessibility", allowed: accessibilityAllowed,
                              detail: "Select, arrange, close, and paste into Mac windows.",
                              section: "Privacy_Accessibility")
                Divider()
                permissionRow("Screen Recording", allowed: screenRecordingAllowed,
                              detail: "Capture window previews for connected devices.",
                              section: "Privacy_ScreenCapture")
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local Network").font(.callout.bold())
                        Text("macOS manages this permission. Allow Show Bar if this Mac does not appear on your iPhone or iPad.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open settings") { openSettings("Privacy_LocalNetwork") }
                }
                Button("Check permissions again", action: refreshPermissions)
                    .font(.callout)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, detail: String, section: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title + (allowed ? ": Allowed" : ": Not allowed"),
                      systemImage: allowed ? "checkmark.circle.fill" : "circle")
                    .font(.callout.bold()).foregroundStyle(allowed ? Color.green : Color.secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open settings") { openSettings(section) }
        }
    }

    private var devicesSection: some View {
        GroupBox("Paired & connected devices") {
            VStack(alignment: .leading, spacing: 12) {
                if bridge.pairedDevices.isEmpty && bridge.connectedDevices.isEmpty {
                    Text("No devices paired yet.").foregroundStyle(.secondary)
                } else {
                    let devices = bridge.pairedDevices.isEmpty
                        ? bridge.connectedDevices.map { RemoteBridge.PairedDevice(id: $0.deviceID, name: $0.name) }
                        : bridge.pairedDevices
                    ForEach(devices) { device in
                        let isConnected = bridge.connectedDevices.contains(where: { $0.deviceID == device.id })
                        PairedDeviceRowView(bridge: bridge, device: device, isConnected: isConnected)
                        if device.id != devices.last?.id {
                            Divider()
                        }
                    }
                }
                HStack {
                    Button("Disconnect all", role: .destructive, action: bridge.disconnectAll)
                        .disabled(bridge.connectedDevices.isEmpty)
                }
                Text("You can disconnect, revoke, or customize permissions for an individual device at any time without resetting the pairing code for other devices.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func refreshPermissions() {
        accessibilityAllowed = AXIsProcessTrusted()
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    }

    private func openSettings(_ section: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PairedDeviceRowView: View {
    @ObservedObject var bridge: RemoteBridge
    let device: RemoteBridge.PairedDevice
    let isConnected: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "ipad.and.iphone")
                    .foregroundStyle(device.isRevoked ? Color.red : (isConnected ? Color.green : Color.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: device.name).font(.callout.bold())
                        if isConnected {
                            Text("Connected").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.green)
                        }
                        if device.isRevoked {
                            Text("Revoked").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.red.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.red)
                        } else if device.customCapabilities != nil {
                            Text("Custom").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.blue)
                        }
                    }
                    Text("Last seen \(device.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isExpanded ? "Hide permissions" : "Permissions…") {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
                .font(.caption)

                if isConnected, let session = bridge.connectedDevices.first(where: { $0.deviceID == device.id }) {
                    Button("Disconnect") { bridge.disconnectSession(sessionID: session.id) }
                        .font(.caption)
                }
                if device.isRevoked {
                    Button("Allow") { bridge.unrevokeDevice(id: device.id) }
                        .font(.caption)
                } else {
                    Button("Revoke", role: .destructive) { bridge.revokeDevice(id: device.id) }
                        .font(.caption)
                }
                Button("Forget") { bridge.removePairedDevice(id: device.id) }
                    .font(.caption)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Toggle("Use custom permissions for this device", isOn: Binding(
                        get: { device.customCapabilities != nil },
                        set: { enable in
                            if enable {
                                bridge.setCustomCapabilities(for: device.id, capabilities: bridge.capabilities)
                            } else {
                                bridge.setCustomCapabilities(for: device.id, capabilities: nil)
                            }
                        }
                    ))
                    .font(.callout.bold())

                    if let caps = device.customCapabilities {
                        HStack(spacing: 8) {
                            Text("Presets:").font(.caption).foregroundStyle(.secondary)
                            Button("Guest / Read-only") {
                                bridge.setCustomCapabilities(for: device.id, capabilities: BridgeCapabilities(
                                    allowFocus: true, allowSnap: false, allowClose: false,
                                    allowCopyToMac: false, allowPasteToMac: false,
                                    shareClipboard: false, shareClipboardImages: false,
                                    shareWindowPreviews: false, shareScreenshots: false
                                ))
                            }.font(.caption)
                            Button("Window Control") {
                                bridge.setCustomCapabilities(for: device.id, capabilities: BridgeCapabilities(
                                    allowFocus: true, allowSnap: true, allowClose: false,
                                    allowCopyToMac: false, allowPasteToMac: false,
                                    shareClipboard: false, shareClipboardImages: false,
                                    shareWindowPreviews: true, shareScreenshots: false
                                ))
                            }.font(.caption)
                            Button("Full Access") {
                                bridge.setCustomCapabilities(for: device.id, capabilities: .all)
                            }.font(.caption)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Actions").font(.caption.bold()).foregroundStyle(.secondary)
                            customToggle("Focus windows", keyPath: \.allowFocus, current: caps)
                            customToggle("Arrange windows", keyPath: \.allowSnap, current: caps)
                            customToggle("Close windows", keyPath: \.allowClose, current: caps)
                            customToggle("Copy text to Mac", keyPath: \.allowCopyToMac, current: caps)
                            customToggle("Paste text into window", keyPath: \.allowPasteToMac, current: caps)

                            Text("Sharing").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                            customToggle("Clipboard text and links", keyPath: \.shareClipboard, current: caps)
                            customToggle("Clipboard images", keyPath: \.shareClipboardImages, current: caps)
                                .disabled(!caps.shareClipboard)
                            customToggle("Window previews", keyPath: \.shareWindowPreviews, current: caps)
                            customToggle("Screenshot shelf", keyPath: \.shareScreenshots, current: caps)
                        }
                        .padding(.leading, 8)

                        Text("Mac global settings always act as the security ceiling.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("This device currently inherits all global settings configured above.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func customToggle(_ title: String, keyPath: WritableKeyPath<BridgeCapabilities, Bool>, current: BridgeCapabilities) -> some View {
        Toggle(title, isOn: Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                var updated = current
                updated[keyPath: keyPath] = newValue
                bridge.setCustomCapabilities(for: device.id, capabilities: updated)
            }
        ))
        .font(.caption)
    }
}
