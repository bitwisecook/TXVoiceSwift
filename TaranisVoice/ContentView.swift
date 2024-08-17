import AVFoundation
import SwiftUI

enum SaveStatus {
    case idle
    case previewing
    case saving
    case success
    case failure
}

enum SampleRate: Int, CaseIterable, Identifiable {
    case rate8kHz = 8000
    case rate16kHz = 16000
    case rate32kHz = 32000

    var id: Int { self.rawValue }

    var description: String {
        switch self {
        case .rate8kHz: return "8 kHz"
        case .rate16kHz: return "16 kHz"
        case .rate32kHz: return "32 kHz"
        }
    }

    static var `default`: SampleRate { .rate32kHz }
}

@MainActor
class SpeechSynthesizerViewModel: ObservableObject {
    @Published var isPreviewInProgress = false
    @Published var isRecording = false
    @Published var progress: Double = 0.0
    @Published var selectedSampleRate: SampleRate = .default
    private let synthesizer: SpeechSynthesizer

    func setSampleRate(_ sampleRate: SampleRate) async {
        await synthesizer.setSampleRate(sampleRate)
        selectedSampleRate = sampleRate
    }

    init() {
        synthesizer = SpeechSynthesizer()
        Task {
            for await newProgress in await synthesizer.$progress.values {
                self.progress = newProgress
            }
        }
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async {
        isPreviewInProgress = true
        defer { isPreviewInProgress = false }
        await synthesizer.speak(text, voice: voice)
    }

    func speakAndSave(_ text: String, voice: AVSpeechSynthesisVoice)
        async throws -> Bool
    {
        return try await synthesizer.speakAndSave(text, voice: voice)
    }

    func startRecording(to url: URL) async throws {
        try await synthesizer.startRecording(to: url)
        isRecording = await synthesizer.isRecording
    }

    func stopRecording() async throws {
        try await synthesizer.stopRecording()
        isRecording = await synthesizer.isRecording
    }
}

struct ContentView: View {
    @State private var inputText: String = "Terrain, pull up!"
    @State private var selectedVoice: AVSpeechSynthesisVoice
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @StateObject private var viewModel = SpeechSynthesizerViewModel()
    @State private var isSaveInProgress = false
    @State private var isTemporarilyDisabled = false
    @State private var showDoneMessage = false
    @State private var doneOpacity: Double = 1.0
    @State private var selectedSampleRate: SampleRate = .default
    @State private var saveStatus: SaveStatus = .idle
    @State private var statusOpacity: Double = 1.0
    @EnvironmentObject private var logManager: LogManager
    @Environment(\.logWindowVisibility) private var logWindowVisibility
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        _availableVoices = State(initialValue: voices)

        let savedVoiceIdentifier = UserDefaults.standard.string(
            forKey: "SelectedVoiceIdentifier")

        if let savedIdentifier = savedVoiceIdentifier,
            let savedVoice = voices.first(where: {
                $0.identifier == savedIdentifier
            })
        {
            _selectedVoice = State(initialValue: savedVoice)
        } else if let defaultVoice = AVSpeechSynthesisVoice(
            language: Locale.current.identifier)
        {
            _selectedVoice = State(initialValue: defaultVoice)
        } else {
            _selectedVoice = State(initialValue: voices.first!)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Image Logo
            Image("TaranisVoiceLogo")  // Make sure to add this image to your asset catalog
                .resizable()
                .scaledToFit()
                .frame(height: 120)
                .padding(.top, 10)

            // Divider line
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, -20)

            // Utterance
            TextField("Phrase", text: $inputText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()

            // Voice to use
            Picker("Select Voice", selection: $selectedVoice) {
                ForEach(availableVoices, id: \.identifier) { voice in
                    Text(voice.name).tag(voice)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .onChange(of: selectedVoice) { oldVoice, newVoice in
                UserDefaults.standard.set(
                    newVoice.identifier, forKey: "SelectedVoiceIdentifier")
            }

            // Sample rate selection
            HStack(spacing: 20) {
                ForEach(SampleRate.allCases) { rate in
                    Button(action: {
                        selectedSampleRate = rate
                        Task {
                            await viewModel.setSampleRate(rate)
                        }
                    }) {
                        Text(rate.description)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity)
                    }
                    .background(
                        selectedSampleRate == rate ? Color.blue : Color.clear
                    )
                    .foregroundColor(
                        selectedSampleRate == rate ? Color.white : Color.blue
                    )
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal)

            // Actions
            HStack {
                Button("Preview") {
                    Task {
                        saveStatus = .previewing
                        await viewModel.speak(inputText, voice: selectedVoice)
                        saveStatus = .idle
                    }
                }
                .disabled(
                    isSaveInProgress
                        || viewModel.isPreviewInProgress
                        || isTemporarilyDisabled)

                Button("Save to .wav") {
                    Task {
                        saveStatus = .saving
                        showSaveDialog()
                    }
                }
                .disabled(
                    isSaveInProgress
                        || viewModel.isPreviewInProgress
                        || isTemporarilyDisabled)
            }

            // Divider line
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, -20)

            ZStack {
                if isSaveInProgress {
                    ProgressView(value: viewModel.progress) {
                        Text("Saving... \(Int(viewModel.progress * 100))%")
                    }
                    .progressViewStyle(LinearProgressViewStyle())
                } else {
                    Group {
                        switch saveStatus {
                        case .idle:
                            Text("idle")
                                .foregroundColor(.gray)
                        case .saving:
                            Image("custom.waveform.badge.arrow.down")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 24))
                        case .failure:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 24))
                        case .previewing:
                            Image(systemName: "speaker.wave.2.bubble")
                                .foregroundColor(.orange)
                                .font(.system(size: 24))
                        }
                    }
                    .opacity(statusOpacity)
                }
            }
            .frame(height: 30)
            .padding(.vertical, 10)
        }
        .padding()
        .frame(width: 400)
        .onChange(of: logWindowVisibility.isVisible) { oldValue, newValue in
            if newValue {
                openWindow(id: "logWindow")
            } else {
                dismissWindow(id: "logWindow")
            }
        }
    }

    private func showSaveDialog() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.wav]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.title = "Save Speech as WAV"
        savePanel.message = "Choose a location to save the speech file"
        savePanel.nameFieldStringValue = generateDefaultFilename(
            from: inputText)

        savePanel.beginSheetModal(for: NSApp.keyWindow!) { response in
            if response == .OK, let url = savePanel.url {
                Task {
                    do {
                        isSaveInProgress = true
                        saveStatus = .saving
                        try await viewModel.startRecording(to: url)
                        _ = try await viewModel.speakAndSave(
                            inputText, voice: selectedVoice)
                        try await viewModel.stopRecording()
                        isSaveInProgress = false
                        saveStatus = .success
                        statusOpacity = 1.0

                        // Show success status for 2 seconds
                        withAnimation(.easeInOut(duration: 0.5).delay(2)) {
                            statusOpacity = 0
                        }

                        // Reset to idle after fading out
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            saveStatus = .idle
                            statusOpacity = 1.0
                        }
                    } catch {
                        LogManager.shared.addLog("Error occurred: \(error)")
                        isSaveInProgress = false
                        saveStatus = .failure
                        statusOpacity = 1.0

                        // Show failure status for 5 seconds
                        withAnimation(.easeInOut(duration: 0.5).delay(5)) {
                            statusOpacity = 0
                        }

                        // Reset to idle after fading out
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                            saveStatus = .idle
                            statusOpacity = 1.0
                        }
                    }
                }
            }
        }
    }

    private func generateDefaultFilename(from text: String) -> String {
        // Step 1: Normalize the string to remove diacritics
        let normalized = text.folding(
            options: .diacriticInsensitive, locale: .current)

        // Step 2: Convert to lowercase and replace non-alphanumeric characters with underscores
        let alphanumeric = CharacterSet.alphanumerics
        var cleanedText = ""
        var needsUnderscore = false

        for scalar in normalized.lowercased().unicodeScalars {
            if alphanumeric.contains(scalar) {
                if needsUnderscore {
                    cleanedText += "_"
                    needsUnderscore = false
                }
                cleanedText.unicodeScalars.append(scalar)
            } else if scalar.properties.isEmoji {
                if needsUnderscore {
                    cleanedText += "_"
                }
                cleanedText +=
                    scalar.properties.name?.lowercased().replacingOccurrences(
                        of: " ", with: "_") ?? ""
                needsUnderscore = true
            } else {
                needsUnderscore = true
            }
        }

        // Step 3: Remove leading/trailing underscores and collapse multiple underscores
        cleanedText = cleanedText.trimmingCharacters(
            in: CharacterSet(charactersIn: "_"))
        while cleanedText.contains("__") {
            cleanedText = cleanedText.replacingOccurrences(of: "__", with: "_")
        }

        // Step 4: Truncate if the filename is too long (leaving room for .wav extension)
        let maxLength = 255 - 4  // Maximum filename length minus .wav
        let truncatedText = cleanedText.prefix(maxLength)

        return truncatedText.isEmpty ? "speech.wav" : "\(truncatedText).wav"
    }
}
