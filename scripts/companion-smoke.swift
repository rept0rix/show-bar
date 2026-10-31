import Foundation
import Network

/// Runs the real desktop bridge in its isolated DEBUG mode. Never opens the
/// installed app, reads its pairing, or invokes Mac window/clipboard actions.
@main
enum CompanionSmoke {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure("Pass the Debug Show Bar executable path.") }
            let code = BridgePairingCode.generate()
            let host = Process()
            host.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            host.arguments = ["--companion-test-host"]
            var environment = ProcessInfo.processInfo.environment
            environment["SHOWBAR_COMPANION_TEST_CODE"] = code
            host.environment = environment
            let output = Pipe()
            host.standardOutput = output
            host.standardError = FileHandle.standardError
            try host.run()
            let watchdog = DispatchWorkItem { if host.isRunning { host.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
            defer {
                watchdog.cancel()
                if host.isRunning { host.terminate() }
                host.waitUntilExit()
            }
            var line = Data()
            while line.count < 4096 {
                let byte = output.fileHandleForReading.readData(ofLength: 1)
                if byte.isEmpty || byte == Data([0x0A]) { break }
                line.append(byte)
            }
            let value = String(decoding: line, as: UTF8.self)
            guard value.hasPrefix("SHOWBAR_TEST_PORT="),
                  let number = UInt16(value.dropFirst("SHOWBAR_TEST_PORT=".count)),
                  let port = NWEndpoint.Port(rawValue: number) else {
                throw Failure("The isolated desktop bridge did not report a test port.")
            }
            try authenticatedCommands(port: port, code: code)
            try rejectsVersion(port: port, code: code)
            try rejectsPairing(port: port)
            print("PASS: real Mac host authenticated, published state, acknowledged refresh, rejected mutations, version mismatch, and wrong pairing.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func authenticatedCommands(port: NWEndpoint.Port, code: String) throws {
        let queue = DispatchQueue(label: "showbar.smoke.commands")
        let connection = NWConnection(host: "127.0.0.1", port: port, using: try BridgeTransport.parameters(pairingCode: code))
        let finished = DispatchSemaphore(value: 0)
        var decoder = BridgeFrameDecoder()
        var stateSeen = false
        var refreshSeen = false
        var denialSeen = false
        var failure: String?
        var completed = false
        func finish(_ error: String? = nil) {
            guard !completed else { return }
            completed = true
            failure = error
            finished.signal()
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                do {
                    for message in try decoder.append(data ?? Data()) {
                        if message.kind == .state, let state = message.snapshot {
                            guard state.hostName == "Show Bar Test Host", state.windows.isEmpty, state.clips.isEmpty,
                                  state.shots.isEmpty, !state.permissions.accessibility, !state.permissions.screenRecording,
                                  state.capabilities == .some(.none) else {
                                finish("Test host unexpectedly accessed live desktop data."); return
                            }
                            if !stateSeen {
                                stateSeen = true
                                for request in [
                                    BridgeMessage(kind: .command, requestID: "refresh", command: BridgeCommand(action: .refresh)),
                                    BridgeMessage(kind: .command, requestID: "mutation", command: BridgeCommand(action: .copyToMac, text: "Must never enter clipboard"))
                                ] {
                                    connection.send(content: try request.encodedFrame(), completion: .contentProcessed { _ in })
                                }
                            }
                        }
                        if message.kind == .result, message.requestID == "refresh" {
                            refreshSeen = message.result?.success == true
                        }
                        if message.kind == .result, message.requestID == "mutation" {
                            guard message.result?.success == false,
                                  message.result?.message.contains("Companion devices") == true else {
                                finish("The desktop permission policy did not deny the ungranted action."); return
                            }
                            denialSeen = true
                        }
                        if stateSeen && refreshSeen && denialSeen { finish(); return }
                    }
                    if complete || error != nil { finish("The desktop bridge disconnected during command validation.") }
                    else if !completed { receive() }
                } catch { finish("Desktop response decoding failed: \(error)") }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: try? BridgeMessage(kind: .hello, deviceName: "Isolated smoke test").encodedFrame(), completion: .contentProcessed { _ in })
                receive()
            case .failed(let error): finish("Paired desktop connection failed: \(error)")
            default: break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        guard finished.wait(timeout: .now() + 10) == .success else { throw Failure("Desktop command test timed out.") }
        if let failure { throw Failure(failure) }
    }

    private static func rejectsVersion(port: NWEndpoint.Port, code: String) throws {
        let queue = DispatchQueue(label: "showbar.smoke.version")
        let connection = NWConnection(host: "127.0.0.1", port: port, using: try BridgeTransport.parameters(pairingCode: code))
        let closed = DispatchSemaphore(value: 0)
        var stateLeaked = false
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: try? BridgeMessage(kind: .hello, version: 99).encodedFrame(), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    stateLeaked = data?.isEmpty == false
                    if complete || error != nil { closed.signal() }
                }
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        guard closed.wait(timeout: .now() + 5) == .success, !stateLeaked else {
            throw Failure("Desktop host did not reject an incompatible protocol before sharing state.")
        }
    }

    private static func rejectsPairing(port: NWEndpoint.Port) throws {
        let connection = NWConnection(host: "127.0.0.1", port: port,
                                      using: try BridgeTransport.parameters(pairingCode: BridgePairingCode.generate()))
        let authenticated = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in if case .ready = state { authenticated.signal() } }
        connection.start(queue: DispatchQueue(label: "showbar.smoke.wrong-key"))
        defer { connection.cancel() }
        if authenticated.wait(timeout: .now() + 2) == .success { throw Failure("Desktop accepted the wrong pairing code.") }
    }
}
