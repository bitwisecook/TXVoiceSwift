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
    var accumulatedBuffer: AVAudioPCMBuffer?

    @Published var isRecording = false
    @Published var progress: Double = 0.0
    private var outputURL: URL?
    private var selectedSampleRate: SampleRate = .default

    override init() {
        self.synthesizer = AVSpeechSynthesizer()
        super.init()
        self.synthesizer.delegate = self
    }

    func setSampleRate(_ sampleRate: SampleRate) {
        selectedSampleRate = sampleRate
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async -> Bool {
        let utterance = createUtterance(text: text, voice: voice)
        synthesizer.speak(utterance)
        return true
    }
    func speakAndSave(_ text: String, voice: AVSpeechSynthesisVoice) async
        -> Bool
    {
        let utterance = createUtterance(text: text, voice: voice)

        // Reset progress and buffer
        progress = 0.0
        accumulatedBuffer = nil

        do {
            try startRecording(to: outputURL!)
        } catch {
            print("Failed to start recording: \(error)")
            return false
        }

        return await synthesizeAndAccumulate(utterance: utterance)
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

    private func synthesizeAndAccumulate(utterance: AVSpeechUtterance) async
        -> Bool
    {
        await withCheckedContinuation { continuation in
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self = self else { return }
                Task {
                    await self.accumulateBuffer(buffer)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(returning: true)
            }
        }
    }

    private func accumulateBuffer(_ buffer: AVAudioBuffer) async {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            return
        }

        if accumulatedBuffer == nil {
            accumulatedBuffer = pcmBuffer
        } else {
            accumulatedBuffer = mergeBuffers(
                buffer1: accumulatedBuffer!, buffer2: pcmBuffer)
        }
    }

    private func mergeBuffers(
        buffer1: AVAudioPCMBuffer, buffer2: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer {
        let newFrameLength = buffer1.frameLength + buffer2.frameLength
        let mergedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer1.format,
            frameCapacity: newFrameLength
        )!

        mergedBuffer.frameLength = newFrameLength
        memcpy(
            mergedBuffer.floatChannelData![0], buffer1.floatChannelData![0],
            Int(buffer1.frameLength) * MemoryLayout<Float>.size)
        memcpy(
            mergedBuffer.floatChannelData![0].advanced(
                by: Int(buffer1.frameLength)), buffer2.floatChannelData![0],
            Int(buffer2.frameLength) * MemoryLayout<Float>.size)

        return mergedBuffer
    }

    func startRecording(to url: URL) throws {
        outputURL = url
        isRecording = true
    }

    func stopRecording() async {
        guard let accumulatedBuffer = accumulatedBuffer else {
            print("No accumulated buffer to save")
            return
        }
        print("Output URL: \(String(describing: outputURL))")
        print("Buffer format before resampling: \(accumulatedBuffer.format)")

        // Resample the accumulated buffer to the selected sample rate
        let resampledBuffer = resample(
            buffer: accumulatedBuffer,
            toSampleRate: Double(selectedSampleRate.rawValue))
        print(
            "Buffer format before changing bit depth: \(resampledBuffer.format)"
        )

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(selectedSampleRate.rawValue),
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,  // Ensure 16-bit depth
                AVLinearPCMIsFloatKey: false,  // Ensure Int16 format
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]

            print("Settings: \(settings)")

            // Create the AVAudioFile with the settings
            let audioFile = try AVAudioFile(
                forWriting: outputURL!, settings: settings)

            // Ensure the buffer frame length is not zero before writing
            guard resampledBuffer.frameLength > 0 else {
                print("Buffer has no frames to write")
                return
            }

            // Ensure the buffer formats are equivalent
            guard audioFile.processingFormat == resampledBuffer.format else {
                print(
                    "Format mismatch: file \(audioFile.processingFormat) vs resampledBuffer \(resampledBuffer.format)"
                )
                return
            }

            // ensure the file is writable
            guard FileManager.default.isWritableFile(atPath: outputURL!.path)
            else {
                print("The file path: '\(outputURL!.path)' is not writable.")
                return
            }

            // Attempt to write the buffer to the file
            print("Attempting to write the buffer to file...")
            try audioFile.write(from: resampledBuffer)
            print("Audio saved successfully.")

            // Log file format after writing
            print("Audio file format after writing: \(audioFile.fileFormat)")
        } catch {
            let nsError = error as NSError
            print("Error writing to audio file: \(nsError)")
            print(
                "Error localized description: \(nsError.localizedDescription)")
            print("AVAudioFile error details: \(nsError.userInfo)")
        }

        isRecording = false
    }

    private func resample(
        buffer: AVAudioPCMBuffer, toSampleRate newSampleRate: Double
    ) -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: newSampleRate,
            channels: 1, interleaved: false)!

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
        let _ = converter.convert(to: outputBuffer, error: &error) {
            inNumPackets, outStatus in
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
            return buffer
        }

        return outputBuffer
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
                    Text("Done")
                        .foregroundColor(.green)
                        .bold()
                        .font(.system(size: 24))
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
