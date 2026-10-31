import XCTest
import Network
@testable import CompanionProtocol

final class BridgeTransportTests: XCTestCase {
    func testMatchingPairingCodeAuthenticatesAndTransfersFramedData() throws {
        let code = BridgePairingCode.generate()
        let ready = expectation(description: "TLS server ready")
        let delivered = expectation(description: "Authenticated message delivered")
        let queue = DispatchQueue(label: "showbar.tests.tls")
        let listener = try NWListener(using: BridgeTransport.parameters(pairingCode: code), on: .any)
        var accepted: NWConnection?
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                        XCTAssertNil(error)
                        var decoder = BridgeFrameDecoder()
                        XCTAssertEqual(try? decoder.append(data ?? Data()), [BridgeMessage(kind: .hello, deviceName: "Test iPad")])
                        delivered.fulfill()
                    }
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { accepted?.cancel(); listener.cancel() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = NWConnection(host: "127.0.0.1", port: port, using: try BridgeTransport.parameters(pairingCode: code))
        defer { client.cancel() }
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(content: try? BridgeMessage(kind: .hello, deviceName: "Test iPad").encodedFrame(), completion: .contentProcessed { error in
                    XCTAssertNil(error)
                })
            }
        }
        client.start(queue: queue)
        wait(for: [delivered], timeout: 8)
    }

    func testWrongPairingCodeNeverReachesAuthenticatedState() throws {
        let ready = expectation(description: "TLS server ready")
        let rejected = expectation(description: "Wrong key rejected")
        let authenticated = expectation(description: "Wrong key must not authenticate")
        authenticated.isInverted = true
        let queue = DispatchQueue(label: "showbar.tests.bad-key")
        let listener = try NWListener(using: BridgeTransport.parameters(pairingCode: BridgePairingCode.generate()), on: .any)
        var accepted: NWConnection?
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: authenticated.fulfill()
                case .failed: rejected.fulfill()
                default: break
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { accepted?.cancel(); listener.cancel() }
        wait(for: [ready], timeout: 5)
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                                  using: try BridgeTransport.parameters(pairingCode: BridgePairingCode.generate()))
        defer { client.cancel() }
        client.stateUpdateHandler = { state in
            switch state {
            case .ready: authenticated.fulfill()
            default: break
            }
        }
        client.start(queue: queue)
        wait(for: [rejected], timeout: 8)
        wait(for: [authenticated], timeout: 1)
    }
}
