import AVFoundation
import Foundation
import SwiftTinyLoggerWindow

enum AudioFileManager {

    static func writeBufferToDisk(
        _ buffer: AVAudioPCMBuffer, to url: URL, sampleRate: Double, logger: AppLogger
    ) async throws {
        logger.send(.debug, phase: "FILE",
            "Converting buffer \(buffer.frameLength) frames \(buffer.format.sampleRate)Hz \(buffer.format.channelCount) channels to \(sampleRate)Hz")
        let audioData = convertToInt16Data(from: buffer)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                logger.send(.debug, phase: "FILE",
                    "Writing audio buffer to \(url.path) at \(sampleRate)Hz")
                try writeWavFile(
                    audioData: audioData, to: url,
                    sampleRate: UInt32(sampleRate), logger: logger)
                continuation.resume(returning: ())
            } catch {
                logger.send(.error, phase: "FILE",
                    "Writing audio buffer failed: \(error)")
                continuation.resume(throwing: error)
            }
        }
    }

    private static func convertToInt16Data(from buffer: AVAudioPCMBuffer) -> Data {
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

    private static func writeWavFile(
        audioData: Data, to url: URL, sampleRate: UInt32, logger: AppLogger
    ) throws {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount * bitsPerSample / 8)
        let blockAlign = channelCount * bitsPerSample / 8
        let dataSize = UInt32(audioData.count)
        let fileSize = 36 + dataSize

        logger.send(.debug, phase: "FILE", "Building Header")

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

        logger.send(.debug, phase: "FILE", "Ensuring directory exists")
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: nil)

        logger.send(.debug, phase: "FILE", "Creating file")
        if !FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: nil)
        {
            throw NSError(
                domain: NSCocoaErrorDomain, code: 4,
                userInfo: [NSFilePathErrorKey: url.path])
        }

        logger.send(.debug, phase: "FILE", "Opening file for writing")
        guard let fileHandle = try? FileHandle(forWritingTo: url) else {
            throw NSError(
                domain: NSCocoaErrorDomain, code: 4,
                userInfo: [NSFilePathErrorKey: url.path])
        }
        defer {
            try? fileHandle.close()
        }

        logger.send(.debug, phase: "FILE", "Writing header")
        fileHandle.write(header)

        // Write audio data in chunks
        let chunkSize = 4096
        for i in stride(from: 0, to: audioData.count, by: chunkSize) {
            logger.send(.debug, phase: "FILE", "Writing chunk \(i)")
            let upperBound = min(i + chunkSize, audioData.count)
            let chunk = audioData[i..<upperBound]
            fileHandle.write(chunk)
        }

        logger.send(.info, phase: "FILE", "File writing completed successfully")
    }
}

extension FixedWidthInteger {
    var data: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
