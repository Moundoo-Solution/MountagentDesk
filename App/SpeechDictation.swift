import AudioToolbox
import AVFoundation
import Observation
import Speech

/// Voice input for the composer: the microphone streamed into Apple's speech recognizer,
/// with partial results so the words appear while you talk.
///
/// The audio tap and the recognizer call back on their own threads. Their closures are built
/// in `nonisolated` functions so they don't inherit main-actor isolation (which would trap
/// off the main thread), and they hop back to the main actor to touch state.
@MainActor @Observable
final class SpeechDictation {
    enum Status: Equatable {
        case idle
        case listening
        /// Permission missing: the message says where to grant it.
        case denied(String)
        case failed(String)
    }

    static let languages: [(id: String, title: String, short: String)] = [
        ("vi-VN", "Tiếng Việt", "VI"),
        ("en-US", "English", "EN"),
    ]

    /// Words the agents' users say often, so mixed Vietnamese and English comes out right.
    private static let vocabulary = [
        "sync", "ticket", "task", "commit", "push", "pull", "merge", "branch", "staging", "main",
        "cherry-pick", "rebase", "pull request", "Claude", "Cursor", "module", "model",
        "view", "field", "test", "deploy", "bug", "fix", "refactor", "API", "SQL", "Python",
    ]

    private(set) var status: Status = .idle
    /// Microphone level, 0…1, smoothed, while listening.
    private(set) var level: Double = 0
    /// The microphone in use while listening.
    private(set) var microphone: String?
    /// Set when the microphone has stayed silent for a few seconds: usually the wrong one.
    private(set) var hearsNothing = false
    /// What has been recognised in this session, for the Settings test.
    private(set) var transcript = ""
    var isListening: Bool { status == .listening }
    private var peak: Double = 0
    private var quietCheck: Task<Void, Never>?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var onText: ((String) -> Void)?
    private var onSilence: (() -> Void)?
    /// Bumped per session, so late callbacks from a finished one are ignored.
    private var generation = 0

    /// Starts listening. `onText` gets the whole transcript so far, each time it changes;
    /// `onSilence`, when given, fires once the speaker pauses and listening has stopped.
    /// `microphone` is a device UID; empty, or one that isn't plugged in, means the system default.
    func start(language: String, microphone uid: String = "", onText: @escaping (String) -> Void = { _ in }, onSilence: (() -> Void)? = nil) async {
        guard !isListening else { return }
        if let problem = await Self.authorize() {
            status = .denied(problem)
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            status = .failed("Speech recognition for \(Self.title(of: language)) isn't available right now.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Self.vocabulary

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let chosen = AudioInput.find(uid: uid)
        if let chosen, let unit = input.audioUnit {
            // Before reading the format: it is the device's.
            var device = chosen.deviceID
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if result != noErr {
                status = .failed("Couldn't switch to \(chosen.name) (error \(result)).")
                return
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            status = .failed("No microphone found.")
            return
        }
        generation += 1
        let box = Owner(self, generation: generation)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(feeding: request, owner: box))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            status = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        self.engine = engine
        self.request = request
        self.onText = onText
        self.onSilence = onSilence
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(owner: box))
        level = 0
        peak = 0
        hearsNothing = false
        transcript = ""
        microphone = (chosen ?? AudioInput.systemDefault())?.name
        status = .listening
        quietCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.isListening else { return }
            if self.peak < 0.08 { self.hearsNothing = true }
        }
    }

    /// Stops the microphone. The recognizer still delivers the words it was finishing.
    func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil
        quietCheck?.cancel()
        quietCheck = nil
        hearsNothing = false
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        request = nil
        level = 0
        if isListening { status = .idle }
    }

    /// Stops and drops anything still on its way, e.g. once the message has been sent.
    func cancel() {
        generation += 1
        task?.cancel()
        finish()
    }

    /// Clears a shown problem.
    func dismissProblem() {
        if !isListening { status = .idle }
    }

    private func finish() {
        stop()
        task = nil
        onText = nil
        onSilence = nil
    }

    fileprivate func receive(text: String?, isFinal: Bool, error: String?, generation: Int) {
        guard generation == self.generation, task != nil else { return }
        if let text, !text.isEmpty {
            transcript = text
            onText?(text)
            if isListening, onSilence != nil { restartSilenceTimer() }
        }
        if isFinal || error != nil {
            // "No speech detected" after a stop is not worth reporting.
            if let error, isListening, text == nil {
                status = .failed(error)
            }
            finish()
        }
    }

    fileprivate func receive(level newLevel: Double, generation: Int) {
        guard generation == self.generation, isListening else { return }
        level = level * 0.6 + newLevel * 0.4
        peak = max(peak, newLevel)
        if hearsNothing, newLevel > 0.15 { hearsNothing = false }
    }

    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self, self.isListening else { return }
            let action = self.onSilence
            self.stop()
            // Let the recognizer settle the last words before sending.
            try? await Task.sleep(for: .milliseconds(500))
            action?()
        }
    }

    static func title(of language: String) -> String {
        languages.first { $0.id == language }?.title ?? language
    }

    static func short(of language: String) -> String {
        languages.first { $0.id == language }?.short ?? language.prefix(2).uppercased()
    }

    // MARK: - Callbacks off the main thread

    /// A weak, Sendable handle the background callbacks can carry.
    private final class Owner: @unchecked Sendable {
        weak var dictation: SpeechDictation?
        let generation: Int

        init(_ dictation: SpeechDictation, generation: Int) {
            self.dictation = dictation
            self.generation = generation
        }
    }

    private nonisolated static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest, owner: Owner) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            request.append(buffer)
            let level = normalizedLevel(of: buffer)
            let generation = owner.generation
            Task { @MainActor in owner.dictation?.receive(level: level, generation: generation) }
        }
    }

    private nonisolated static func results(owner: Owner) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            let generation = owner.generation
            Task { @MainActor in owner.dictation?.receive(text: text, isFinal: isFinal, error: message, generation: generation) }
        }
    }

    /// RMS of the first channel on a -50…-10 dB scale, as 0…1.
    private nonisolated static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(count))
        let decibels = 20 * log10(max(rms, 1e-7))
        return Double(min(1, max(0, (decibels + 50) / 40)))
    }

    /// Asks for speech recognition, then the microphone. Returns what is missing, if anything.
    private nonisolated static func authorize() async -> String? {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            return "Allow Speech Recognition for Mountagent Desk in System Settings → Privacy & Security."
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return "Allow the Microphone for Mountagent Desk in System Settings → Privacy & Security."
        }
        return nil
    }
}
