#if os(iOS)
@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech

/// Hold to talk: the iPhone's microphone, turned into text on the phone itself where it can,
/// for the owner to talk to a creature instead of typing.
@MainActor @Observable
final class SpeechListener {
    private(set) var isListening = false
    /// What has been heard so far, updated while the owner speaks.
    private(set) var transcript = ""
    private(set) var problem: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finished = false

    func start() async {
        guard !isListening else { return }
        problem = nil
        transcript = ""
        finished = false
        guard await Self.permitted() else {
            problem = "Allow the microphone and Speech Recognition for Fennec in Settings."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            problem = "Speech recognition is not available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            Self.feed(engine.inputNode, into: request)
            engine.prepare()
            try engine.start()
            self.request = request
            task = Self.recognize(request, with: recognizer) { [weak self] text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.finished = true }
                }
            }
            isListening = true
        } catch {
            problem = "The microphone could not start."
            cleanUp()
        }
    }

    /// Stops listening and returns what was said (waits a moment for the last words).
    func finish() async -> String {
        guard isListening else { return "" }
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        for _ in 0..<15 where !finished {                    // up to 1.5 s for the final result
            try? await Task.sleep(for: .milliseconds(100))
        }
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanUp()
        return said
    }

    func cancel() {
        guard isListening else { return }
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        cleanUp()
    }

    private func cleanUp() {
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // The audio, recognition and permission callbacks arrive on background threads. Closures written
    // inside this main-actor class would be main-actor closures, and Swift stops the app when one runs
    // elsewhere, so they are made in these nonisolated functions instead.

    private nonisolated static func feed(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        with recognizer: SFSpeechRecognizer,
        update: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }

    private nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    private static func permitted() async -> Bool {
        guard await speechAllowed() else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
#endif
