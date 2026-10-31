import XCTest
@testable import CompanionProtocol

final class BridgeProtocolTests: XCTestCase {
    func testFragmentedAndCoalescedFramesPreserveUnicodeAndEscapedNewlines() throws {
        let first = BridgeMessage(kind: .command, requestID: "one",
                                  command: BridgeCommand(action: .copyToMac, text: "שלום 👋\nnext line"))
        let second = BridgeMessage(kind: .ping, requestID: "two")
        let data = try first.encodedFrame() + second.encodedFrame()
        var decoder = BridgeFrameDecoder()
        var received: [BridgeMessage] = []
        for byte in data { received += try decoder.append(Data([byte])) }
        XCTAssertEqual(received, [first, second])
        var coalesced = BridgeFrameDecoder()
        XCTAssertEqual(try coalesced.append(data), [first, second])
    }

    func testLargeBinaryShotRoundTripsAcrossTCPChunks() throws {
        let bytes = Data((0..<100_000).map { UInt8($0 % 256) })
        let message = BridgeMessage(kind: .result, requestID: "shot",
                                    result: BridgeResult(success: true, message: "Screenshot", data: bytes, mimeType: "image/jpeg"))
        let frame = try message.encodedFrame()
        var decoder = BridgeFrameDecoder()
        let split = frame.count / 2
        XCTAssertTrue(try decoder.append(frame.prefix(split)).isEmpty)
        XCTAssertEqual(try decoder.append(frame.suffix(from: split)), [message])
    }

    func testVersionMismatchRejected() throws {
        var decoder = BridgeFrameDecoder()
        XCTAssertThrowsError(try decoder.append(BridgeMessage(kind: .hello, version: 99).encodedFrame())) {
            guard case BridgeProtocolError.unsupportedVersion = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testMalformedAndNonUTF8DataRejected() {
        for bytes in [Data("not json\n".utf8), Data([0xFF, 0x0A])] {
            var decoder = BridgeFrameDecoder()
            XCTAssertThrowsError(try decoder.append(bytes))
        }
    }

    func testOversizedUnfinishedFrameRejectedAcrossReads() throws {
        var decoder = BridgeFrameDecoder()
        XCTAssertTrue(try decoder.append(Data(repeating: 0x20, count: BridgeFrameDecoder.maximumFrameSize)).isEmpty)
        XCTAssertThrowsError(try decoder.append(Data([0x20])))
    }

    func testEmptyLinesDoNotLoseFollowingFrame() throws {
        var decoder = BridgeFrameDecoder()
        let message = BridgeMessage(kind: .hello, deviceName: "iPad")
        XCTAssertEqual(try decoder.append(Data([0x0A, 0x0A]) + message.encodedFrame()), [message])
    }

    func testPairingCodesAreRandomValidatedAndNormalized() {
        let code = BridgePairingCode.generate()
        XCTAssertTrue(BridgePairingCode.isValid(code))
        XCTAssertTrue(BridgePairingCode.isValid(" \(code.uppercased())\n"))
        XCTAssertNotEqual(code, BridgePairingCode.generate())
        for invalid in ["123456", "sb1-", "sb1-" + String(repeating: "g", count: 32), code + "0"] {
            XCTAssertFalse(BridgePairingCode.isValid(invalid))
            XCTAssertThrowsError(try BridgeTransport.parameters(pairingCode: invalid))
        }
    }

    func testDeviceIDRoundTripAndBackwardCompatibility() throws {
        let msgWithDeviceID = BridgeMessage(kind: .hello, deviceName: "Naor's iPhone", deviceID: "iphone-17-unique-uuid")
        let encoded = try msgWithDeviceID.encodedFrame()
        var decoder = BridgeFrameDecoder()
        let decoded = try decoder.append(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.deviceID, "iphone-17-unique-uuid")
        XCTAssertEqual(decoded.first?.deviceName, "Naor's iPhone")

        // Backward compatibility: JSON without deviceID decodes with deviceID == nil
        let legacyJSON = Data(#"{"kind":"hello","version":1,"deviceName":"Legacy iPad"}"#.utf8) + Data([0x0A])
        var legacyDecoder = BridgeFrameDecoder()
        let legacyDecoded = try legacyDecoder.append(legacyJSON)
        XCTAssertEqual(legacyDecoded.count, 1)
        XCTAssertNil(legacyDecoded.first?.deviceID)
        XCTAssertEqual(legacyDecoded.first?.deviceName, "Legacy iPad")
    }
}
