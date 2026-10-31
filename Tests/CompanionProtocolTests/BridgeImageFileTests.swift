import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CompanionProtocol

final class BridgeImageFileTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testValidPNGPreservesStoredImageAndMakesSmallThumbnail() throws {
        let original = try png(width: 720, height: 360)
        try original.write(to: folder.appendingPathComponent("clip.png"))
        XCTAssertEqual(BridgeImageFile.image(root: folder, name: "clip.png"), original)
        let thumb = try XCTUnwrap(BridgeImageFile.thumbnail(root: folder, name: "clip.png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumb as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 360)
        XCTAssertEqual(image.height, 180)
    }

    func testTraversalAndSymlinkCannotExportFilesOutsideShelf() throws {
        let outside = folder.appendingPathComponent("outside", isDirectory: true)
        let shelf = folder.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.png")
        try png().write(to: secret)
        try FileManager.default.createSymbolicLink(at: shelf.appendingPathComponent("link.png"), withDestinationURL: secret)
        for name in ["../outside/secret.png", secret.path, "link.png", ""] {
            XCTAssertNil(BridgeImageFile.image(root: shelf, name: name))
            XCTAssertNil(BridgeImageFile.thumbnail(root: shelf, name: name))
        }
    }

    func testOversizedAndNonImageFilesAreRejected() throws {
        try Data(repeating: 0, count: BridgeImageFile.maximumBytes + 1).write(to: folder.appendingPathComponent("large.png"))
        try Data("secret plain text".utf8).write(to: folder.appendingPathComponent("fake.png"))
        for name in ["large.png", "fake.png", "absent.png"] {
            XCTAssertNil(BridgeImageFile.image(root: folder, name: name))
        }
    }

    func testExcessivePixelDimensionsAreRejectedBeforeImageDecoding() throws {
        try png(width: 4001, height: 1).write(to: folder.appendingPathComponent("huge.png"))
        XCTAssertNil(BridgeImageFile.image(root: folder, name: "huge.png"))
        XCTAssertNil(BridgeImageFile.thumbnail(root: folder, name: "huge.png"))
    }

    private func png(width: Int = 8, height: Int = 8) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
