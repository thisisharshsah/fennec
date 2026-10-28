import Foundation
import Observation

/// Text or voice, for each direction of the conversation.
enum TalkMode: String, CaseIterable, Identifiable, Sendable {
    case text, voice

    var id: String { rawValue }
    var title: String { self == .text ? "Text" : "Voice" }
    var symbol: String { self == .text ? "text.bubble" : "waveform" }
}

/// How a voice is shaped: the creature's own high voice by default.
enum VoiceTone: String, CaseIterable, Identifiable, Sendable {
    case creature, tiny, natural, deep

    var id: String { rawValue }
    var title: String {
        switch self {
        case .creature: "Creature"
        case .tiny: "Tiny"
        case .natural: "Natural"
        case .deep: "Deep"
        }
    }
    var pitch: Float {
        switch self {
        case .creature: 1.35
        case .tiny: 1.75
        case .natural: 1.0
        case .deep: 0.75
        }
    }
    /// Relative to the system's default speaking rate.
    var rate: Float {
        switch self {
        case .creature: 1.03
        case .tiny: 1.08
        case .natural: 1.0
        case .deep: 0.94
        }
    }
}

/// How the creature replies and how the owner talks to it. Both start as text on every device:
/// nothing is spoken and the microphone stays off until the owner picks voice.
@MainActor @Observable
final class TalkPrefs {
    nonisolated static let replyKey = "talk.reply"
    nonisolated static let inputKey = "talk.input"
    nonisolated static let voiceKey = "talk.voice"
    nonisolated static let toneKey = "talk.tone"

    /// The creature's replies and notices: shown as text, or also spoken aloud.
    var reply: TalkMode { didSet { UserDefaults.standard.set(reply.rawValue, forKey: Self.replyKey) } }
    /// The owner's side: typing, or talking (hands-free with the voice button).
    var input: TalkMode { didSet { UserDefaults.standard.set(input.rawValue, forKey: Self.inputKey) } }
    /// An installed voice's identifier, or "" for the best voice of the device's language.
    var voiceID: String { didSet { UserDefaults.standard.set(voiceID, forKey: Self.voiceKey) } }
    var tone: VoiceTone { didSet { UserDefaults.standard.set(tone.rawValue, forKey: Self.toneKey) } }

    init() {
        reply = TalkMode(rawValue: UserDefaults.standard.string(forKey: Self.replyKey) ?? "") ?? .text
        input = TalkMode(rawValue: UserDefaults.standard.string(forKey: Self.inputKey) ?? "") ?? .text
        voiceID = UserDefaults.standard.string(forKey: Self.voiceKey) ?? ""
        tone = VoiceTone(rawValue: UserDefaults.standard.string(forKey: Self.toneKey) ?? "") ?? .creature
    }

    /// Read where no model is at hand (the voice itself).
    nonisolated static var speaks: Bool { UserDefaults.standard.string(forKey: replyKey) == TalkMode.voice.rawValue }
}
