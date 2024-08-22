import AVFoundation

enum SpeechSynthesizerError: Error {
    case noAccumulatedBuffer
    case bufferHasNoFrames
    case formatMismatch
    case fileNotWritable
    case audioWriteFailed
    case noPCMBuffer
}

extension FixedWidthInteger {
    var data: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}

actor SpeechSynthesizer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate
{
    let synthesizer: AVSpeechSynthesizer
    var audioFile: AVAudioFile?
    var accumulatedBuffer: AVAudioPCMBuffer?

    @Published var status: SaveStatus = .idle
    private var outputURL: URL?
    private var selectedSampleRate: SampleRate = .default
    private var currentUtteranceID: UUID?
    private var utteranceIDs: [ObjectIdentifier: UUID] = [:]
    private var totalExpectedFrames: AVAudioFrameCount = 0
    private var currentFrameCount: AVAudioFrameCount = 0
    private var utteranceCompletion: CheckedContinuation<Bool, Error>?
    private var currentUtteranceIdentifier: ObjectIdentifier?

    override init() {
        self.synthesizer = AVSpeechSynthesizer()
        super.init()
        self.synthesizer.delegate = self
    }

    func setSampleRate(_ sampleRate: SampleRate) {
        selectedSampleRate = sampleRate
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async {
        let utterance = createUtterance(text: text, voice: voice)
        let utteranceID = UUID()
        let utteranceObjectID = ObjectIdentifier(utterance)
        utteranceIDs[utteranceObjectID] = utteranceID
        currentUtteranceID = utteranceID
        currentUtteranceIdentifier = utteranceObjectID
        status = .previewing

        return await withCheckedContinuation { continuation in
            synthesizer.speak(utterance)
            Task {
                await waitForSpeechCompletion()
                status = .idle
                continuation.resume()
            }
        }
    }

    private func waitForSpeechCompletion() async {
        while status == .previewing {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { [weak self] in
            await self?.handleSpeechFinished(
                utteranceIdentifier: ObjectIdentifier(utterance))
        }
    }

    private func handleSpeechFinished(utteranceIdentifier: ObjectIdentifier) {
        guard utteranceIdentifier == currentUtteranceIdentifier else {
            return  // Ignore if it's not the current utterance
        }
        status = .success
        utteranceCompletion?.resume(returning: true)
        utteranceCompletion = nil
        currentUtteranceIdentifier = nil
        LogManager.shared.addLog("Speech completed successfully")
    }

    private func handleSpeechError(_ error: Error) {
        status = .failure
        utteranceCompletion?.resume(throwing: error)
        utteranceCompletion = nil
        currentUtteranceIdentifier = nil
        LogManager.shared.addLog("Speech error occurred: \(error)")
    }

    private func createUtterance(text: String, voice: AVSpeechSynthesisVoice)
        -> AVSpeechUtterance
    {
        LogManager.shared.addLog(
            "Creating utterance for text '\(text)' using voice '\(voice.name)'")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        return utterance
    }

    func speakAndSave(_ text: String, voice: AVSpeechSynthesisVoice)
        async throws -> Bool
    {
        let utterance = createUtterance(text: text, voice: voice)
        currentUtteranceIdentifier = ObjectIdentifier(utterance)

        accumulatedBuffer = nil
        totalExpectedFrames = AVAudioFrameCount(
            Double(utterance.speechString.count) * 220)  // Rough estimate
        currentFrameCount = 0

        guard let outputURL = outputURL else {
            throw SpeechSynthesizerError.fileNotWritable
        }

        try startRecording(to: outputURL)

        return try await withCheckedThrowingContinuation { continuation in
            utteranceCompletion = continuation
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self = self else { return }
                Task {
                    do {
                        try await self.accumulateBuffer(buffer)
                    } catch {
                        await self.handleSpeechError(error)
                    }
                }
            }
        }
    }

    private func synthesizeAndAccumulate(utterance: AVSpeechUtterance)
        async throws -> Bool
    {
        return try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self = self else { return }
                Task {
                    do {
                        try await self.accumulateBuffer(buffer)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(returning: true)
            }
        }
    }

    private func accumulateBuffer(_ buffer: AVAudioBuffer) async throws {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            throw SpeechSynthesizerError.noPCMBuffer
        }

        if accumulatedBuffer == nil {
            accumulatedBuffer = pcmBuffer
        } else {
            accumulatedBuffer = mergeBuffers(
                buffer1: accumulatedBuffer!, buffer2: pcmBuffer)
        }

        currentFrameCount += pcmBuffer.frameLength
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
        status = .saving
    }

    func stopRecording() async throws {
        guard let accumulatedBuffer = accumulatedBuffer else {
            LogManager.shared.addLog("No accumulated buffer to save")
            throw SpeechSynthesizerError.noAccumulatedBuffer
        }

        LogManager.shared.addLog("Output URL: \(String(describing: outputURL))")
        LogManager.shared.addLog(
            "Buffer format before resampling: \(accumulatedBuffer.format)")

        let resampledBuffer = resample(
            buffer: accumulatedBuffer,
            toSampleRate: Double(selectedSampleRate.rawValue))
        LogManager.shared.addLog(
            "Buffer format before changing bit depth: \(resampledBuffer.format)"
        )

        guard let outputURL = outputURL else {
            LogManager.shared.addLog(
                "File not writable: \(String(outputURL?.path() ?? "nil"))"
            )
            throw SpeechSynthesizerError.fileNotWritable
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(selectedSampleRate.rawValue),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        LogManager.shared.addLog("Settings: \(settings)")

        let audioFile = try AVAudioFile(
            forWriting: outputURL, settings: settings)

        guard resampledBuffer.frameLength > 0 else {
            LogManager.shared.addLog("Buffer has no frames to write")
            throw SpeechSynthesizerError.bufferHasNoFrames
        }

        guard audioFile.processingFormat == resampledBuffer.format else {
            LogManager.shared.addLog(
                "Format mismatch: file \(audioFile.processingFormat) vs resampledBuffer \(resampledBuffer.format)"
            )
            throw SpeechSynthesizerError.formatMismatch
        }

        guard FileManager.default.isWritableFile(atPath: outputURL.path) else {
            LogManager.shared.addLog(
                "The file path: '\(outputURL.path)' is not writable.")
            throw SpeechSynthesizerError.fileNotWritable
        }

        LogManager.shared.addLog("Attempting to write the buffer to file...")
        do {
            try await writeBufferToDisk(
                resampledBuffer, to: outputURL, settings: settings)
            status = .success
            LogManager.shared.addLog("Audio saved successfully.")
        } catch {
            status = .failure
            LogManager.shared.addLog("Failed to save audio: \(error)")
            throw error
        }
    }

    private func writeBufferToDisk(
        _ buffer: AVAudioPCMBuffer, to url: URL, settings: [String: Any]
    ) async throws {
        let audioData = convertToInt16Data(from: buffer)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try writeWavFile(
                    audioData: audioData, to: url,
                    sampleRate: UInt32(selectedSampleRate.rawValue))
                continuation.resume(returning: ())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func convertToInt16Data(from buffer: AVAudioPCMBuffer) -> Data {
        let floatData = buffer.floatChannelData![0]
        let frameCount = Int(buffer.frameLength)
        var int16Data = Data(count: frameCount * 2)

        int16Data.withUnsafeMutableBytes { int16Buffer in
            let int16Ptr = int16Buffer.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<frameCount {
                let floatSample = floatData[i]
                let int16Sample = Int16(
                    max(-32768, min(32767, round(floatSample * 32767))))
                int16Ptr[i] = int16Sample
            }
        }

        return int16Data
    }

    func writeWavFile(
        audioData: Data, to url: URL, sampleRate: UInt32
    ) throws {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount * bitsPerSample / 8)
        let blockAlign = channelCount * bitsPerSample / 8
        let dataSize = UInt32(audioData.count)
        let fileSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.append(fileSize.littleEndian.data)
        header.append(contentsOf: "WAVEfmt ".utf8)
        header.append(UInt32(16).littleEndian.data)
        header.append(UInt16(1).littleEndian.data)
        header.append(channelCount.littleEndian.data)
        header.append(sampleRate.littleEndian.data)
        header.append(byteRate.littleEndian.data)
        header.append(blockAlign.littleEndian.data)
        header.append(bitsPerSample.littleEndian.data)
        header.append(contentsOf: "data".utf8)
        header.append(dataSize.littleEndian.data)

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { fileHandle.closeFile() }

        // Write header
        fileHandle.write(header)

        // Write audio data in chunks
        let chunkSize = 4096
        var writtenBytes = header.count
        for i in stride(from: 0, to: audioData.count, by: chunkSize) {
            let upperBound = min(i + chunkSize, audioData.count)
            let chunk = audioData[i..<upperBound]
            fileHandle.write(chunk)
            writtenBytes += chunk.count
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
