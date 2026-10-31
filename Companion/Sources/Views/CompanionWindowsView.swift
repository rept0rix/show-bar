import SwiftUI
import UIKit

struct CompanionWindowsView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var confirmClose = false
    @AppStorage(CompanionPreferences.confirmWindowClose) private var confirmWindowClose = true
    @AppStorage(CompanionPreferences.showWindowPreviews) private var showWindowPreviews = true

    private var windows: [BridgeWindow] { client.snapshot?.windows ?? [] }
    private var selectedWindow: BridgeWindow? { windows.first { $0.id == client.selectedWindowID } }
    private var canControl: Bool { client.isConnected && !client.isDemo && client.snapshot?.permissions.accessibility == true }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if client.isConnected, client.snapshot?.permissions.accessibility == false {
                        PermissionNote(title: "Window control needs permission", detail: "On your Mac, enable Show Bar in System Settings → Privacy & Security → Accessibility.")
                    }
                    if client.isConnected, client.snapshot?.capabilities == nil {
                        PermissionNote(title: "Update Show Bar on your Mac", detail: "This Mac does not report individual feature settings. Update the Mac app before using remote controls.")
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            windowSection(compact: false)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            snapPad
                                .frame(width: min(360, (geometry.size.width - 44) * 0.43))
                        }
                    } else {
                        windowSection(compact: true)
                        snapPad
                    }
                }
                .padding(22)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
            .refreshable { client.refresh() }
        }
        .confirmationDialog("Close this Mac window?", isPresented: $confirmClose, titleVisibility: .visible) {
            if let selectedWindow {
                Button("Close \(selectedWindow.title)", role: .destructive) { client.close(selectedWindow) }
            }
        } message: {
            Text("The app on your Mac may ask you to save unsaved work.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(client.snapshot?.hostName ?? "A little more room to work.")
                    .font(.title2.weight(.bold))
                Text(client.isDemo ? "Demo workspace · connect your Mac to use controls" : "Choose a window, then put it in its place.")
                    .font(.subheadline).foregroundStyle(CompanionStyle.secondary)
            }
            Spacer()
            Button { client.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered).disabled(!client.isConnected || client.isDemo)
                .accessibilityLabel("Refresh Mac windows")
        }
    }

    private func windowSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfSectionTitle(title: "Open windows", detail: "\(windows.count) WINDOWS")
            if windows.isEmpty {
                ShelfEmptyState(symbol: "rectangle.3.group", title: client.isConnected ? "No windows yet" : "Bring your Mac into the picture", detail: client.isConnected ? "Open an app window on your Mac, then refresh." : "Pair from Connect to see and arrange the windows on your Mac.")
            } else if compact {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(windows) { window in
                            windowCard(window, compact: true).frame(width: 220)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .accessibilityHint("Swipe horizontally to choose another Mac window")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(windows) { window in
                        windowCard(window, compact: false)
                    }
                }
            }
        }
    }

    private func windowCard(_ window: BridgeWindow, compact: Bool) -> some View {
        Button {
            client.selectedWindowID = window.id
        } label: {
            ShelfCard(accent: client.selectedWindowID == window.id) {
                VStack(alignment: .leading, spacing: compact ? 9 : 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11).fill(CompanionStyle.background)
                        if showWindowPreviews, client.capabilities.shareWindowPreviews,
                           let data = window.thumbnail, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().padding(5)
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: 32, weight: .ultraLight))
                                .foregroundStyle(CompanionStyle.secondary.opacity(0.6))
                        }
                    }
                    .frame(height: compact ? 85 : 112)
                    .clipped()
                    HStack {
                        Text(window.appName.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(0.8).foregroundStyle(CompanionStyle.cyan)
                        Spacer()
                        if client.selectedWindowID == window.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(CompanionStyle.yellow)
                        }
                    }
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(2).frame(minHeight: compact ? 34 : 40, alignment: .topLeading)
                    Text(window.isCurrent ? "On this desktop" : "Another desktop")
                        .font(.caption2).foregroundStyle(CompanionStyle.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(window.appName), \(window.title)")
        .accessibilityHint("Select this window for focus, layout, or close controls")
        .accessibilityAddTraits(client.selectedWindowID == window.id ? .isSelected : [])
    }

    private var snapPad: some View {
        ShelfCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Snap pad").font(.title3.weight(.semibold))
                    Spacer()
                    Text(selectedWindow?.appName ?? "SELECT A WINDOW")
                        .font(.caption).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    snapButton("Top left", zone: "topLeft", symbol: "rectangle.inset.topleft.filled")
                    snapButton("Top", zone: "top", symbol: "rectangle.tophalf.filled")
                    snapButton("Top right", zone: "topRight", symbol: "rectangle.inset.topright.filled")
                    snapButton("Left", zone: "left", symbol: "rectangle.lefthalf.filled")
                    snapButton("Fill", zone: "maximize", symbol: "arrow.up.left.and.arrow.down.right")
                    snapButton("Right", zone: "right", symbol: "rectangle.righthalf.filled")
                    snapButton("Bottom left", zone: "bottomLeft", symbol: "rectangle.inset.bottomleft.filled")
                    snapButton("Bottom", zone: "bottom", symbol: "rectangle.bottomhalf.filled")
                    snapButton("Bottom right", zone: "bottomRight", symbol: "rectangle.inset.bottomright.filled")
                }
                .disabled(!canControl || !client.capabilities.allowSnap || selectedWindow == nil)
                HStack(spacing: 12) {
                    Button {
                        if let selectedWindow { client.focus(selectedWindow) }
                    } label: {
                        Label("Focus window", systemImage: "scope")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .disabled(!canControl || !client.capabilities.allowFocus || selectedWindow == nil)
                    Button(role: .destructive) {
                        if confirmWindowClose { confirmClose = true }
                        else if let selectedWindow { client.close(selectedWindow) }
                    } label: {
                        Image(systemName: "xmark.rectangle").padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Close selected Mac window")
                    .disabled(!canControl || !client.capabilities.allowClose || selectedWindow == nil)
                }
                Text("Repeat a layout to restore the window’s previous size.")
                    .font(.caption2).foregroundStyle(CompanionStyle.secondary)
                if client.isConnected, !client.capabilities.allowSnap || !client.capabilities.allowFocus || !client.capabilities.allowClose {
                    Text("Some controls are disabled on your Mac. Change individual features in Show Bar → Companion devices, or view their status in Settings here.")
                        .font(.caption2).foregroundStyle(CompanionStyle.secondary)
                }
            }
        }
    }

    private func snapButton(_ title: String, zone: String, symbol: String) -> some View {
        Button { client.snap(zone) } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 21, weight: .light))
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 67)
            .foregroundStyle(zone == "maximize" ? CompanionStyle.yellow : .white)
            .background(CompanionStyle.background, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Move selected Mac window: \(title)")
        .keyboardShortcut(shortcut(for: zone), modifiers: [.command, .option])
    }

    private func shortcut(for zone: String) -> KeyEquivalent {
        let keys: [String: KeyEquivalent] = [
            "left": .leftArrow, "right": .rightArrow, "top": .upArrow, "bottom": .downArrow,
            "topLeft": "u", "topRight": "i", "bottomLeft": "j", "bottomRight": "k",
            "maximize": KeyEquivalent("\r")
        ]
        return keys[zone] ?? KeyEquivalent("\r")
    }
}
