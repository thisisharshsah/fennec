import Foundation
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// A creature's voice: what it says, read aloud by the iPhone while the app is open, in a higher,
/// quicker voice than the system default. iPhone only: the Mac is a test rig and stays silent.
@MainActor
final class CreatureVoice {
    static let enabledKey = "voice.speaks"

    /// On unless the owner turned it off in Settings.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    #if os(iOS)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    func say(_ text: String) {
        #if os(iOS)
        guard Self.isEnabled, !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.pitchMultiplier = 1.35
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.03
        synthesizer.speak(utterance)
        #endif
    }

    func stop() {
        #if os(iOS)
        synthesizer.stopSpeaking(at: .immediate)
        #endif
    }

    #if os(iOS)
    /// The best installed voice for the phone's language: premium, then enhanced, then any.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }()
    #endif
}
