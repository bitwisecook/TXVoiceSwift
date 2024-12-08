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

struct ContentView: View {
    @State private var inputText: String = "Terrain, pull up!"
    @State private var selectedVoice: AVSpeechSynthesisVoice
    @State private var groupedVoices: [VoiceGroup] = []
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @StateObject private var viewModel = SpeechSynthesizerViewModel()
    @State private var showDoneMessage = false
    @State private var doneOpacity: Double = 1.0
    @State private var selectedSampleRate: SampleRate = .default
    @State private var statusOpacity: Double = 1.0
    @State private var isAnimating: Bool = false
    @State private var animationTimer: Timer?
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
            Image("TXVoiceLogo")
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
                        await preview()
                    }
                }
                .disabled(viewModel.status != .idle)

                Button("Save to .wav") {
                    Task {
                        await saveToWav()
                    }
                }
                .disabled(viewModel.status != .idle)
            }

            // Divider line
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, -20)

            // Status
            ZStack {
                Group {
                    switch viewModel.status {
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
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            LogManager.shared.addLog(
                "Status changed from \(oldStatus) to \(newStatus)")
            animateStatusChange(newStatus)
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

    private func preview() async {
        await viewModel.speak(inputText, voice: selectedVoice)
    }

    private func saveToWav() async {
        LogManager.shared.addLog("Starting saveToWav operation")
        if let url = await showSaveDialog() {
            LogManager.shared.addLog("Save dialog confirmed")
            await viewModel.speakAndSave(
                inputText, voice: selectedVoice, to: url)
            if viewModel.status == .success {
                LogManager.shared.addLog(
                    "Save operation completed successfully")
            } else {
                LogManager.shared.addLog("Save operation failed")
            }
        } else {
            LogManager.shared.addLog("Save dialog cancelled")
            viewModel.status = .idle
        }
    }

    private func showSaveDialog() async -> URL? {
        await withCheckedContinuation { continuation in
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.wav]
            savePanel.canCreateDirectories = true
            savePanel.isExtensionHidden = false
            savePanel.title = "Save Speech as WAV"
            savePanel.message = "Choose a location to save the speech file"
            savePanel.nameFieldStringValue = generateDefaultFilename(
                from: inputText)

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func animateStatusChange(_ newStatus: SaveStatus) {
        withAnimation(.easeInOut(duration: 0.3)) {
            statusOpacity = 1.0
        }

        switch newStatus {
        case .success:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.statusOpacity = 0
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.viewModel.status = .idle
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.statusOpacity = 1.0
                }
            }
        case .failure:
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.statusOpacity = 0
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.viewModel.status = .idle
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.statusOpacity = 1.0
                }
            }
        case .idle:
            do {}
        case .previewing:
            do {}
        case .saving:
            do {}
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
