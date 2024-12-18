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
                    (isLogWindowVisible, { self.isLogWindowVisible = $0 }))
        }
        .commands {
            CommandGroup(replacing: .newItem) {}  // Remove default New menu item
            CommandGroup(replacing: .saveItem) {}  // Remove default Save menu items
        }

        Window("Logs", id: "logWindow") {
            LogView()
                .environmentObject(logManager)
        }
        .defaultSize(CGSize(width: 600, height: 300))
        .keyboardShortcut("L", modifiers: [.command, .shift])
        .windowResizability(.contentSize)
    }
}
