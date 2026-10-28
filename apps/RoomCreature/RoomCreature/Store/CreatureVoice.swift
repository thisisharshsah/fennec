import Foundation
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// A creature's voice: what it says, read aloud by the iPhone while the app is open, in a higher,
/// quicker voice than the system default. iPhone only: the Mac is a test rig and stays silent.
@MainActor
final class CreatureVoice: NSObject {
    static let enabledKey = "voice.speaks"

    /// On unless the owner turned it off in Settings.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Run when the current line has been spoken (or was skipped), for the companion to listen again.
    private var whenDone: (() -> Void)?

    #if os(iOS)
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }
    #endif

    /// Speaks `text`. `always` speaks even with "Speak messages aloud" off (the companion mode asked for it).
    func say(_ text: String, always: Bool = false, then done: (() -> Void)? = nil) {
        #if os(iOS)
        guard always || Self.isEnabled, !text.isEmpty else { done?(); return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.pitchMultiplier = 1.35
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.03
        whenDone = done
        synthesizer.speak(utterance)
        #else
        done?()
        #endif
    }

    func stop() {
        whenDone = nil
        #if os(iOS)
        synthesizer.stopSpeaking(at: .immediate)
        #endif
    }

    fileprivate func finished() {
        guard let done = whenDone else { return }
        whenDone = nil
        done()
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

#if os(iOS)
extension CreatureVoice: AVSpeechSynthesizerDelegate {
    // called on the synthesizer's own thread: hop to the main actor
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
#endif
