import SwiftUI

@MainActor
class LogManager: ObservableObject {
    static let shared = LogManager()
    @Published var logs: [String] = []

    private init() {}

    nonisolated func addLog(_ message: String) {
        Task { @MainActor in
            let newLogs = message.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            self.logs.append(contentsOf: newLogs)
        }
    }

    func getAllLogs() -> String {
        return logs.joined(separator: "\n")
    }
}

struct LogWindowVisibilityKey: EnvironmentKey {
    static let defaultValue: (Bool, @Sendable (Bool) -> Void) = (false, { _ in })
}

extension EnvironmentValues {
    var logWindowVisibility: (isVisible: Bool, update: @Sendable (Bool) -> Void) {
        get { self[LogWindowVisibilityKey.self] }
        set { self[LogWindowVisibilityKey.self] = newValue }
    }
}

struct LogView: View {
    @EnvironmentObject var logManager: LogManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.logWindowVisibility) private var logWindowVisibility

    @State private var scrollProxy: ScrollViewProxy?
    @State private var showCopyConfirmation = false

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logManager.getAllLogs())
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logContent")
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onAppear {
                    scrollProxy = proxy
                    scrollToBottom()
                }
            }
        }
        .onChange(of: logManager.logs) { _ in
            scrollToBottom()
        }
        HStack {
            Spacer()
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .opacity(showCopyConfirmation ? 1 : 0)
                    .scaleEffect(showCopyConfirmation ? 1 : 0.5)
                Button("Copy Logs") {
                    copyLogs()
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])
            }

            Button("Close") {
                dismiss()
                logWindowVisibility.update(false)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .padding()
        }
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logManager.getAllLogs(), forType: .string)

        withAnimation(.easeInOut(duration: 0.2)) {
            showCopyConfirmation = true
        }

        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopyConfirmation = false
            }
        }
    }

    private func scrollToBottom() {
        Task {
            withAnimation {
                scrollProxy?.scrollTo("logContent", anchor: .bottom)
            }
        }
    }
}
