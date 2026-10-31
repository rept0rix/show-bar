import AppKit
import Foundation

/// Lightweight, privacy-first telemetry for Show Bar.
/// 100% GDPR-compliant: No personal data, no keystrokes, no image contents, no IP logging.
/// Transmits anonymous usage milestones to understand onboarding drop-offs and feature engagement.
final class Telemetry: @unchecked Sendable {
    static let shared = Telemetry()

    private let queue = DispatchQueue(label: "com.naoryanko.showbar.telemetry", qos: .utility)
    private var telemetryDeckAppID: String?
    private var customEndpoint: URL?

    private let anonymousIDKey = "ShowBar.telemetryAnonymousID"
    private let firstLaunchDateKey = "ShowBar.telemetryFirstLaunchDate"

    private init() {
        // Ensure anonymous persistent ID exists (random UUID, completely decoupled from hardware UUID/Apple ID)
        if UserDefaults.standard.string(forKey: anonymousIDKey) == nil {
            UserDefaults.standard.set(UUID().uuidString, forKey: anonymousIDKey)
        }
        if UserDefaults.standard.object(forKey: firstLaunchDateKey) == nil {
            UserDefaults.standard.set(Date(), forKey: firstLaunchDateKey)
        }
    }

    var anonymousID: String {
        UserDefaults.standard.string(forKey: anonymousIDKey) ?? UUID().uuidString
    }

    var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ||
        NSHomeDirectory().contains("/Containers/")
    }

    var daysSinceFirstLaunch: Int {
        guard let firstDate = UserDefaults.standard.object(forKey: firstLaunchDateKey) as? Date else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: firstDate, to: Date()).day ?? 0)
    }

    func configure(telemetryDeckAppID: String?, customEndpoint: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let tID = telemetryDeckAppID?.trimmingCharacters(in: .whitespacesAndNewlines), !tID.isEmpty {
                self.telemetryDeckAppID = tID
            }
            if let endpoint = customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: endpoint), url.scheme == "https" {
                self.customEndpoint = url
            }
        }
    }

    /// Record a telemetry event with optional key-value metadata
    func track(_ event: String, params: [String: String] = [:]) {
        queue.async { [weak self] in
            guard let self else { return }
            var metadata = params
            metadata["app_version"] = ShowBarSupport.version
            metadata["macos_version"] = ProcessInfo.processInfo.operatingSystemVersionString
            metadata["is_sandboxed"] = self.isSandboxed ? "true" : "false"
            metadata["days_active"] = "\(self.daysSinceFirstLaunch)"

            NSLog("[ShowBar Analytics] 📊 Event: %{public}@ | %{public}@", event, metadata.description)

            // 1. Send to TelemetryDeck if configured
            if let appID = self.telemetryDeckAppID {
                self.sendToTelemetryDeck(appID: appID, event: event, params: metadata)
            }

            // 2. Send to custom webhook/worker endpoint if configured
            if let endpoint = self.customEndpoint {
                self.sendToCustomEndpoint(url: endpoint, event: event, params: metadata)
            }
        }
    }

    private func sendToTelemetryDeck(appID: String, event: String, params: [String: String]) {
        guard let url = URL(string: "https://nom.telemetrydeck.com/v2/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let payload: [[String: Any]] = [
            [
                "appID": appID,
                "clientUser": anonymousID,
                "type": event,
                "isTestMode": false,
                "payload": params
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body

        Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func sendToCustomEndpoint(url: URL, event: String, params: [String: String]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let payload: [String: Any] = [
            "client_id": anonymousID,
            "event": event,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "properties": params
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body

        Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
