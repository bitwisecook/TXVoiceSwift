import AVFoundation

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
            LogManager.shared.addLog("Failed to start recording: \(error)")
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
            LogManager.shared.addLog("No accumulated buffer to save")
            return
        }
                                     LogManager.shared.addLog("Output URL: \(String(describing: outputURL))")
                                                              LogManager.shared.addLog("Buffer format before resampling: \(accumulatedBuffer.format)")

        // Resample the accumulated buffer to the selected sample rate
        let resampledBuffer = resample(
            buffer: accumulatedBuffer,
            toSampleRate: Double(selectedSampleRate.rawValue))
                                                                                       LogManager.shared.addLog(
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

                LogManager.shared.addLog("Settings: \(settings)")

            // Create the AVAudioFile with the settings
            let audioFile = try AVAudioFile(
                forWriting: outputURL!, settings: settings)

            // Ensure the buffer frame length is not zero before writing
            guard resampledBuffer.frameLength > 0 else {
                    LogManager.shared.addLog("Buffer has no frames to write")
                return
            }

            // Ensure the buffer formats are equivalent
            guard audioFile.processingFormat == resampledBuffer.format else {
                        LogManager.shared.addLog(
                    "Format mismatch: file \(audioFile.processingFormat) vs resampledBuffer \(resampledBuffer.format)"
                )
                return
            }

            // ensure the file is writable
            guard FileManager.default.isWritableFile(atPath: outputURL!.path)
            else {
                            LogManager.shared.addLog("The file path: '\(outputURL!.path)' is not writable.")
                return
            }

            // Attempt to write the buffer to the file
                                                     LogManager.shared.addLog("Attempting to write the buffer to file...")
            try audioFile.write(from: resampledBuffer)
                                                                              LogManager.shared.addLog("Audio saved successfully.")

            // Log file format after writing
                                                                                                       LogManager.shared.addLog("Audio file format after writing: \(audioFile.fileFormat)")
        } catch {
            let nsError = error as NSError
                                LogManager.shared.addLog("Error writing to audio file: \(nsError)")
                                                         LogManager.shared.addLog(
                "Error localized description: \(nsError.localizedDescription)")
                                                                                  LogManager.shared.addLog("AVAudioFile error details: \(nsError.userInfo)")
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
            LogManager.shared.addLog("Failed to create audio converter")
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
                LogManager.shared.addLog("Failed to create output buffer")
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
                    LogManager.shared.addLog("Error during conversion: \(error)")
            return buffer
        }

        return outputBuffer
    }
}
