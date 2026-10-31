import SwiftUI
import UIKit

enum CompanionPreferences {
    static let confirmWindowClose = "companion.confirmWindowClose"
    static let showWindowPreviews = "companion.showWindowPreviews"
}

struct CompanionSettingsView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var shelf: CompanionShelf
    @Environment(\.dismiss) private var dismiss
    @Binding var deskMode: Bool
    @AppStorage(CompanionPreferences.confirmWindowClose) private var confirmWindowClose = true
    @AppStorage(CompanionPreferences.showWindowPreviews) private var showWindowPreviews = true
    @State private var confirmClear = false
    @State private var confirmForget = false

    private var liveStatus: Bool { client.isConnected && !client.isDemo }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Confirm before closing Mac windows", isOn: $confirmWindowClose)
                        .accessibilityIdentifier("confirmWindowClose")
                    Toggle("Show window previews", isOn: $showWindowPreviews)
                        .accessibilityIdentifier("showWindowPreviews")
                    Toggle("Keep screen awake in desk mode", isOn: $deskMode)
                        .accessibilityIdentifier("deskMode")
                } header: {
                    Text("On this device")
                } footer: {
                    Text("Window previews also need sharing enabled on your Mac. Desk mode keeps the screen awake only while Show Bar is active.")
                }

                Section {
                    permissionRow("Local Network on this device", symbol: "wifi", status: liveStatus ? "Available" : "Not verified", enabled: liveStatus,
                                  detail: liveStatus ? "This connection confirms local network access is currently available." : "Connect to a nearby Mac to verify access. A disconnected state does not tell us whether permission was denied.")
                    Button("Open this app’s system settings", systemImage: "arrow.up.right.square") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .accessibilityIdentifier("openSystemSettings")
                    permissionRow("Accessibility on your Mac", symbol: "hand.point.up.left", status: macPermissionStatus(client.snapshot?.permissions.accessibility), enabled: liveStatus && client.snapshot?.permissions.accessibility == true,
                                  detail: "Required to focus, arrange, close, or paste into Mac windows. Change in Mac System Settings → Privacy & Security → Accessibility.")
                    permissionRow("Screen Recording on your Mac", symbol: "record.circle", status: macPermissionStatus(client.snapshot?.permissions.screenRecording), enabled: liveStatus && client.snapshot?.permissions.screenRecording == true,
                                  detail: "Required for window previews and screen capture. Change in Mac System Settings → Privacy & Security → Screen Recording, then restart Show Bar.")
                } header: {
                    Text("System permissions")
                } footer: {
                    Text(client.isDemo ? "Demo content cannot verify any system permission." : "System permission alone does not turn on a shared feature. Your Mac must allow each feature below.")
                }

                Section {
                    ForEach(featureStatuses) { feature in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(feature.name).font(.subheadline.weight(.medium))
                                Spacer(minLength: 10)
                                Text(featureStatus(feature.enabled))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(liveStatus && feature.enabled ? CompanionStyle.cyan : CompanionStyle.secondary)
                            }
                            Text(feature.detail).font(.caption).foregroundStyle(CompanionStyle.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Allowed by your Mac")
                } footer: {
                    Text(capabilityFooter)
                }

                Section {
                    LabeledContent("Saved local items", value: "\(shelf.items.count)")
                    Button("Clear this device’s shelf", role: .destructive) { confirmClear = true }
                        .disabled(shelf.items.isEmpty)
                        .accessibilityIdentifier("clearLocalShelf")
                    Button("Forget saved Mac pairing", role: .destructive) { confirmForget = true }
                        .disabled(client.isDemo || !client.hasPairingToForget)
                        .accessibilityIdentifier("forgetPairing")
                    if let error = shelf.storageError {
                        Text(error).font(.caption).foregroundStyle(CompanionStyle.yellow)
                    }
                } header: {
                    Text("Your data and pairing")
                } footer: {
                    Text("Forgetting removes this device’s saved code. To revoke every device with the shared code, reset the pairing code in Show Bar → Companion devices on your Mac.")
                }

                Section {
                    LabeledContent("Version", value: version)
                    Text("Keyboard: ⌘1–4 changes sections. In Windows, ⌥⌘ plus an arrow arranges halves; ⌥⌘U/I/J/K selects corners; ⌥⌘Return fills the screen. A selected window and the Mac’s layout grant are required.")
                        .font(.caption).foregroundStyle(CompanionStyle.secondary)
                    Text("Show Bar controls windows on your paired Mac. It cannot replace the iPad app switcher, watch the iPhone clipboard in the background, or place a shelf over other iOS apps.")
                        .font(.caption).foregroundStyle(CompanionStyle.secondary)
                    Text("Paste is explicit. Local notes stay on this device. Mac feature settings can be changed only on your Mac.")
                        .font(.caption).foregroundStyle(CompanionStyle.secondary)
                } header: {
                    Text("About Show Bar Companion")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CompanionStyle.background)
            .navigationTitle("Settings & permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear this device’s shelf?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear local shelf", role: .destructive) { shelf.clear() }
            } message: {
                Text("Your saved local text will be removed. Your Mac’s clipboard history remains on your Mac.")
            }
            .confirmationDialog("Forget this Mac’s saved pairing?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget pairing", role: .destructive) {
                    client.forgetPairing()
                    client.startDiscovery()
                }
            } message: {
                Text("The connection will close and the saved pairing code will be removed from this device. Other paired devices keep access until you reset the code on your Mac.")
            }
        }
        .tint(CompanionStyle.yellow)
    }

    private func permissionRow(_ title: String, symbol: String, status: String, enabled: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(status).font(.caption.weight(.semibold))
                    .foregroundStyle(enabled ? CompanionStyle.cyan : CompanionStyle.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(CompanionStyle.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func macPermissionStatus(_ value: Bool?) -> String {
        guard liveStatus, let value else { return "Not verified" }
        return value ? "Allowed" : "Needed"
    }

    private func featureStatus(_ enabled: Bool) -> String {
        guard liveStatus else { return client.isDemo ? "Demo" : "Not verified" }
        guard client.snapshot?.capabilities != nil else { return "Update Mac app" }
        return enabled ? "On" : "Off"
    }

    private var capabilityFooter: String {
        if client.isDemo { return "Demo capabilities are sample information. Connect your Mac to see its actual settings." }
        if !liveStatus { return "Connect your Mac to check which features it allows." }
        if client.snapshot?.capabilities == nil { return "Update Show Bar on your Mac to view and grant individual features." }
        return "Change on Mac: Show Bar → Companion devices. This device can view these grants and cannot enable them remotely. Shared features are available only while connected."
    }

    private var featureStatuses: [FeatureStatus] {
        let grants = client.capabilities
        return [
            FeatureStatus(name: "Focus windows", enabled: grants.allowFocus, detail: "Needs Mac Accessibility permission."),
            FeatureStatus(name: "Arrange windows", enabled: grants.allowSnap, detail: "Needs Mac Accessibility permission and a selected window."),
            FeatureStatus(name: "Close windows", enabled: grants.allowClose, detail: "Needs Mac Accessibility permission. Confirmations follow this device’s preference."),
            FeatureStatus(name: "Copy text to Mac", enabled: grants.allowCopyToMac, detail: "Writes to the Mac clipboard after you tap Copy to Mac."),
            FeatureStatus(name: "Paste text into Mac", enabled: grants.allowPasteToMac, detail: "Needs Mac Accessibility permission and a selected window."),
            FeatureStatus(name: "Share Mac clipboard text", enabled: grants.shareClipboard, detail: "Makes eligible Mac clipboard text visible on this device."),
            FeatureStatus(name: "Share Mac clipboard images", enabled: grants.shareClipboardImages, detail: "Image downloads also need Mac clipboard sharing enabled."),
            FeatureStatus(name: "Share window previews", enabled: grants.shareWindowPreviews, detail: "Needs Mac Screen Recording permission. Can also be hidden on this device."),
            FeatureStatus(name: "Share screenshots", enabled: grants.shareScreenshots, detail: "Mac capture needs Screen Recording permission. Transfers use optimized image copies.")
        ]
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketing = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(marketing) (\(build))"
    }

    private struct FeatureStatus: Identifiable {
        var id: String { name }
        let name: String
        let enabled: Bool
        let detail: String
    }
}
