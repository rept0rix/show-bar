import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads bounded, validated PNGs from one known shelf directory. Network callers
/// resolve an opaque clipboard ID first; filenames never come from a command.
enum BridgeImageFile {
    static let maximumBytes = 3 * 1024 * 1024

    static func image(root: URL, name: String) -> Data? {
        guard let url = validatedURL(root: root, name: name),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maximumBytes else { return nil }
        return data
    }

    static func thumbnail(root: URL, name: String) -> Data? {
        guard let url = validatedURL(root: root, name: name),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func validatedURL(root: URL, name: String) -> URL? {
        guard !name.isEmpty, URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == root,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= maximumBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4000, height <= 4000 else { return nil }
        return url
    }
}
