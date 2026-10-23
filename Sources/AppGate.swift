import AppKit
import Foundation
import IOKit

enum DeviceIdentity {
    static let uuid: String = {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return "UNKNOWN-DEVICE" }
        defer { IOObjectRelease(platformExpert) }
        guard let serial = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return "UNKNOWN-DEVICE"
        }
        return serial.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
}

struct RemotePolicy: Decodable {
    let minVersion: String?
    let blockedDevices: [String]?
    let killSwitch: Bool?
    let paywallEnabled: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case minVersion = "min_version"
        case blockedDevices = "blocked_devices"
        case killSwitch = "kill_switch"
        case paywallEnabled = "paywall_enabled"
        case message
    }
}

enum AppGate {
    private static let policyURL = URL(string: "https://rept0rix.github.io/show-bar/app-policy.json")!
    private static let licenseKey = "ShowBar.licenseKey"

    static var currentDeviceID: String {
        DeviceIdentity.uuid
    }

    static var isLicensed: Bool {
        guard let key = UserDefaults.standard.string(forKey: licenseKey), !key.isEmpty else { return false }
        return true
    }

    static func setLicense(key: String) {
        UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: licenseKey)
    }

    static func checkPolicyOnLaunch() {
        Task {
            await verify()
        }
    }

    private static func verify() async {
        var request = URLRequest(url: policyURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let policy = try? JSONDecoder().decode(RemotePolicy.self, from: data) else {
            return
        }

        let myDevice = DeviceIdentity.uuid
        let isBlocked = policy.blockedDevices?.contains(myDevice) ?? false
        let isKilled = policy.killSwitch ?? false

        if isBlocked || isKilled {
            await MainActor.run {
                AppDelegate.shared.pauseForUpdate()
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Show Bar Access Disabled"
                alert.informativeText = policy.message ?? "Access has been restricted on this Mac. Please contact na0ryank0@gmail.com for assistance."
                alert.addButton(withTitle: "Quit")
                NSRunningApplication.current.activate()
                alert.runModal()
                NSApp.terminate(nil)
            }
            return
        }

        if let minVer = policy.minVersion, AppUpdate.isNewer(minVer, than: ShowBarSupport.version) {
            await MainActor.run {
                AppUpdate.checkManually()
            }
        }
    }
}
