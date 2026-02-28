import AVFoundation
import SwiftTinyLoggerWindow

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
    private let logger: AppLogger

    // Constants for buffer management
    private let initialBufferSeconds: Double = 30
    private let bufferGrowthFactor: Double = 1.5

    init(logger: AppLogger) {
        self.logger = logger
        let tempSynthesizer = AVSpeechSynthesizer()
        self.synthesizer = tempSynthesizer
        self.delegate = SpeechSynthesizerDelegate(logger: logger)
        tempSynthesizer.delegate = self.delegate
    }

    func setSampleRate(_ sampleRate: Double) {
        selectedSampleRate = sampleRate
        logger.send(.debug, phase: "SYNTH", "Sample rate set to \(sampleRate) Hz")
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async throws {
        logger.send(.debug, phase: "SYNTH", "Starting speech preview: '\(text)' with voice '\(voice.name)'")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
        let logger = self.logger

        logger.send(.debug, phase: "SYNTH",
            "Starting speech synthesis and save: '\(text)' with voice '\(voice.name)'")

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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.onUtteranceComplete = { error in
                logger.send(.debug, phase: "SYNTH",
                    "Speech synthesis completed, frames accumulated: \(accumulator.currentFrame)")

                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                Task {
                    do {
                        logger.send(.debug, phase: "SYNTH",
                            "Attempting to write to file: \(url.path)")
                        try await AudioFileManager.writeBufferToDisk(
                            accumulator.buffer, to: url,
                            sampleRate: sampleRate, logger: logger)
                        logger.send(.info, phase: "SYNTH", "File written successfully")
                        continuation.resume()
                    } catch {
                        logger.send(.error, phase: "SYNTH",
                            "Error writing file: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                }
            }

            synthesizer.write(utterance) { buffer in
                nonisolated(unsafe) let buffer = buffer
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer,
                    pcmBuffer.frameLength > 0
                else {
                    return
                }

                let convertedBuffer: AVAudioPCMBuffer
                if pcmBuffer.format.sampleRate != sampleRate {
                    convertedBuffer = Self.resample(
                        buffer: pcmBuffer, toSampleRate: sampleRate, logger: logger)
                } else {
                    convertedBuffer = pcmBuffer
                }

                accumulator.append(convertedBuffer, growthFactor: growthFactor, logger: logger)
            }
        }
    }

    private static func resample(
        buffer: AVAudioPCMBuffer, toSampleRate newSampleRate: Double, logger: AppLogger
    ) -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: newSampleRate,
            channels: 1, interleaved: false)!

        guard
            let converter = AVAudioConverter(
                from: inputFormat, to: outputFormat)
        else {
            logger.send(.error, phase: "SYNTH", "Failed to create audio converter")
            return buffer
        }

        let ratio = newSampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio)
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outputFrameCapacity)
        else {
            logger.send(.error, phase: "SYNTH",
                "Failed to create output buffer for resampling")
            return buffer
        }

        var error: NSError?
        nonisolated(unsafe) let capturedBuffer = buffer
        let inputBlock: AVAudioConverterInputBlock = {
            inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return capturedBuffer
        }

        converter.convert(
            to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            logger.send(.error, phase: "SYNTH", "Error during conversion: \(error)")
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

    func append(_ convertedBuffer: AVAudioPCMBuffer, growthFactor: Double, logger: AppLogger) {
        let framesToAdd = convertedBuffer.frameLength
        let totalRequiredFrames = currentFrame + framesToAdd

        if totalRequiredFrames > buffer.frameCapacity {
            let newCapacity = AVAudioFrameCount(
                Double(buffer.frameCapacity) * growthFactor)
            guard
                let newBuffer = Self.extendBuffer(
                    buffer, newCapacity: newCapacity)
            else {
                logger.send(.error, phase: "SYNTH", "Failed to extend buffer")
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
        logger.send(.debug, phase: "SYNTH",
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
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
        super.init()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        logger.send(.debug, phase: "SYNTH", "Speech synthesis completed")
        onUtteranceComplete?(nil)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        logger.send(.warning, phase: "SYNTH", "Speech synthesis cancelled")
        onUtteranceComplete?(SpeechSynthesizerError.synthesisIncomplete)
    }
}
