import SwiftUI

struct CompanionConnectionView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var deskMode: Bool
    @State private var selectedMacID: String?
    @State private var pairingCode = ""
    @State private var showCode = false
    @State private var confirmForget = false

    private var selectedMac: DiscoveredMac? {
        client.devices.first { $0.id == selectedMacID }
    }

    private var busy: Bool {
        if case .connecting = client.phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if client.isConnected || client.isDemo {
                    connectedCard
                } else {
                    discoveryCard
                    pairingCard
                }
                ShelfCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $deskMode) {
                            Label("Desk mode", systemImage: "sun.max")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text("Keep the screen awake while Show Bar is open. Ideal beside your Mac or with a keyboard.")
                            .font(.caption).foregroundStyle(CompanionStyle.secondary)
                    }
                }
                if !client.isConnected && !client.isDemo {
                    Button {
                        client.loadDemo()
                    } label: {
                        Label("Explore a demo workspace", systemImage: "sparkles")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Uses sample windows and clipboard items. Remote actions are disabled.")
                }
                Label("Your devices connect directly on the same local network. The pairing code stays in Keychain.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(CompanionStyle.secondary)
                    .padding(.bottom, 12)
            }
            .padding(22)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { client.startDiscovery() }
        .onChange(of: client.devices.map(\.id)) { _, ids in
            if selectedMacID == nil, ids.count == 1 { selectedMacID = ids.first }
        }
        .refreshable { client.startDiscovery() }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget pairing", role: .destructive) {
                client.forgetPairing()
                client.startDiscovery()
                pairingCode = ""
            }
        } message: {
            Text("The saved pairing code will be removed from this device. You can pair again from your Mac.")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.bottomhalf.inset.filled")
                    .font(.title2).foregroundStyle(CompanionStyle.yellow)
                Text("SHOW BAR / COMPANION")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5).foregroundStyle(CompanionStyle.secondary)
            }
            Text("Your Mac.\nWithin reach.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Arrange windows. Move ideas. Keep the good stuff close.")
                .font(.subheadline).foregroundStyle(CompanionStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var connectedCard: some View {
        ShelfCard(accent: true) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(CompanionStyle.cyan)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(client.snapshot?.hostName ?? "Demo Mac").font(.headline)
                        Text(client.isDemo ? "Sample workspace · remote actions disabled" : "Connected over your local network")
                            .font(.caption).foregroundStyle(CompanionStyle.secondary)
                    }
                }
                if let permissions = client.snapshot?.permissions, !client.isDemo {
                    Label(permissions.accessibility ? "Mac Accessibility permission allowed" : "Enable Accessibility on your Mac", systemImage: permissions.accessibility ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(permissions.accessibility ? CompanionStyle.cyan : CompanionStyle.yellow)
                }
                if !client.isDemo {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(client.snapshot?.capabilities == nil ? "Update your Mac app to check feature access" : "\(enabledFeatureCount) of 9 features allowed by your Mac")
                            .font(.caption.weight(.semibold)).foregroundStyle(CompanionStyle.cyan)
                        Text("Change individual features on Mac: Show Bar → Companion devices. System permissions and feature grants are separate.")
                            .font(.caption).foregroundStyle(CompanionStyle.secondary)
                    }
                }
                HStack {
                    Button(client.isDemo ? "Leave demo" : "Disconnect") {
                        client.disconnect()
                        client.startDiscovery()
                    }
                        .buttonStyle(.bordered)
                    if !client.isDemo {
                        Spacer()
                        Button("Forget Mac", role: .destructive) { confirmForget = true }
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var discoveryCard: some View {
        ShelfCard {
            VStack(alignment: .leading, spacing: 17) {
                ShelfSectionTitle(title: "1. Find your Mac", detail: "SAME WI-FI")
                Text("On your Mac, open Show Bar → Companion devices and enable the connection.")
                    .font(.subheadline).foregroundStyle(CompanionStyle.secondary)
                if client.devices.isEmpty {
                    HStack(spacing: 12) {
                        if busy || client.phase == .searching { ProgressView().tint(CompanionStyle.cyan) }
                        Text(discoveryMessage).font(.caption).foregroundStyle(CompanionStyle.secondary)
                    }
                    Button("Search again", systemImage: "arrow.clockwise") { client.startDiscovery() }
                        .font(.subheadline)
                } else {
                    ForEach(client.devices) { mac in
                        Button {
                            selectedMacID = mac.id
                            pairingCode = ""
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer").font(.title3)
                                    .foregroundStyle(CompanionStyle.cyan)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mac.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                    if client.hasSavedPairing(for: mac) {
                                        Text("Previously paired").font(.caption).foregroundStyle(CompanionStyle.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selectedMacID == mac.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedMacID == mac.id ? CompanionStyle.yellow : CompanionStyle.secondary)
                            }
                            .padding(13)
                            .background(Color.white.opacity(selectedMacID == mac.id ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedMacID == mac.id ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var pairingCard: some View {
        ShelfCard {
            VStack(alignment: .leading, spacing: 16) {
                ShelfSectionTitle(title: "2. Pair securely", detail: "ONE-TIME SETUP")
                if let mac = selectedMac, client.hasSavedPairing(for: mac), pairingCode.isEmpty {
                    Label("Pairing saved for \(mac.name)", systemImage: "key.fill")
                        .font(.subheadline).foregroundStyle(CompanionStyle.cyan)
                    Text("Connect using the saved code, or enter a new code if it changed on your Mac.")
                        .font(.caption).foregroundStyle(CompanionStyle.secondary)
                } else {
                    Text("Copy the pairing code shown on your Mac. Only devices with this code can connect.")
                        .font(.subheadline).foregroundStyle(CompanionStyle.secondary)
                }
                HStack {
                    Group {
                        if showCode { TextField("sb1-…", text: $pairingCode) }
                        else { SecureField("Pairing code", text: $pairingCode) }
                    }
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .accessibilityIdentifier("pairingCode")
                    Button { showCode.toggle() } label: {
                        Image(systemName: showCode ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(showCode ? "Hide pairing code" : "Show pairing code")
                }
                .padding(14)
                .background(CompanionStyle.background, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { pairingCode = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.titleAndIcon)
                    Spacer()
                    if busy { ProgressView().tint(CompanionStyle.yellow) }
                    Button("Connect", systemImage: "link") { connect() }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.black)
                        .disabled(!canConnect || busy)
                        .accessibilityIdentifier("connectMac")
                }
            }
        }
    }

    private var canConnect: Bool {
        guard let mac = selectedMac else { return false }
        return BridgePairingCode.isValid(pairingCode) || (pairingCode.isEmpty && client.hasSavedPairing(for: mac))
    }

    private var enabledFeatureCount: Int {
        let grants = client.capabilities
        return [grants.allowFocus, grants.allowSnap, grants.allowClose, grants.allowCopyToMac,
                grants.allowPasteToMac, grants.shareClipboard, grants.shareClipboardImages,
                grants.shareWindowPreviews, grants.shareScreenshots].filter { $0 }.count
    }

    private var discoveryMessage: String {
        if case .failed(let message) = client.phase { return message }
        return "Looking for nearby Macs. Allow Local Network access when asked."
    }

    private func connect() {
        guard let mac = selectedMac, canConnect, !busy else { return }
        client.connect(to: mac, pairingCode: pairingCode)
        pairingCode = ""
    }
}
