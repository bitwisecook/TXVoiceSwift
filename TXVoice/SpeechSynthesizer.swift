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

actor SpeechSynthesizer {
    private var synthesizer = AVSpeechSynthesizer()
    private var selectedSampleRate: Double = 32000
    private let delegate: SpeechSynthesizerDelegate

    // Constants for buffer management
    private let initialBufferSeconds: Double = 30
    private let bufferGrowthFactor: Double = 1.5

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

        try await withCheckedThrowingContinuation { continuation in
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
        // Capture actor-isolated state into locals before entering @Sendable closures
        let sampleRate = selectedSampleRate
        let growthFactor = bufferGrowthFactor

        LogManager.shared.addLog(
            "Starting speech synthesis and save: '\(text)' with voice '\(voice.name)'"
        )

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1)!

        let initialFrameCapacity = AVAudioFrameCount(
            initialBufferSeconds * sampleRate)
        guard
            let initialBuffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: initialFrameCapacity)
        else {
            throw SpeechSynthesizerError.noPCMBuffer
        }

        // Use a Sendable wrapper so mutable buffer state can be captured in @Sendable closures
        let accumulator = BufferAccumulator(buffer: initialBuffer)

        try await withCheckedThrowingContinuation { continuation in
            delegate.onUtteranceComplete = { error in
                LogManager.shared.addLog(
                    "Speech synthesis completed, frames accumulated: \(accumulator.currentFrame)"
                )

                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                do {
                    LogManager.shared.addLog(
                        "Attempting to write to file: \(url.path)")
                    try AudioFileManager.shared.writeBufferToDisk(
                        accumulator.buffer, to: url,
                        sampleRate: sampleRate)
                    LogManager.shared.addLog("File written successfully")
                    continuation.resume()
                } catch {
                    LogManager.shared.addLog(
                        "Error writing file: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }

            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer,
                    pcmBuffer.frameLength > 0
                else {
                    return
                }

                let convertedBuffer: AVAudioPCMBuffer
                if pcmBuffer.format.sampleRate != sampleRate {
                    convertedBuffer = Self.resample(
                        buffer: pcmBuffer, toSampleRate: sampleRate)
                } else {
                    convertedBuffer = pcmBuffer
                }

                accumulator.append(convertedBuffer, growthFactor: growthFactor)
            }
        }
    }

    private static func resample(
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

/// Wraps mutable audio buffer accumulation state for use in @Sendable closures.
/// Safe as @unchecked Sendable because AVSpeechSynthesizer.write delivers
/// buffer callbacks sequentially, and onUtteranceComplete fires only after
/// all write callbacks have completed.
private final class BufferAccumulator: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var currentFrame: AVAudioFrameCount = 0

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func append(_ convertedBuffer: AVAudioPCMBuffer, growthFactor: Double) {
        let framesToAdd = convertedBuffer.frameLength
        let totalRequiredFrames = currentFrame + framesToAdd

        if totalRequiredFrames > buffer.frameCapacity {
            let newCapacity = AVAudioFrameCount(
                Double(buffer.frameCapacity) * growthFactor)
            guard
                let newBuffer = Self.extendBuffer(
                    buffer, newCapacity: newCapacity)
            else {
                LogManager.shared.addLog("Failed to extend buffer")
                return
            }
            buffer = newBuffer
        }

        let targetBuffer = buffer.floatChannelData![0]
            .advanced(by: Int(currentFrame))
        convertedBuffer.floatChannelData![0].withMemoryRebound(
            to: Float.self, capacity: Int(framesToAdd)
        ) { sourceBuffer in
            targetBuffer.initialize(
                from: sourceBuffer, count: Int(framesToAdd))
        }

        currentFrame += framesToAdd
        buffer.frameLength = currentFrame
        LogManager.shared.addLog(
            "Accumulated \(framesToAdd) frames, total: \(currentFrame)")
    }

    private static func extendBuffer(
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
}

final class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    var onUtteranceComplete: (@Sendable (Error?) -> Void)?

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
