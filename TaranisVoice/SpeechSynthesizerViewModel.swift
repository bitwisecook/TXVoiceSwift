import SwiftUI
import AVFoundation

@MainActor
class SpeechSynthesizerViewModel: ObservableObject {
    @Published var status: SaveStatus = .idle
    @Published var selectedSampleRate: SampleRate = .default
    private let synthesizer: SpeechSynthesizer
    
    init() {
        synthesizer = SpeechSynthesizer()
    }
    
    func setSampleRate(_ sampleRate: SampleRate) async {
        await synthesizer.setSampleRate(Double(sampleRate.rawValue))
        selectedSampleRate = sampleRate
    }
    
    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async {
        status = .previewing
        LogManager.shared.addLog("Status changed to previewing")
        do {
            try await synthesizer.speak(text, voice: voice)
            status = .idle
            LogManager.shared.addLog("Status changed to idle after preview")
        } catch {
            LogManager.shared.addLog("Error in speak: \(error)")
            status = .failure
            LogManager.shared.addLog(
                "Status changed to failure after preview error")
        }
    }
    
    func speakAndSave(
        _ text: String, voice: AVSpeechSynthesisVoice, to url: URL
    ) async {
        status = .saving
        LogManager.shared.addLog("Status changed to saving")
        do {
            try await synthesizer.speakAndSave(text, voice: voice, to: url)
            status = .success
            LogManager.shared.addLog("Status changed to success after save")
        } catch {
            LogManager.shared.addLog("Error in speakAndSave: \(error)")
            status = .failure
            LogManager.shared.addLog(
                "Status changed to failure after save error")
        }
    }
}
