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

    static var `default`: SampleRate { .rate16kHz }
}

struct VoiceGroup: Identifiable {
    let id = UUID()
    let name: String
    var voices: [AVSpeechSynthesisVoice]
    let isNovelty: Bool
    let isPrimaryLanguage: Bool
}

struct ColoredSFSymbol: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .foregroundColor(color)
            .symbolRenderingMode(.palette)
    }
}

struct VoicePickerView: View {
    @Binding var selection: AVSpeechSynthesisVoice
    let voiceGroups: [VoiceGroup]

    var body: some View {
        Menu {
            ForEach(voiceGroups) { group in
                Section(header: Text(group.name).foregroundColor(.secondary)) {
                    ForEach(group.voices, id: \.identifier) { voice in
                        Button(action: {
                            selection = voice
                        }) {
                            HStack {
                                Text(voice.name)
                                Spacer()
                                if voice == selection {
                                    ColoredSFSymbol(
                                        systemName: "checkmark",
                                        color: .accentColor
                                    )
                                } else if voice.quality == .premium {
                                    ColoredSFSymbol(
                                        systemName: "waveform.badge.plus",
                                        color: Color("VoiceMenuPremiumColor")
                                    )
                                } else if voice.quality == .enhanced {
                                    ColoredSFSymbol(
                                        systemName: "waveform.badge.plus",
                                        color: Color("VoiceMenuEnhancedColor")
                                    )
                                } else {
                                    ColoredSFSymbol(
                                        systemName: "waveform",
                                        color: Color("VoiceMenuStandardColor")
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(selection.name)
                if selection.quality == .premium {
                    ColoredSFSymbol(
                        systemName: "waveform.badge.plus",
                        color: Color("VoiceMenuPremiumColor")
                    )
                } else if selection.quality == .enhanced {
                    ColoredSFSymbol(
                        systemName: "waveform.badge.plus",
                        color: Color("VoiceMenuEnhancedColor")
                    )
                }
            }
        }
    }
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
    @State private var groupedVoices: [VoiceGroup] = []
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
        _selectedVoice = State(initialValue: voices.first!)
        _groupedVoices = State(initialValue: Self.groupVoices(voices))

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
            VStack {
                HStack {
                    Text("Voice")
                    Spacer()
                    VoicePickerView(
                        selection: $selectedVoice, voiceGroups: groupedVoices)
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
                                .foregroundColor(Color("MainStatusIdleColor"))
                        case .saving:
                            Image("custom.waveform.badge.arrow.down")
                                .foregroundColor(Color("MainStatusSavingColor"))
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

    private static func groupVoices(_ voices: [AVSpeechSynthesisVoice])
        -> [VoiceGroup]
    {
        let currentLanguage = Locale.current.language
        let currentLanguageCode =
            currentLanguage.languageCode?.identifier ?? "en"
        let currentRegion = currentLanguage.region?.identifier ?? ""

        let noveltyVoices = [
            "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
            "Good News", "Jester", "Organ", "Trinoids", "Whisper", "Wobble",
            "Zarvox",
        ]

        let filteredVoices = voices.filter { voice in
            voice.language.hasPrefix(currentLanguageCode)
                || noveltyVoices.contains(voice.name)
        }

        let groupedVoices = Dictionary(grouping: filteredVoices) {
            voice -> String in
            if noveltyVoices.contains(voice.name) {
                return "Novelty"
            } else {
                return Locale.current.localizedString(
                    forIdentifier: voice.language) ?? voice.language
            }
        }

        let sortedGroups = groupedVoices.map { key, value in
            let isPrimaryLanguage = value.contains {
                $0.language == "\(currentLanguageCode)-\(currentRegion)"
            }
            let sortedVoices = value.sorted { v1, v2 in
                if v1.quality != v2.quality {
                    return v1.quality.rawValue > v2.quality.rawValue
                } else {
                    return v1.name < v2.name
                }
            }
            return VoiceGroup(
                name: key, voices: sortedVoices, isNovelty: key == "Novelty",
                isPrimaryLanguage: isPrimaryLanguage)
        }.sorted { group1, group2 in
            if group1.isNovelty {
                return false
            } else if group2.isNovelty {
                return true
            } else if group1.isPrimaryLanguage {
                return true
            } else if group2.isPrimaryLanguage {
                return false
            } else {
                return group1.name < group2.name
            }
        }

        return sortedGroups
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

    private func transliterate(_ input: String) -> String {
        let mutableString = NSMutableString(string: input)
        CFStringTransform(mutableString, nil, kCFStringTransformToLatin, false)
        CFStringTransform(
            mutableString, nil, kCFStringTransformStripDiacritics, false
        )
        return mutableString as String
    }

    private func generateDefaultFilename(from text: String) -> String {
        // Step 1: Transliterate to Latin characters
        let transliterated = transliterate(text)

        // Step 2: Convert to lowercase and replace non-alphanumeric characters with underscores
        let alphanumeric = CharacterSet.alphanumerics
        var cleanedText = ""
        var needsUnderscore = false

        for scalar in transliterated.lowercased().unicodeScalars {
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
