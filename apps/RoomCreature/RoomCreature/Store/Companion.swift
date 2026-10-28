#if os(iOS)
import Foundation
import Observation

/// Voice companion mode: a hands-free conversation with one creature. It listens; a pause of
/// PAUSE_S after some words sends them; the creature's answer, notices and (while nobody is talking)
/// its thoughts are spoken; then it listens again. It never listens while the creature speaks, so it
/// does not hear itself. Ends when switched off or when the app leaves the screen.
@MainActor @Observable
final class Companion {
    enum Phase { case off, listening, waiting, speaking }

    private(set) var phase: Phase = .off
    private(set) var unitID: String?
    var isOn: Bool { phase != .off }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var toldBrainOff = false

    private static let pauseS = 1.3
    private static let answerWaitS = 45.0          // the local model takes about 7 to 15 s, more when it first loads

    func attach(_ model: AppModel) {
        self.model = model
    }

    func start(unit: String) {
        guard let model, phase == .off else { return }
        unitID = unit
        toldBrainOff = false
        model.voice.stop()
        listen()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        model?.listener.cancel()
        model?.voice.stop()
        phase = .off
        unitID = nil
    }

    /// The creature said something while the companion is on. Thoughts wait if the owner is mid-sentence.
    func creatureSays(_ text: String, isThought: Bool) {
        guard let model, isOn else { return }
        if isThought && (phase != .listening || !model.listener.transcript.isEmpty) { return }
        loop?.cancel()
        model.listener.cancel()
        phase = .speaking
        model.voice.say(text, always: true) { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.listen()
        }
    }

    private func listen() {
        guard let model else { return }
        phase = .listening
        loop?.cancel()
        loop = Task { [weak self] in
            await model.listener.start()
            guard let self, !Task.isCancelled else { return }
            guard model.listener.isListening else { self.stop(); return }       // no microphone permission
            var last = ""
            var changed = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let heard = model.listener.transcript
                if heard != last { last = heard; changed = .now }
                if !heard.isEmpty && Date.now.timeIntervalSince(changed) > Self.pauseS { break }
            }
            guard !Task.isCancelled, self.phase == .listening else { return }
            let said = await model.listener.finish()
            guard self.phase == .listening else { return }
            if said.isEmpty { self.listen(); return }
            self.send(said)
        }
    }

    private func send(_ said: String) {
        guard let model, let unitID else { return }
        model.sendMessage(said, to: unitID)
        if let brain = model.store.brain, !(brain.hasKey ?? false) {
            if toldBrainOff { listen(); return }
            toldBrainOff = true
            creatureSays("I can hear you, but my thinking part is not switched on yet. Your words are saved for later.", isThought: false)
            return
        }
        phase = .waiting
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.answerWaitS))
            guard let self, !Task.isCancelled, self.phase == .waiting else { return }
            self.listen()                                // no answer came: listen again
        }
    }
}
#endif
