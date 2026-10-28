import Foundation
import Observation

/// Text or voice, for each direction of the conversation.
enum TalkMode: String, CaseIterable, Identifiable, Sendable {
    case text, voice

    var id: String { rawValue }
    var title: String { self == .text ? "Text" : "Voice" }
    var symbol: String { self == .text ? "text.bubble" : "waveform" }
}

/// How the creature replies and how the owner talks to it. Both start as text on every device:
/// nothing is spoken and the microphone stays off until the owner picks voice.
@MainActor @Observable
final class TalkPrefs {
    nonisolated static let replyKey = "talk.reply"
    nonisolated static let inputKey = "talk.input"

    /// The creature's replies and notices: shown as text, or also spoken aloud.
    var reply: TalkMode { didSet { UserDefaults.standard.set(reply.rawValue, forKey: Self.replyKey) } }
    /// The owner's side: typing, or talking (hands-free with the voice button).
    var input: TalkMode { didSet { UserDefaults.standard.set(input.rawValue, forKey: Self.inputKey) } }

    init() {
        reply = TalkMode(rawValue: UserDefaults.standard.string(forKey: Self.replyKey) ?? "") ?? .text
        input = TalkMode(rawValue: UserDefaults.standard.string(forKey: Self.inputKey) ?? "") ?? .text
    }

    /// Read where no model is at hand (the voice itself).
    nonisolated static var speaks: Bool { UserDefaults.standard.string(forKey: replyKey) == TalkMode.voice.rawValue }
}
