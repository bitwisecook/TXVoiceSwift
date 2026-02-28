import AVFoundation
import SwiftUI
import SwiftTinyLoggerWindow

@MainActor
@Observable
class SpeechSynthesizerViewModel {
    var status: SaveStatus = .idle
    var selectedSampleRate: SampleRate = .default
    private let synthesizer: SpeechSynthesizer
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
        self.synthesizer = SpeechSynthesizer(logger: logger)
    }

    func setSampleRate(_ sampleRate: SampleRate) async {
        await synthesizer.setSampleRate(Double(sampleRate.rawValue))
        selectedSampleRate = sampleRate
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async {
        status = .previewing
        logger.log(.info, phase: "SYNTH", "Status changed to previewing")
        do {
            try await synthesizer.speak(text, voice: voice)
            status = .idle
            logger.log(.info, phase: "SYNTH", "Status changed to idle after preview")
        } catch {
            logger.log(.error, phase: "SYNTH", "Error in speak: \(error)")
            status = .failure
            logger.log(.info, phase: "SYNTH", "Status changed to failure after preview error")
        }
    }

    func speakAndSave(
        _ text: String, voice: AVSpeechSynthesisVoice, to url: URL
    ) async {
        status = .saving
        logger.log(.info, phase: "SYNTH", "Status changed to saving")
        do {
            try await synthesizer.speakAndSave(text, voice: voice, to: url)
            status = .success
            logger.log(.info, phase: "SYNTH", "Status changed to success after save")
        } catch {
            logger.log(.error, phase: "SYNTH", "Error in speakAndSave: \(error)")
            status = .failure
            logger.log(.info, phase: "SYNTH", "Status changed to failure after save error")
        }
    }
}
