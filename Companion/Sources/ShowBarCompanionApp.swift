import SwiftUI

@main
@MainActor
struct ShowBarCompanionApp: App {
    @StateObject private var client: CompanionClient
    @StateObject private var shelf = CompanionShelf()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let client = CompanionClient()
        // Prepare sample mode before any connection view can start discovery.
        if ProcessInfo.processInfo.arguments.contains("--demo") { client.loadDemo() }
        _client = StateObject(wrappedValue: client)
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(client)
                .environmentObject(shelf)
                .preferredColorScheme(.dark)
                .tint(CompanionStyle.yellow)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    client.setActive(phase == .active)
                }
        }
    }
}
