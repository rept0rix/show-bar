import Network
import XCTest
@testable import ShowBarCompanion

@MainActor
final class CompanionClientTests: XCTestCase {
    func testInvalidPairingDoesNotStartAConnection() {
        let client = CompanionClient()
        let mac = DiscoveredMac(id: "test-mac", name: "Test Mac", endpoint: .hostPort(host: "localhost", port: 52418))
        client.connect(to: mac, pairingCode: "incorrect")
        XCTAssertEqual(client.phase, .idle)
        XCTAssertFalse(client.isConnected)
        XCTAssertNil(client.snapshot)
        XCTAssertNotNil(client.errorMessage)
    }

    func testDemoIsExplicitAndRemoteCommandsCannotMutateItsState() {
        let client = CompanionClient()
        client.loadDemo()
        let demoState = client.snapshot
        XCTAssertTrue(client.isDemo)
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(demoState?.windows.count, 3)
        client.snap("left")
        XCTAssertNotNil(client.errorMessage)
        XCTAssertEqual(client.snapshot, demoState)
    }

    func testDemoSurvivesSceneSuspensionWithoutConnecting() {
        let client = CompanionClient()
        client.loadDemo()
        let demoState = client.snapshot
        client.setActive(false)
        client.setActive(true)
        XCTAssertTrue(client.isDemo)
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.snapshot, demoState)
    }

    func testDisconnectClearsRemoteDataAndSelection() {
        let client = CompanionClient()
        client.loadDemo()
        client.disconnect()
        XCTAssertNil(client.snapshot)
        XCTAssertNil(client.selectedWindowID)
        XCTAssertFalse(client.isDemo)
        XCTAssertEqual(client.phase, .idle)
    }

    func testScreenshotRequestWhenDisconnectedCompletesExactlyOnce() {
        let client = CompanionClient()
        var completions = 0
        client.requestShot("shot") { data in
            XCTAssertNil(data)
            completions += 1
        }
        XCTAssertEqual(completions, 1)
        XCTAssertNotNil(client.errorMessage)
    }

    func testPasteRequiresAnExplicitTargetWindow() {
        let client = CompanionClient()
        client.sendText("Keep this text", paste: true)
        XCTAssertEqual(client.errorMessage, "Choose the Mac window that should receive the paste.")
        XCTAssertNil(client.snapshot)
    }

    func testDisconnectedCapabilitiesFailClosed() {
        let client = CompanionClient()
        XCTAssertEqual(client.capabilities, .none)
        XCTAssertFalse(client.hasPairingToForget)
        var completions = 0
        client.requestClipImage("image") { data in
            XCTAssertNil(data)
            completions += 1
        }
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(client.isConnected)
        XCTAssertNotNil(client.errorMessage)
    }

    func testDemoCapabilitiesDoNotEnableLiveAssetRequests() {
        let client = CompanionClient()
        client.loadDemo()
        XCTAssertEqual(client.capabilities, .all)
        XCTAssertFalse(client.hasPairingToForget)
        var completions = 0
        client.requestClipImage("image") { data in
            XCTAssertNil(data)
            completions += 1
        }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(client.isDemo)
        XCTAssertFalse(client.isConnected)
    }

    func testDeviceIDIsPersistentAcrossClientInstances() {
        let first = CompanionClient()
        let second = CompanionClient()
        XCTAssertEqual(first.deviceID, second.deviceID)
        XCTAssertFalse(first.deviceID.isEmpty)
    }
}
