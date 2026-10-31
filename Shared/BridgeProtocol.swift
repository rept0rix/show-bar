import Foundation

/// Versioned messages shared by the desktop host and the iOS companion.
/// Every message occupies one UTF-8 JSON line; binary fields use Codable's base64 encoding.
struct BridgeMessage: Codable, Equatable {
    enum Kind: String, Codable { case hello, state, command, result, ping, pong }
    static let currentVersion = 1
    var kind: Kind
    var version: Int
    var requestID: String?
    var deviceName: String?
    var deviceID: String?
    var snapshot: BridgeSnapshot?
    var command: BridgeCommand?
    var result: BridgeResult?

    init(kind: Kind, version: Int = Self.currentVersion, requestID: String? = nil,
         deviceName: String? = nil, deviceID: String? = nil, snapshot: BridgeSnapshot? = nil,
         command: BridgeCommand? = nil, result: BridgeResult? = nil) {
        self.kind = kind; self.version = version; self.requestID = requestID
        self.deviceName = deviceName; self.deviceID = deviceID; self.snapshot = snapshot
        self.command = command; self.result = result
    }

    func encodedFrame() throws -> Data {
        var data = try JSONEncoder().encode(self)
        guard data.count <= BridgeFrameDecoder.maximumFrameSize else { throw BridgeProtocolError.frameTooLarge }
        data.append(0x0A)
        return data
    }
}

struct BridgeSnapshot: Codable, Equatable {
    var hostName: String
    var windows: [BridgeWindow]
    var clips: [BridgeClip]
    var shots: [BridgeShot]
    var permissions: BridgePermissions
    /// Missing on an older host. Clients must treat missing capabilities as denied.
    var capabilities: BridgeCapabilities? = nil
}

struct BridgeWindow: Codable, Equatable, Identifiable {
    var id: UInt32
    var pid: Int32
    var title: String
    var appName: String
    var isCurrent: Bool
    var thumbnail: Data?
    init(id: UInt32, pid: Int32, title: String, appName: String, isCurrent: Bool, thumbnail: Data? = nil) {
        self.id = id; self.pid = pid; self.title = title; self.appName = appName
        self.isCurrent = isCurrent; self.thumbnail = thumbnail
    }
}

struct BridgeClip: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var text: String
    var date: Date
    var thumbnail: Data? = nil
    var isTruncated: Bool? = nil
}

struct BridgeShot: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var thumbnail: Data?
    init(id: String, date: Date, thumbnail: Data? = nil) {
        self.id = id; self.date = date; self.thumbnail = thumbnail
    }
}

struct BridgePermissions: Codable, Equatable {
    var accessibility: Bool
    var screenRecording: Bool
}

/// User-granted companion features, separate from the operating system's grants.
/// Permission to discover a Mac never implies permission to change its clipboard.
struct BridgeCapabilities: Codable, Equatable {
    var allowFocus: Bool
    var allowSnap: Bool
    var allowClose: Bool
    var allowCopyToMac: Bool
    var allowPasteToMac: Bool
    var shareClipboard: Bool
    var shareClipboardImages: Bool
    var shareWindowPreviews: Bool
    var shareScreenshots: Bool

    init(allowFocus: Bool = false, allowSnap: Bool = false, allowClose: Bool = false,
         allowCopyToMac: Bool = false, allowPasteToMac: Bool = false,
         shareClipboard: Bool = false, shareClipboardImages: Bool = false,
         shareWindowPreviews: Bool = false, shareScreenshots: Bool = false) {
        self.allowFocus = allowFocus; self.allowSnap = allowSnap; self.allowClose = allowClose
        self.allowCopyToMac = allowCopyToMac; self.allowPasteToMac = allowPasteToMac
        self.shareClipboard = shareClipboard; self.shareClipboardImages = shareClipboardImages
        self.shareWindowPreviews = shareWindowPreviews; self.shareScreenshots = shareScreenshots
    }

    static let none = BridgeCapabilities()
    static let all = BridgeCapabilities(allowFocus: true, allowSnap: true, allowClose: true,
        allowCopyToMac: true, allowPasteToMac: true, shareClipboard: true,
        shareClipboardImages: true, shareWindowPreviews: true, shareScreenshots: true)

    func permits(_ action: BridgeCommand.Action) -> Bool {
        switch action {
        case .refresh: return true
        case .focus: return allowFocus
        case .snap: return allowSnap
        case .close: return allowClose
        case .copyToMac: return allowCopyToMac
        case .pasteToMac: return allowPasteToMac
        case .requestShot: return shareScreenshots
        case .requestClipImage: return shareClipboard && shareClipboardImages
        }
    }
}

struct BridgeCommand: Codable, Equatable {
    enum Action: String, Codable {
        case refresh, focus, close, snap, copyToMac, pasteToMac, requestShot, requestClipImage
    }
    var action: Action
    var windowID: UInt32?
    var zone: String?
    var text: String?
    var shotID: String?
    var clipID: String?
    init(action: Action, windowID: UInt32? = nil, zone: String? = nil,
         text: String? = nil, shotID: String? = nil, clipID: String? = nil) {
        self.action = action; self.windowID = windowID; self.zone = zone
        self.text = text; self.shotID = shotID; self.clipID = clipID
    }
}

struct BridgeResult: Codable, Equatable {
    var success: Bool
    var message: String
    var data: Data?
    var mimeType: String?
    init(success: Bool, message: String, data: Data? = nil, mimeType: String? = nil) {
        self.success = success; self.message = message; self.data = data; self.mimeType = mimeType
    }
}

enum BridgeProtocolError: LocalizedError {
    case frameTooLarge, malformedFrame, unsupportedVersion, invalidPairingCode
    var errorDescription: String? {
        switch self {
        case .frameTooLarge: return "The companion message exceeds the size limit."
        case .malformedFrame: return "The companion sent an unreadable message."
        case .unsupportedVersion: return "Update Show Bar on both devices to use matching companion versions."
        case .invalidPairingCode: return "Paste the complete pairing code shown in Show Bar on your Mac."
        }
    }
}

/// TCP may split one line across many reads or join many lines into one read.
/// Keep the unfinished suffix and bound it before attempting JSON decoding.
struct BridgeFrameDecoder {
    static let maximumFrameSize = 8 * 1024 * 1024
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [BridgeMessage] {
        var messages: [BridgeMessage] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let newline = data[cursor...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            guard pending.count + data.distance(from: cursor, to: end) <= Self.maximumFrameSize else {
                pending.removeAll(); throw BridgeProtocolError.frameTooLarge
            }
            pending.append(contentsOf: data[cursor..<end])
            guard let newline else { break }
            if !pending.isEmpty {
                let message: BridgeMessage
                do { message = try JSONDecoder().decode(BridgeMessage.self, from: pending) }
                catch { pending.removeAll(); throw BridgeProtocolError.malformedFrame }
                pending.removeAll(keepingCapacity: true)
                guard message.version == BridgeMessage.currentVersion else { throw BridgeProtocolError.unsupportedVersion }
                messages.append(message)
            }
            cursor = data.index(after: newline)
        }
        return messages
    }
}
