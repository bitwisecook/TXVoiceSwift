import AVFoundation

enum SpeechSynthesizerError: Error {
    case noAccumulatedBuffer
    case bufferHasNoFrames
    case formatMismatch
    case fileNotWritable
    case audioWriteFailed
    case noPCMBuffer
    case synthesisIncomplete
}

actor SpeechSynthesizer: ObservableObject {
    private var synthesizer = AVSpeechSynthesizer()
    private var accumulatedBuffer: AVAudioPCMBuffer?
    private var outputURL: URL?
    private var selectedSampleRate: Double = 32000
    private var utteranceCompletion: CheckedContinuation<Void, Error>?
    private let delegate: SpeechSynthesizerDelegate

    init() {
        let tempSynthesizer = AVSpeechSynthesizer()
        self.synthesizer = tempSynthesizer
        self.delegate = SpeechSynthesizerDelegate()
        tempSynthesizer.delegate = self.delegate
    }

    func setSampleRate(_ sampleRate: Double) {
        selectedSampleRate = sampleRate
        LogManager.shared.addLog("Sample rate set to \(sampleRate) Hz")
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async throws {
        LogManager.shared.addLog(
            "Starting speech preview: '\(text)' with voice '\(voice.name)'")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        return try await withCheckedThrowingContinuation { continuation in
            self.utteranceCompletion = continuation
            delegate.onUtteranceComplete = { [weak self] error in
                Task { await self?.completeUtterance(with: error) }
            }
            synthesizer.speak(utterance)
        }
    }

    func speakAndSave(
        _ text: String, voice: AVSpeechSynthesisVoice, to url: URL
    ) async throws {
        LogManager.shared.addLog(
            "Starting speech synthesis and save: '\(text)' with voice '\(voice.name)'"
        )

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        let audioEngine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)

        let format = AVAudioFormat(
            standardFormatWithSampleRate: selectedSampleRate, channels: 1)!
        audioEngine.connect(
            playerNode, to: audioEngine.mainMixerNode, format: format)

        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        return try await withCheckedThrowingContinuation { continuation in
            self.utteranceCompletion = continuation
            delegate.onUtteranceComplete = { [weak self] error in
                Task { await self?.completeUtterance(with: error) }
            }

            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer,
                    pcmBuffer.frameLength > 0
                else {
                    return
                }

                let convertedBuffer: AVAudioPCMBuffer
                if pcmBuffer.format.sampleRate != self.selectedSampleRate {
                    convertedBuffer = self.resample(
                        buffer: pcmBuffer, toSampleRate: self.selectedSampleRate
                    )
                } else {
                    convertedBuffer = pcmBuffer
                }

                do {
                    try file.write(from: convertedBuffer)
                    LogManager.shared.addLog(
                        "Wrote \(convertedBuffer.frameLength) frames to file")
                } catch {
                    LogManager.shared.addLog("Error writing to file: \(error)")
                    continuation.resume(throwing: error)
                }
            }

            do {
                try audioEngine.start()
                LogManager.shared.addLog("Audio engine started")
            } catch {
                LogManager.shared.addLog(
                    "Error starting audio engine: \(error)")
                continuation.resume(throwing: error)
            }
        }
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
        let outputFrameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio)
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outputFrameCapacity)
        else {
            LogManager.shared.addLog(
                "Failed to create output buffer for resampling")
            return buffer
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = {
            inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(
            to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            LogManager.shared.addLog("Error during conversion: \(error)")
            return buffer
        }

        return outputBuffer
    }

    private func writeBufferToWavFile(_ buffer: AVAudioPCMBuffer, to url: URL)
        async throws
    {
        do {
            let audioFile = try AVAudioFile(
                forWriting: url, settings: buffer.format.settings)
            try audioFile.write(from: buffer)
        } catch {
            LogManager.shared.addLog("Error writing audio file: \(error)")
            throw SpeechSynthesizerError.audioWriteFailed
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            LogManager.shared.addLog("Speech synthesis completed")
            await self.completeUtterance()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            LogManager.shared.addLog("Speech synthesis cancelled")
            await self.completeUtterance(
                with: SpeechSynthesizerError.synthesisIncomplete)
        }
    }

    private func completeUtterance(with error: Error? = nil) {
        LogManager.shared.addLog("Completing utterance")
        if let error = error {
            LogManager.shared.addLog("Utterance completed with error: \(error)")
            utteranceCompletion?.resume(throwing: error)
        } else {
            LogManager.shared.addLog("Utterance completed successfully")
            utteranceCompletion?.resume()
        }
        utteranceCompletion = nil
    }
}

class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onUtteranceComplete: ((Error?) -> Void)?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        LogManager.shared.addLog("Speech synthesis completed")
        onUtteranceComplete?(nil)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        LogManager.shared.addLog("Speech synthesis cancelled")
        onUtteranceComplete?(SpeechSynthesizerError.synthesisIncomplete)
    }
}
