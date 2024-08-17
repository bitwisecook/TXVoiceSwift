import AVFoundation
import SwiftUI

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

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async -> Bool {
        return await synthesizer.speak(text, voice: voice)
    }

    func speakAndSave(_ text: String, voice: AVSpeechSynthesisVoice) async
        -> Bool
    {
        return await synthesizer.speakAndSave(text, voice: voice)
    }

    func startRecording(to url: URL) async throws {
        try await synthesizer.startRecording(to: url)
        isRecording = await synthesizer.isRecording
    }

    func stopRecording() async {
        await synthesizer.stopRecording()
        isRecording = await synthesizer.isRecording
    }
}

struct ContentView: View {
    @State private var inputText: String = "Terrain, pull up!"
    @State private var selectedVoice: AVSpeechSynthesisVoice
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @StateObject private var viewModel = SpeechSynthesizerViewModel()
    @State private var isSaving = false
    @State private var isTemporarilyDisabled = false
    @State private var showDoneMessage = false
    @State private var doneOpacity: Double = 1.0
    @State private var selectedSampleRate: SampleRate = .default
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
                        await viewModel.speak(inputText, voice: selectedVoice)
                    }
                }
                .disabled(isSaving || isTemporarilyDisabled)

                Button("Save to .wav") {
                    showSaveDialog()
                }
                .disabled(isSaving || isTemporarilyDisabled)
            }

            // Divider line
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, -20)

            ZStack {
                if isSaving {
                    ProgressView(value: viewModel.progress) {
                        Text("Saving... \(Int(viewModel.progress * 100))%")
                    }
                    .progressViewStyle(LinearProgressViewStyle())
                } else if showDoneMessage {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 24))
                        .bold()
                        .opacity(doneOpacity)
                } else {
                    Text("idle")
                        .foregroundColor(
                            .init(hue: 1.0, saturation: 0.0, brightness: 0.3))
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
                        isSaving = true
                        try await viewModel.startRecording(to: url)
                        _ = await viewModel.speakAndSave(
                            inputText, voice: selectedVoice)
                        await viewModel.stopRecording()
                        isSaving = false
                        isTemporarilyDisabled = true
                        showDoneMessage = true

                        // Re-enable buttons after 500ms
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isTemporarilyDisabled = false
                        }

                        // Fade out "Done" message after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(.easeOut(duration: 1)) {
                                doneOpacity = 0
                            }
                        }

                        // Hide "Done" message after fade-out
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            showDoneMessage = false
                            doneOpacity = 1
                        }
                    } catch {
                        print("Failed to record: \(error)")
                        isSaving = false
                    }
                }
            }
        }
    }

    private func generateDefaultFilename(from text: String) -> String {
        let latinizedText =
            text.applyingTransform(.toLatin, reverse: false) ?? text
        let cleanedText = latinizedText.components(
            separatedBy: CharacterSet.letters.inverted
        ).joined()
        let underscored = cleanedText.replacingOccurrences(of: " ", with: "_")
        return underscored.isEmpty ? "speech.wav" : "\(underscored).wav"
    }
}
