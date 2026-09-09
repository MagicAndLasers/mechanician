import Foundation
import AVFoundation
import Speech
import SwiftUI   // VoiceWaveform (the composer's live recording indicator) lives below

/// On-device dictation for the composer: taps the mic, streams audio into `SFSpeechRecognizer`
/// (on-device when the locale supports it), and publishes the running transcript. The composer
/// owns how the transcript is spliced into the field; this class just captures + recognizes.
///
/// Continuity across pauses is the subtle part. When you pause mid-dictation, the recognizer keeps
/// the task alive but *resets* `formattedString` to the new utterance — so naively assigning
/// `transcript = formattedString` makes the words after a pause OVERWRITE the words before it. We
/// instead keep `committed` text from finished utterances and append the live partial to it, so a
/// pause commits a segment rather than erasing it. Utterance boundaries are detected three ways: a
/// reset (the partial jumps to a fresh, unrelated utterance), an `isFinal` result, and errors.
@MainActor
final class SpeechDictation: ObservableObject {
    @Published private(set) var isRecording = false
    /// The full transcript-so-far (committed utterances + the live partial); the composer observes
    /// this and splices it into the field. Only ever grows during a session.
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?
    /// Rolling mic loudness (0–1, newest last) for the composer's live waveform strip. Tap buffers
    /// arrive every ~20 ms — too fast to read as a waveform — so samples are coalesced to one bar
    /// per ~70 ms (keeping the loudest), giving the Cowork-style dots-and-bars timeline. Capped at
    /// a few hundred so long dictations scroll instead of growing unboundedly.
    @Published private(set) var levels: [CGFloat] = []
    private var pendingPeak: CGFloat = 0
    private var lastLevelAt = Date.distantPast

    func pushLevel(_ l: CGFloat) {
        guard isRecording else { return }
        pendingPeak = max(pendingPeak, l)
        let now = Date()
        guard now.timeIntervalSince(lastLevelAt) >= 0.07 else { return }
        lastLevelAt = now
        levels.append(pendingPeak)
        pendingPeak = 0
        if levels.count > 300 { levels.removeFirst(levels.count - 300) }
    }

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private let box = RequestBox()

    /// Text from utterances already finalized (each pause commits one). The live partial is
    /// appended to this, so a pause never overwrites earlier words.
    private var committed = ""
    /// The current utterance's latest partial transcription.
    private var segment = ""
    /// Bumped whenever we open a new recognition request, so stale callbacks from a finished
    /// request are ignored.
    private var generation = 0
    /// Prefer on-device (private, offline) recognition; flipped to server after a one-time
    /// fallback if the on-device model errors (e.g. not downloaded yet).
    private var onDevicePreferred = true
    private var triedServerFallback = false
    /// Guards against a tight reopen loop if recognition keeps erroring with no progress.
    private var rapidErrorCount = 0

    /// A thread-safe holder for the active recognition request. The realtime audio tap appends to
    /// whatever request is current; we swap it (under a lock) when a request is reopened. Keeping
    /// this off the main actor avoids touching actor-isolated state from the realtime audio thread.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
        func append(_ b: AVAudioPCMBuffer) { lock.lock(); let r = request; lock.unlock(); r?.append(b) }
        func end() { lock.lock(); request?.endAudio(); lock.unlock() }
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        errorMessage = nil
        triedServerFallback = false
        onDevicePreferred = true
        rapidErrorCount = 0
        committed = ""
        segment = ""
        transcript = ""
        // MICROPHONE first, THEN speech recognition. Requesting the mic first is what registers
        // the app in System Settings ▸ Privacy & Security ▸ Microphone (registration happens on
        // the first AVCaptureDevice.requestAccess call). Requesting speech first — and bailing if
        // it's declined — meant the mic request never fired, so the app never appeared in that
        // list and voice couldn't be enabled at all.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard mic else {
                self.errorMessage = "Microphone access denied. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone."
                return
            }
            let speech = await Self.requestSpeechAuthorization()
            guard speech == .authorized else {
                self.errorMessage = "Speech recognition isn't authorized. Turn it on in System Settings ▸ Privacy & Security ▸ Speech Recognition."
                return
            }
            self.beginCapture()
        }
    }

    /// async wrapper over the callback-based speech authorization request.
    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    /// Start the mic engine (once for the session) and open the first recognition request.
    private func beginCapture() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable for your language."
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero-channel / zero-rate format means the mic isn't actually available — bail with a
        // clear message instead of installing a tap that captures silence.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            errorMessage = "No microphone input available."
            NSLog("MECHVOICE invalid input format: \(format)")
            return
        }
        // The tap fires on the realtime audio thread; it appends to whatever request the box holds
        // (swapped when we reopen). It never touches main-actor state — the level is computed here
        // and hopped to main for the waveform.
        let box = self.box
        let fan = self.fan
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            box.append(buffer)   // legacy SFSpeechRecognizer path (no-op when no request is set)
            fan.send(buffer)     // modern SpeechAnalyzer path (no-op when no sink is set)
            // RMS of channel 0 → a 0–1 loudness for the live waveform. Perceptual (log) mapping so
            // normal speech moves the bars instead of pinning near zero.
            if let data = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                guard n > 0 else { return }
                var sum: Float = 0
                for i in 0..<n { sum += data[i] * data[i] }
                let rms = sqrt(sum / Float(n))
                let db = 20 * log10(max(rms, 0.000_01))            // ≈ -100…0 dB
                let norm = CGFloat(min(max((db + 50) / 50, 0), 1)) // -50 dB floor → 0…1
                DispatchQueue.main.async { self?.pushLevel(norm) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[dictation] microphone could not start: %@", error.localizedDescription)
            errorMessage = "Mechanician couldn’t start the microphone. Check that it is connected "
                + "and not in use by another app."
            hardStop()
            return
        }
        isRecording = true
        // Prefer the modern SpeechAnalyzer/SpeechTranscriber stack (macOS 26 "Golden Gate"-era
        // Speech framework: fully on-device, volatile+final results, long-form). Any setup failure
        // falls back to the SFSpeechRecognizer path at runtime. Escape hatch: `voiceLegacySF`.
        if #available(macOS 26.0, *), !UserDefaults.standard.bool(forKey: "voiceLegacySF") {
            startModern(tapFormat: format)
        } else {
            openRequest()
        }
    }

    /// Thread-safe optional buffer sink feeding the modern analyzer from the realtime tap.
    private final class BufferFan: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: ((AVAudioPCMBuffer) -> Void)?
        func set(_ s: ((AVAudioPCMBuffer) -> Void)?) { lock.lock(); sink = s; lock.unlock() }
        func send(_ b: AVAudioPCMBuffer) { lock.lock(); let s = sink; lock.unlock(); s?(b) }
    }
    private let fan = BufferFan()
    private var modernActive = false
    private var modernTask: Task<Void, Never>?
    /// AsyncStream<AnalyzerInput>.Continuation, stored as Any because the type is macOS 26+.
    private var modernContinuation: Any?

    @available(macOS 26.0, *)
    private func startModern(tapFormat: AVAudioFormat) {
        modernActive = true
        modernTask = Task { @MainActor [weak self] in
            do {
                let transcriber = SpeechTranscriber(locale: Locale.current,
                                                    transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults],
                                                    attributeOptions: [])
                // On-device model assets download once per locale; instant no-op afterwards.
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await req.downloadAndInstall()
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw NSError(domain: "MechVoice", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "no compatible analyzer audio format"])
                }
                let converter = tapFormat == analyzerFormat ? nil : AVAudioConverter(from: tapFormat, to: analyzerFormat)
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                guard let self, self.isRecording else { return }
                self.modernContinuation = continuation
                self.fan.set { buffer in
                    let out: AVAudioPCMBuffer
                    if let converter {
                        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
                        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { return }
                        var err: NSError?
                        var fed = false
                        // `convert(to:error:withInputFrom:)` invokes its input block synchronously on
                        // this thread and does not retain it, so the buffer never escapes — but the
                        // block type is `@Sendable` and `AVAudioPCMBuffer` is not. The annotation
                        // states that contract; it does not move the buffer anywhere.
                        nonisolated(unsafe) let input = buffer
                        converter.convert(to: converted, error: &err) { _, status in
                            if fed { status.pointee = .noDataNow; return nil }
                            fed = true; status.pointee = .haveData; return input
                        }
                        guard err == nil, converted.frameLength > 0 else { return }
                        out = converted
                    } else {
                        out = buffer
                    }
                    continuation.yield(AnalyzerInput(buffer: out))
                }
                try await analyzer.start(inputSequence: stream)
                // Volatile results REPLACE the live segment; finals COMMIT it — mapping exactly
                // onto the class's committed/segment model, so the composer splice is unchanged.
                for try await result in transcriber.results {
                    guard self.isRecording, self.modernActive else { break }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.committed = self.joined(self.committed, text)
                        self.segment = ""
                    } else {
                        self.segment = text
                    }
                    self.transcript = self.joined(self.committed, self.segment)
                }
            } catch {
                NSLog("MECHVOICE SpeechAnalyzer failed, falling back to SFSpeechRecognizer: \(error)")
                guard let self, self.isRecording else { return }
                self.teardownModern()
                self.openRequest()   // legacy path takes over on the same running engine
            }
        }
    }

    private func teardownModern() {
        modernActive = false
        fan.set(nil)
        if #available(macOS 26.0, *) {
            (modernContinuation as? AsyncStream<AnalyzerInput>.Continuation)?.finish()
        }
        modernContinuation = nil
        modernTask?.cancel()
        modernTask = nil
    }

    /// Open a fresh recognition request/task against the already-running engine. Called initially
    /// and again after an `isFinal`/error boundary, so dictation continues instead of ending.
    private func openRequest() {
        guard let recognizer, isRecording else { return }
        generation += 1
        let gen = generation
        segment = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevicePreferred && recognizer.supportsOnDeviceRecognition
        box.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isRecording, gen == self.generation else { return }
                if let result {
                    self.rapidErrorCount = 0
                    let partial = result.bestTranscription.formattedString
                    // A pause keeps the task alive but resets `formattedString` to a fresh
                    // utterance. Detect that and commit the previous one so it isn't overwritten.
                    if self.looksLikeReset(from: self.segment, to: partial) {
                        self.committed = self.joined(self.committed, self.segment)
                    }
                    self.segment = partial
                    self.transcript = self.joined(self.committed, self.segment)
                    if result.isFinal { self.commitAndReopen() }
                } else if let error {
                    self.handleError(error, wasOnDevice: request.requiresOnDeviceRecognition)
                }
            }
        }
    }

    /// Commit the current utterance and open a fresh request so dictation keeps going (used at an
    /// `isFinal` boundary and after a recoverable error).
    private func commitAndReopen() {
        committed = joined(committed, segment)
        transcript = committed
        segment = ""
        box.end()
        task?.finish()
        task = nil
        openRequest()
    }

    private func handleError(_ error: Error, wasOnDevice: Bool) {
        NSLog("MECHVOICE recognition error: \(error.localizedDescription)")
        // On-device model may not be downloaded yet — retry once via server, before any text.
        if wasOnDevice && !triedServerFallback && committed.isEmpty && segment.isEmpty {
            triedServerFallback = true
            onDevicePreferred = false
            box.end()
            task?.cancel()
            task = nil
            openRequest()
            return
        }
        rapidErrorCount += 1
        // Bail out of a tight loop if recognition keeps failing with no progress (e.g. mic lost).
        if rapidErrorCount >= 5 {
            if committed.isEmpty && segment.isEmpty {
                NSLog("[dictation] recognition kept failing: %@", error.localizedDescription)
                errorMessage = "Mechanician stopped dictation because it couldn’t hear anything. "
                    + "Check your microphone and try again."
            }
            stop()
            return
        }
        // Otherwise this is a normal endpoint/no-speech error — keep the session alive by
        // committing what we have and reopening, so the user can keep dictating.
        commitAndReopen()
    }

    func stop() {
        guard isRecording else { return }
        // Fold the in-flight partial into the transcript so nothing is lost on stop.
        transcript = joined(committed, segment)
        isRecording = false
        levels = []
        hardStop()
    }

    /// Clear the accumulated transcript while KEEPING the mic on — used when the composer submits
    /// a dictated message: the input box empties and further speech starts a fresh transcript.
    /// Reopens the recognition request so the recognizer's own formattedString restarts too;
    /// otherwise the next partial would re-surface the words we just cleared.
    func reset() {
        committed = ""
        segment = ""
        transcript = ""
        guard isRecording else { return }
        // Modern path: the analyzer keeps running; clearing the text state is the whole reset
        // (volatile results replace the segment, so nothing re-surfaces the cleared words).
        if modernActive { return }
        box.end()
        task?.finish()
        task = nil
        openRequest()
    }

    /// Tear down engine + task. `generation` is bumped so any late recognition callback is ignored.
    private func hardStop() {
        generation += 1
        teardownModern()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        box.end()
        box.set(nil)
        task?.cancel()
        task = nil
    }

    /// Heuristic utterance-boundary detector: a live partial being *revised* keeps the same
    /// beginning, while a post-pause reset jumps to a different, usually shorter utterance.
    private func looksLikeReset(from old: String, to new: String) -> Bool {
        guard !old.isEmpty, !new.isEmpty else { return false }
        // Different opening characters → a new utterance, not a revision of the old one.
        if old.prefix(2).lowercased() != new.prefix(2).lowercased() { return true }
        // Or a dramatic shortening — the recognizer dropped back to a fresh, shorter utterance.
        return new.count * 2 < old.count
    }

    /// Join two fragments with a single separating space when needed.
    private func joined(_ base: String, _ next: String) -> String {
        if base.isEmpty { return next }
        if next.isEmpty { return base }
        let needsSpace = !base.hasSuffix(" ") && !next.hasPrefix(" ")
        return base + (needsSpace ? " " : "") + next
    }
}

/// The live dictation waveform — a full-width dots-and-bars timeline (à la Claude Cowork), lit with
/// the Magic & Lasers beam: each bar takes a color from the violet→gold→teal→pink spectrum, the
/// spectrum slowly drifts, and brightness/height track loudness. Silence renders as dim beam-tinted
/// dots, speech as glowing bars. Pure render; no audio access.
struct VoiceWaveform: View {
    let levels: [CGFloat]
    /// Below this a sample reads as silence → dot.
    private static let silence: CGFloat = 0.08

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let drift = (timeline.date.timeIntervalSinceReferenceDate * 0.06)
            GeometryReader { geo in
                let slot: CGFloat = 5                       // bar width + gap
                let count = max(Int(geo.size.width / slot), 10)
                let recent = Array(levels.suffix(count))
                let maxH = geo.size.height
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(recent.indices, id: \.self) { i in
                        let l = recent[i]
                        let quiet = l < Self.silence
                        // Position along the spectrum + a slow drift so the colors flow as bars scroll.
                        let hue = MagicBeam.color(at: Double(i) / Double(max(count - 1, 1)), shift: drift)
                        Capsule()
                            .fill(hue.opacity(quiet ? 0.30 : 0.55 + 0.45 * l))
                            .frame(width: 2.5, height: quiet ? 2.5 : max(4, l * maxH))
                            // A soft same-color bloom on louder bars — the "glowing beam" feel.
                            .shadow(color: hue.opacity(quiet ? 0 : 0.5 * l), radius: quiet ? 0 : 2 + 3 * l)
                    }
                    Spacer(minLength: 0)                    // history fills left→right like Cowork
                }
                .frame(height: maxH)
                .animation(.linear(duration: 0.07), value: levels.count)
            }
        }
        .accessibilityHidden(true)
    }
}
