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
    private var selectedSampleRate: Double = 32000
    private let delegate: SpeechSynthesizerDelegate

    // Constants for buffer management
    private let initialBufferSeconds: Double = 30  // Initial buffer size in seconds
    private let bufferGrowthFactor: Double = 1.5  // Factor to grow buffer when needed

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
            delegate.onUtteranceComplete = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
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

        let format = AVAudioFormat(
            standardFormatWithSampleRate: selectedSampleRate, channels: 1)!

        // Preallocate the buffer
        let initialFrameCapacity = AVAudioFrameCount(
            initialBufferSeconds * selectedSampleRate)
        guard
            let initialBuffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: initialFrameCapacity)
        else {
            throw SpeechSynthesizerError.noPCMBuffer
        }
        var accumulatedBuffer = initialBuffer
        var currentFrame: AVAudioFrameCount = 0

        return try await withCheckedThrowingContinuation { continuation in
            delegate.onUtteranceComplete = { [weak self] error in
                guard let self = self else { return }
                LogManager.shared.addLog(
                    "Speech synthesis completed, frames accumulated: \(currentFrame)"
                )

                Task {
                    do {
                        try await self.writeToFile(
                            buffer: accumulatedBuffer, url: url)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
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

                let framesToAdd = convertedBuffer.frameLength
                let totalRequiredFrames = currentFrame + framesToAdd

                if totalRequiredFrames > accumulatedBuffer.frameCapacity {
                    // Need to extend the buffer
                    let newCapacity = AVAudioFrameCount(
                        Double(accumulatedBuffer.frameCapacity)
                            * self.bufferGrowthFactor)
                    guard
                        let newBuffer = self.extendBuffer(
                            accumulatedBuffer, newCapacity: newCapacity)
                    else {
                        LogManager.shared.addLog("Failed to extend buffer")
                        return
                    }
                    accumulatedBuffer = newBuffer
                }

                // Copy new frames into the accumulated buffer
                let targetBuffer = accumulatedBuffer.floatChannelData![0]
                    .advanced(by: Int(currentFrame))
                convertedBuffer.floatChannelData![0].withMemoryRebound(
                    to: Float.self, capacity: Int(framesToAdd)
                ) { sourceBuffer in
                    targetBuffer.initialize(
                        from: sourceBuffer, count: Int(framesToAdd))
                }

                currentFrame += framesToAdd
                accumulatedBuffer.frameLength = currentFrame
                LogManager.shared.addLog(
                    "Accumulated \(framesToAdd) frames, total: \(currentFrame)")
            }
        }
    }

    private func writeToFile(buffer: AVAudioPCMBuffer, url: URL) async throws {
        if buffer.frameLength > 0 {
            do {
                LogManager.shared.addLog("Starting to write audio file...")
                try await AudioFileManager.shared.writeBufferToDisk(
                    buffer, to: url, sampleRate: self.selectedSampleRate)
                LogManager.shared.addLog(
                    "Audio file written successfully to \(url.path)")
            } catch {
                LogManager.shared.addLog("Error writing audio file: \(error)")
                throw error
            }
        } else {
            LogManager.shared.addLog("No audio data to write")
            throw SpeechSynthesizerError.noAccumulatedBuffer
        }
    }

    private func extendBuffer(
        _ buffer: AVAudioPCMBuffer, newCapacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard
            let newBuffer = AVAudioPCMBuffer(
                pcmFormat: buffer.format, frameCapacity: newCapacity)
        else {
            return nil
        }

        let framesToCopy = min(buffer.frameLength, newCapacity)
        let bytesToCopy = Int(framesToCopy) * MemoryLayout<Float>.size

        memcpy(
            newBuffer.floatChannelData?[0], buffer.floatChannelData?[0],
            bytesToCopy)
        newBuffer.frameLength = framesToCopy

        return newBuffer
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
