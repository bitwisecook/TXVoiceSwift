import SwiftUI

@main
struct TaranisVoiceApp: App {
    @StateObject private var logManager = LogManager.shared
    @State private var isLogWindowVisible = false

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
