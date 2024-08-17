import SwiftUI

@main
struct TaranisVoiceApp: App {
    @StateObject private var logManager = LogManager.shared
    @State private var showLogWindow = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logManager)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }  // Remove default New menu item
            CommandGroup(replacing: .saveItem) { }  // Remove default Save menu items
            
            CommandMenu("View") {
                Button("Show Logs") {
                    showLogWindow.toggle()
                    if showLogWindow {
                        openLogWindow()
                    }
                }
                .keyboardShortcut("L", modifiers: .command)
            }
        }
        
        WindowGroup("Logs") {
            LogView()
        }
        .defaultSize(CGSize(width: 600, height: 300))
        .keyboardShortcut("L", modifiers: [.command, .shift])
    }
    
    private func openLogWindow() {
        DispatchQueue.main.async {
            if let logWindow = NSApp.windows.first(where: { $0.title == "Logs" }) {
                logWindow.makeKeyAndOrderFront(nil)
            } else {
                let logWindow = NSWindow(
                    contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                logWindow.title = "Logs"
                logWindow.contentView = NSHostingView(rootView: LogView().environmentObject(logManager))
                logWindow.makeKeyAndOrderFront(nil)
            }
        }
    }
}
