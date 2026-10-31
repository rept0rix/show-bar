import SwiftUI
import UIKit

enum CompanionSection: String, CaseIterable, Identifiable {
    case windows = "Windows"
    case clipboard = "Clipboard"
    case shots = "Shots"
    case connection = "Connect"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .windows: return "rectangle.3.group"
        case .clipboard: return "doc.on.clipboard"
        case .shots: return "viewfinder"
        case .connection: return "personalhotspot"
        }
    }
}

struct CompanionRootView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var shelf: CompanionShelf
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: CompanionSection = ProcessInfo.processInfo.arguments.contains("--demo") ? .windows : .connection
    @State private var deskMode = false
    @State private var presentedFeedback: String?
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 850 {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 210)
                    Divider().overlay(Color.white.opacity(0.05))
                    navigationContent
                }
                .background(CompanionStyle.background)
            } else {
                TabView(selection: $section) {
                    ForEach(CompanionSection.allCases) { item in
                        NavigationStack {
                            sectionContent(item)
                                .navigationTitle(item.rawValue)
                                .toolbar { connectionToolbar }
                        }
                        .tabItem { Label(item.rawValue, systemImage: item.symbol) }
                        .tag(item)
                    }
                }
            }
        }
        .background(CompanionStyle.background)
        .sheet(isPresented: $showSettings) {
            CompanionSettingsView(deskMode: $deskMode)
        }
        .overlay(alignment: .bottom) {
            if let feedback = presentedFeedback {
                Text(feedback)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: 600)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 75)
                    .accessibilityAddTraits(.updatesFrequently)
                    .allowsHitTesting(false)
            }
        }
        .task(id: client.feedback) {
            presentedFeedback = client.feedback
            guard client.feedback != nil else { return }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            presentedFeedback = nil
        }
        .alert("Show Bar", isPresented: Binding(
            get: { client.errorMessage != nil },
            set: { if !$0 { client.clearError() } }
        )) {
            Button("OK", role: .cancel) { client.clearError() }
        } message: {
            Text(client.errorMessage ?? "")
        }
        .onChange(of: client.isConnected) { _, connected in
            if connected && section == .connection { section = .windows }
        }
        .onChange(of: client.isDemo) { _, demo in
            if demo { section = .windows }
        }
        .onChange(of: deskMode) { _, enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled && scenePhase == .active
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = deskMode && phase == .active
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onOpenURL { url in
            handleOpenURL(url)
        }
        .background {
            VStack {
                Button("Windows") { section = .windows }.keyboardShortcut("1", modifiers: .command)
                Button("Clipboard") { section = .clipboard }.keyboardShortcut("2", modifiers: .command)
                Button("Shots") { section = .shots }.keyboardShortcut("3", modifiers: .command)
                Button("Connect") { section = .connection }.keyboardShortcut("4", modifiers: .command)
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    private var navigationContent: some View {
        NavigationStack {
            sectionContent(section)
                .navigationTitle(section.rawValue)
                .toolbar { connectionToolbar }
        }
    }

    @ViewBuilder private func sectionContent(_ section: CompanionSection) -> some View {
        Group {
            switch section {
            case .windows: CompanionWindowsView()
            case .clipboard: CompanionClipboardView()
            case .shots: CompanionShotsView()
            case .connection: CompanionConnectionView(deskMode: $deskMode)
            }
        }
        .background(CompanionStyle.background)
    }

    @ToolbarContentBuilder private var connectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings and permissions")
            .accessibilityIdentifier("settingsAndPermissions")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { section = .connection } label: {
                HStack(spacing: 6) {
                    Circle().fill(client.isDemo ? CompanionStyle.yellow : client.isConnected ? CompanionStyle.cyan : .gray).frame(width: 6, height: 6)
                    Text(client.isDemo ? "Demo" : client.isConnected ? "Connected" : "Offline")
                        .font(.caption.weight(.medium))
                }
            }
            .accessibilityLabel("Connection: \(client.isDemo ? "demo" : client.isConnected ? "connected" : "offline")")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "rectangle.bottomhalf.inset.filled")
                    .font(.system(size: 30)).foregroundStyle(CompanionStyle.yellow)
                Text("Show Bar").font(.title2.weight(.bold))
                Text("YOUR MAC, WITHIN REACH")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.0).foregroundStyle(CompanionStyle.secondary)
            }
            VStack(spacing: 6) {
                ForEach(CompanionSection.allCases) { item in
                    Button { section = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 13)
                            .foregroundStyle(section == item ? CompanionStyle.yellow : CompanionStyle.secondary)
                            .background(section == item ? CompanionStyle.yellow.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if client.isDemo {
                Label("Demo workspace", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(CompanionStyle.yellow)
            }
            Label("Local. Encrypted. Yours.", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(CompanionStyle.secondary)
        }
        .padding(22)
        .padding(.top, 12)
        .background(CompanionStyle.surface.opacity(0.5))
    }

    private func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "showbar" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var importedText: String?

        if let textItem = components?.queryItems?.first(where: { $0.name == "text" })?.value, !textItem.isEmpty {
            importedText = textItem
        } else if let urlItem = components?.queryItems?.first(where: { $0.name == "url" })?.value, !urlItem.isEmpty {
            importedText = urlItem
        } else if let host = url.host, host != "shelf" && host != "import" {
            importedText = host
        }

        if let text = importedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if shelf.add(text) {
                section = .clipboard
                presentedFeedback = "Imported to local shelf"
            }
        }
    }
}
