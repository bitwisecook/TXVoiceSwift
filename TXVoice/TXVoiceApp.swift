import SwiftUI

@main
struct TXVoiceApp: App {
    @StateObject private var logManager = LogManager.shared
    @State private var isLogWindowVisible = false

    init() {
        logVersionAndBuild()
    }

    private func logVersionAndBuild() {
        let version =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "Unknown"
        LogManager.shared.addLog(
            "TXVoice starting up - Version: \(version), Build: \(build)")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logManager)
                .environment(
                    \.logWindowVisibility,
                    (isLogWindowVisible, { @Sendable newValue in
                        Task { @MainActor in
                            self.isLogWindowVisible = newValue
                        }
                    }))
        }
        .commands {
            CommandGroup(replacing: .newItem) {}  // Remove default New menu item
            CommandGroup(replacing: .saveItem) {}  // Remove default Save menu items
        }

        Window("Logs", id: "logWindow") {
            LogView()
                .environmentObject(logManager)
        }
        .defaultSize(width: 600, height: 300)
        .windowResizability(.contentSize)
    }
}
