import Foundation
@preconcurrency import AVFoundation

/// A creature's voice: what it says, read aloud while the app is open, in a higher, quicker voice than
/// the system default. Only when the owner set replies to voice (TalkPrefs); text is the default.
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.pitchMultiplier = 1.35
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.03
        whenDone = done
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

    /// The best installed voice for the phone's language: premium, then enhanced, then any.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }()
}

extension CreatureVoice: AVSpeechSynthesizerDelegate {
    // called on the synthesizer's own thread: hop to the main actor
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
