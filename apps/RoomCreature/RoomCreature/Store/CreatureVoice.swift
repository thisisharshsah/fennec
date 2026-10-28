import Foundation
@preconcurrency import AVFoundation

/// A creature's voice: what it says, read aloud while the app is open, in the voice and tone the owner
/// chose. Only when the owner set replies to voice (TalkPrefs); text is the default.
@MainActor
final class CreatureVoice: NSObject {
    /// Run when the current line has been spoken (or was skipped), for the companion to listen again.
    private var whenDone: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` when replies are set to voice; otherwise just calls `done`.
    func say(_ text: String, then done: (() -> Void)? = nil) {
        guard TalkPrefs.speaks, !text.isEmpty else { done?(); return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
        speak(text)
        whenDone = done
    }

    /// A sample line in the chosen voice and tone, for the owner trying voices out.
    func preview(_ name: String) {
        synthesizer.stopSpeaking(at: .immediate)
        whenDone = nil
        speak("Hi, I'm \(name). This is how I sound.")
    }

    private func speak(_ text: String) {
        let tone = VoiceTone(rawValue: UserDefaults.standard.string(forKey: TalkPrefs.toneKey) ?? "") ?? .creature
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.chosenVoice()
        utterance.pitchMultiplier = tone.pitch
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * tone.rate
        synthesizer.speak(utterance)
    }

    func stop() {
        whenDone = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    fileprivate func finished() {
        guard let done = whenDone else { return }
        whenDone = nil
        done()
    }

    /// The chosen voice, else the best installed one for the device's language: premium, enhanced, any.
    private static func chosenVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: TalkPrefs.voiceKey), !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// One installed voice, for the picker.
    struct Choice: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let detail: String
        let isFun: Bool
    }

    /// The installed voices in the device's language: the better ones first, playful ones apart.
    static func choices() -> [Choice] {
        let language = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { voice in
                let quality = switch voice.quality {
                case .premium: "premium"
                case .enhanced: "enhanced"
                default: ""
                }
                let region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
                return Choice(id: voice.identifier, name: voice.name,
                              detail: [region, quality].filter { !$0.isEmpty }.joined(separator: ", "),
                              isFun: voice.voiceTraits.contains(.isNoveltyVoice))
            }
    }
}

extension CreatureVoice: AVSpeechSynthesizerDelegate {
    // called on the synthesizer's own thread: hop to the main actor
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
