import XCTest
@testable import CompanionProtocol

final class BridgeCapabilityTests: XCTestCase {
    func testNoGrantAllowsOnlyRefresh() {
        XCTAssertTrue(BridgeCapabilities.none.permits(.refresh))
        for action in [BridgeCommand.Action.focus, .close, .snap, .copyToMac, .pasteToMac, .requestShot, .requestClipImage] {
            XCTAssertFalse(BridgeCapabilities.none.permits(action))
            XCTAssertTrue(BridgeCapabilities.all.permits(action))
        }
    }

    func testClipboardImagesRequireBothIndependentSharingGrants() {
        var grants = BridgeCapabilities(shareClipboard: true)
        XCTAssertFalse(grants.permits(.requestClipImage))
        grants.shareClipboardImages = true
        XCTAssertTrue(grants.permits(.requestClipImage))
        grants.shareClipboard = false
        XCTAssertFalse(grants.permits(.requestClipImage))
    }

    func testSharingDoesNotGrantClipboardWritesOrWindowMutations() {
        let grants = BridgeCapabilities(shareClipboard: true, shareClipboardImages: true,
                                        shareWindowPreviews: true, shareScreenshots: true)
        XCTAssertTrue(grants.permits(.requestShot))
        XCTAssertFalse(grants.permits(.copyToMac))
        XCTAssertFalse(grants.permits(.pasteToMac))
        XCTAssertFalse(grants.permits(.close))
        XCTAssertFalse(grants.permits(.snap))
    }

    func testPreviewSharingAndScreenshotSharingAreIndependent() {
        let previewsOnly = BridgeCapabilities(shareWindowPreviews: true)
        XCTAssertFalse(previewsOnly.permits(.requestShot))
        let shotsOnly = BridgeCapabilities(shareScreenshots: true)
        XCTAssertFalse(shotsOnly.shareWindowPreviews)
        XCTAssertTrue(shotsOnly.permits(.requestShot))
    }

    func testOlderHostSnapshotHasNoImplicitGrants() throws {
        let oldSnapshot = Data(#"{"hostName":"Old Mac","windows":[],"clips":[],"shots":[],"permissions":{"accessibility":true,"screenRecording":true}}"#.utf8)
        let state = try JSONDecoder().decode(BridgeSnapshot.self, from: oldSnapshot)
        XCTAssertNil(state.capabilities)
        XCTAssertFalse((state.capabilities ?? .none).permits(.pasteToMac))
    }

    func testImageClipMetadataAndCommandRoundTrip() throws {
        let clip = BridgeClip(id: "opaque-image", kind: "image", text: "Image", date: Date(timeIntervalSince1970: 1),
                              thumbnail: Data([1, 2, 3]), isTruncated: false)
        XCTAssertEqual(try JSONDecoder().decode(BridgeClip.self, from: JSONEncoder().encode(clip)), clip)
        let request = BridgeMessage(kind: .command, requestID: "image", command: BridgeCommand(action: .requestClipImage, clipID: clip.id))
        var decoder = BridgeFrameDecoder()
        XCTAssertEqual(try decoder.append(request.encodedFrame()), [request])
    }

    func testPerDeviceCustomCapabilityMaskingAndPresets() {
        let guestPreset = BridgeCapabilities(allowFocus: true, allowSnap: false, allowClose: false,
                                             allowCopyToMac: false, allowPasteToMac: false,
                                             shareClipboard: false, shareClipboardImages: false,
                                             shareWindowPreviews: false, shareScreenshots: false)
        XCTAssertTrue(guestPreset.permits(.refresh))
        XCTAssertTrue(guestPreset.permits(.focus))
        XCTAssertFalse(guestPreset.permits(.snap))
        XCTAssertFalse(guestPreset.permits(.close))
        XCTAssertFalse(guestPreset.permits(.copyToMac))
        XCTAssertFalse(guestPreset.permits(.pasteToMac))
        XCTAssertFalse(guestPreset.permits(.requestShot))
        XCTAssertFalse(guestPreset.permits(.requestClipImage))

        let windowControlPreset = BridgeCapabilities(allowFocus: true, allowSnap: true, allowClose: false,
                                                     allowCopyToMac: false, allowPasteToMac: false,
                                                     shareClipboard: false, shareClipboardImages: false,
                                                     shareWindowPreviews: true, shareScreenshots: false)
        XCTAssertTrue(windowControlPreset.permits(.focus))
        XCTAssertTrue(windowControlPreset.permits(.snap))
        XCTAssertTrue(windowControlPreset.shareWindowPreviews)
        XCTAssertFalse(windowControlPreset.permits(.close))
        XCTAssertFalse(windowControlPreset.permits(.requestShot))

        // Effective masking: Global ceiling AND Custom device capabilities
        let global = BridgeCapabilities(allowFocus: true, allowSnap: true, allowClose: false,
                                        allowCopyToMac: false, allowPasteToMac: false,
                                        shareClipboard: true, shareClipboardImages: false,
                                        shareWindowPreviews: true, shareScreenshots: true)
        let customDevice = BridgeCapabilities.all
        let effective = BridgeCapabilities(
            allowFocus: global.allowFocus && customDevice.allowFocus,
            allowSnap: global.allowSnap && customDevice.allowSnap,
            allowClose: global.allowClose && customDevice.allowClose,
            allowCopyToMac: global.allowCopyToMac && customDevice.allowCopyToMac,
            allowPasteToMac: global.allowPasteToMac && customDevice.allowPasteToMac,
            shareClipboard: global.shareClipboard && customDevice.shareClipboard,
            shareClipboardImages: global.shareClipboard && global.shareClipboardImages && customDevice.shareClipboardImages,
            shareWindowPreviews: global.shareWindowPreviews && customDevice.shareWindowPreviews,
            shareScreenshots: global.shareScreenshots && customDevice.shareScreenshots
        )

        // Close and copy/paste were disabled globally, so even with .all on device, they remain disabled
        XCTAssertFalse(effective.allowClose)
        XCTAssertFalse(effective.allowCopyToMac)
        XCTAssertFalse(effective.allowPasteToMac)
        XCTAssertFalse(effective.shareClipboardImages) // disabled globally
        XCTAssertTrue(effective.allowFocus)
        XCTAssertTrue(effective.allowSnap)
        XCTAssertTrue(effective.shareClipboard)
        XCTAssertTrue(effective.shareScreenshots)
    }
}
