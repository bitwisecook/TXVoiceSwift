import SwiftUI
import SwiftTinyLoggerWindow

@main
struct TXVoiceApp: App {
    @State private var logger = AppLogger(
        appName: "TXVoice",
        subsystem: "com.bragi0.TXVoice",
        debugEmailAddress: DeveloperConfig.debugEmailAddress
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(logger)
                .onAppear {
                    logVersionAndBuild()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
        }

        Window("Log", id: "logWindow") {
            LogView(logger: logger)
        }
        .defaultSize(CGSize(width: 700, height: 400))
        .keyboardShortcut("L", modifiers: [.command, .shift])
    }

    private func logVersionAndBuild() {
        let version =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "Unknown"
        logger.log(.info, phase: "APP", "TXVoice starting up - Version: \(version), Build: \(build)")
    }
}
