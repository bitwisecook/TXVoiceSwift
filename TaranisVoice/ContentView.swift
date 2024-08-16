import AVFoundation
import AppKit
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

actor SpeechSynthesizer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate
{
    let synthesizer: AVSpeechSynthesizer
    var audioFile: AVAudioFile?

    @Published var isRecording = false
    @Published var progress: Double = 0.0
    private var outputURL: URL?
    private var audioEngine: AVAudioEngine
    private var mainMixerNode: AVAudioMixerNode
    private var totalSamples: Int = 0
    private var processedSamples: Int = 0
    private var estimatedTotalSamples: Int = 0

    override init() {
        self.synthesizer = AVSpeechSynthesizer()
        self.audioEngine = AVAudioEngine()
        self.mainMixerNode = self.audioEngine.mainMixerNode
        super.init()
        self.synthesizer.delegate = self
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async -> Bool {
        return await withCheckedContinuation { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.volume = 1.0

            synthesizer.speak(utterance)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(returning: true)
            }
        }
    }

    func speakAndSave(_ text: String, voice: AVSpeechSynthesisVoice) async -> Bool {
        print("Starting speakAndSave")
        let utterance = createUtterance(text: text, voice: voice)
        print("Created utterance")
        
        // Reset progress tracking
        totalSamples = 0
        processedSamples = 0
        progress = 0.0
        estimatedTotalSamples = estimateTotalSamples(for: text)
        print("Estimated total samples: \(estimatedTotalSamples)")
        
        do {
            print("Attempting to start audio engine")
            try startAudioEngine()
            print("Audio engine started successfully")
        } catch {
            print("Failed to start audio engine: \(error)")
            return false
        }
        
        return await synthesizeAndWrite(utterance: utterance)
    }

    private func createUtterance(text: String, voice: AVSpeechSynthesisVoice)
        -> AVSpeechUtterance
    {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        return utterance
    }

    private func synthesizeAndWrite(utterance: AVSpeechUtterance) async -> Bool
    {
        await withCheckedContinuation { continuation in
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self = self else { return }
                Task {
                    await self.processBuffer(buffer)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(returning: true)
            }
        }
    }

    private func processBuffer(_ buffer: AVAudioBuffer) async {
        print("Received buffer of type: \(type(of: buffer))")
        
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            print("Failed to cast buffer to AVAudioPCMBuffer")
            return
        }
        
        print("PCM Buffer frame length: \(pcmBuffer.frameLength)")
        print("PCM Buffer format: \(pcmBuffer.format)")
        
        guard pcmBuffer.frameLength > 0 else {
            print("Received empty buffer (frameLength = 0)")
            return
        }
        await writeAudioBufferToFile(pcmBuffer)
        processedSamples += Int(pcmBuffer.frameLength)
        updateProgress()
    }

    private func startAudioEngine() throws {
        print("Resetting audio engine")
        audioEngine.reset()
        
        print("Preparing audio engine")
        audioEngine.prepare()
        
        print("Starting audio engine")
        try audioEngine.start()
        print("Audio engine started")
    }

    private var selectedSampleRate: SampleRate = .default

    func setSampleRate(_ sampleRate: SampleRate) {
        selectedSampleRate = sampleRate
    }

    private func resample(
        buffer: AVAudioPCMBuffer, toSampleRate newSampleRate: Double
    ) -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: newSampleRate,
            channels: 1,
            interleaved: false)!

        guard
            let converter = AVAudioConverter(
                from: inputFormat, to: outputFormat)
        else {
            print("Failed to create audio converter")
            return buffer
        }

        let ratio = newSampleRate / inputFormat.sampleRate
        let estimatedOutputFrameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio)

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: estimatedOutputFrameCount)
        else {
            print("Failed to create output buffer")
            return buffer
        }

        var error: NSError?

        let status = converter.convert(
            to: outputBuffer,
            error: &error
        ) { inNumPackets, outStatus in
            if buffer.frameLength > 0 {
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        if let error = error {
            print("Error during conversion: \(error)")
            print("Input buffer format: \(inputFormat)")
            print("Input buffer frame length: \(buffer.frameLength)")
            print("Output buffer format: \(outputFormat)")
            print("Estimated output frame count: \(estimatedOutputFrameCount)")
            print("Conversion status: \(status)")
            return buffer
        }

        print(
            "Resampling completed. Input frames: \(buffer.frameLength), Output frames: \(outputBuffer.frameLength)"
        )

        return outputBuffer
    }

    private func writeAudioBufferToFile(_ buffer: AVAudioPCMBuffer) async {
        guard isRecording, let audioFile = audioFile else {
            print("Not recording or audioFile is nil")
            return
        }

        let resampledBuffer = resample(
            buffer: buffer, toSampleRate: Double(selectedSampleRate.rawValue))

        do {
            try audioFile.write(from: resampledBuffer)
            print(
                "Written to file. Buffer frame length: \(resampledBuffer.frameLength)"
            )
        } catch {
            print("Error writing to audio file: \(error)")
            print("Audio file format: \(audioFile.fileFormat)")
            print("Resampled buffer format: \(resampledBuffer.format)")
            print(
                "Resampled buffer frame length: \(resampledBuffer.frameLength)")
        }
    }

    func startRecording(to url: URL) throws {
        outputURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(selectedSampleRate.rawValue),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        isRecording = true
    }

    func stopRecording() {
        audioFile = nil
        outputURL = nil
        isRecording = false
        audioEngine.stop()
    }

    private func updateProgress() {
        progress = min(
            Double(processedSamples) / Double(estimatedTotalSamples), 1.0)
    }

    private func estimateTotalSamples(for text: String) -> Int {
        // Estimate based on average speaking rate and sample rate
        let averageSamplesPerCharacter = 220.5 * 22050 / 1000  // Assuming 220.5 ms per character and 22050 Hz sample rate
        return Int(Double(text.count) * averageSamplesPerCharacter)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { [weak self] in
            await self?.stopRecording()
        }
    }
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
                .frame(height: 120)  // Adjust this value to fit your logo
                .padding(.top, 10)

            // Divider line
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, -20)

            TextField("Phrase", text: $inputText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()

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

            ZStack {
                if isSaving {
                    ProgressView(value: viewModel.progress) {
                        Text("Saving... \(Int(viewModel.progress * 100))%")
                    }
                    .progressViewStyle(LinearProgressViewStyle())
                } else if showDoneMessage {
                    Text("Done")
                        .foregroundColor(.green)
                        .opacity(doneOpacity)
                }
            }
            .frame(height: 30)
            .padding(.vertical, 10)
        }
        .padding()
        .frame(width: 400, height: 340)
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
