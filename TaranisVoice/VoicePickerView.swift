import AVFoundation
import SwiftUI

struct VoiceGroup: Identifiable {
    let id = UUID()
    let name: String
    var voices: [AVSpeechSynthesisVoice]
    let isNovelty: Bool
    let isPrimaryLanguage: Bool
}

struct ColoredSFSymbol: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .foregroundColor(color)
            .symbolRenderingMode(.palette)
    }
}

struct VoicePickerView: View {
    @Binding var selection: AVSpeechSynthesisVoice
    let voiceGroups: [VoiceGroup]

    var body: some View {
        Menu {
            ForEach(voiceGroups) { group in
                Section(header: Text(group.name).foregroundColor(.secondary)) {
                    ForEach(group.voices, id: \.identifier) { voice in
                        Button(action: {
                            selection = voice
                        }) {
                            HStack {
                                Text(voice.name)
                                Spacer()
                                if voice == selection {
                                    ColoredSFSymbol(
                                        systemName: "checkmark",
                                        color: .accentColor
                                    )
                                } else if voice.quality == .premium {
                                    ColoredSFSymbol(
                                        systemName: "waveform.badge.plus",
                                        color: Color("VoiceMenuPremiumColor")
                                    )
                                } else if voice.quality == .enhanced {
                                    ColoredSFSymbol(
                                        systemName: "waveform.badge.plus",
                                        color: Color("VoiceMenuEnhancedColor")
                                    )
                                } else {
                                    ColoredSFSymbol(
                                        systemName: "waveform",
                                        color: Color("VoiceMenuStandardColor")
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(selection.name)
                if selection.quality == .premium {
                    ColoredSFSymbol(
                        systemName: "waveform.badge.plus",
                        color: Color("VoiceMenuPremiumColor")
                    )
                } else if selection.quality == .enhanced {
                    ColoredSFSymbol(
                        systemName: "waveform.badge.plus",
                        color: Color("VoiceMenuEnhancedColor")
                    )
                }
            }
        }
    }
}
