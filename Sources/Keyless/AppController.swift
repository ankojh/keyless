import AppKit
import AVFoundation
import KeylessCore

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private var session: SessionController
    private var echo: EchoGuard
    private let phonon: PhononService
    private let stream = SpeechStream()
    private let capture = AudioCapture()
    private let text = FocusedTextAdapter()
    private let executor = ActionExecutor()
    private let feedback = Feedback()
    private let overlay = OverlayPanel()
    private var statusItem: NSStatusItem!

    private var muted = false
    private let recorder = EnrollmentRecorder()
    private var gate: SpeakerGate?
    private var enrolling = false
    private var streamEpoch = 0
    private var streamReady = false
    private var validateTimer: Timer?

    // Latency metrics (numbers only).
    private var pendingOnset: Double?

    override init() {
        let address = UserDefaults.standard.string(forKey: "addressPhrase") ?? "computer"
        let grammar = CommandGrammar(addressPhrase: address)
        session = SessionController(grammar: grammar)
        echo = EchoGuard(grammar: grammar)
        phonon = PhononService(executable: Self.fermionExecutable())
        super.init()
    }

    // MARK: Startup

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatus()
        overlay.model.onQuit = { NSApp.terminate(nil) }
        overlay.model.onLearnVoice = { [weak self] in self?.startEnrollment() }
        setUpVoiceFilter()
        overlay.model.onToggleMute = { [weak self] in self?.toggleMute() }
        overlay.show()
        // The MacBook notch silently hides menu bar items that don't fit; record whether ours shows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.statusItem.button?.window else { return Logs.event("status item: no window") }
                Logs.event("status item visible=\(window.occlusionState.contains(.visible)) x=\(Int(window.frame.minX))")
            }
        }

        feedback.onStart = { [weak self] phrase in self?.echo.didStartSpeaking(phrase, at: Self.now) }
        feedback.onFinish = { [weak self] in self?.echo.didFinishSpeaking(at: Self.now) }
        stream.onFrame = { [weak self] delivery in self?.received(delivery) }
        stream.onClosed = { [weak self] epoch, reason in self?.streamClosed(epoch: epoch, reason: reason) }
        capture.onSpeechOnset = { [weak self] t in self?.pendingOnset = t }
        capture.onError = { [weak self] message in self?.setDetail(message) }
        let stream = self.stream, recorder = self.recorder
        capture.onSamples = { samples in
            stream.send(samples)
            recorder.append(samples)
        }

        phonon.onStateChange = { [weak self] state in self?.phononChanged(state) }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudioPath(reason: "Mac woke") }
        }

        requestPermissions()
        phonon.start()
    }

    func shutdown() {
        capture.stop()
        stream.close()
        phonon.stop()
    }

    private func requestPermissions() {
        // Accessibility shows the system prompt once; the app can't grant it to itself.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Logs.event("accessibility not yet granted")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        Logs.event("microphone access \(granted ? "granted" : "denied")")
                        self?.startAudioIfReady()
                    }
                }
            }
        }
    }

    private func phononChanged(_ state: PhononService.State) {
        Logs.event("phonon \(state)")
        switch state {
        case .ready:
            setDetail("Warming up speech…")
            Task { await warmUpThenListen() }
        case .starting:
            setDetail("Loading speech model…")
        case .failed(let message):
            streamReady = false
            setDetail(message)
        case .stopped:
            streamReady = false
        }
        refreshStatus()
    }

    private func warmUpThenListen() async {
        let started = Self.now
        if let samples = Self.warmUpSamples() {
            let ok = await SpeechStream.warmUp(url: phonon.streamURL, apiKey: phonon.apiKey, samples: samples)
            Logs.metric("warmup", ["ok": ok, "ms": Int((Self.now - started) * 1000)])
        }
        streamReady = true
        startAudioIfReady()
    }

    private func startAudioIfReady() {
        guard streamReady, !muted else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            setDetail("Microphone permission is needed: System Settings › Privacy & Security › Microphone.")
            return
        }
        connectStream()
        if !capture.isRunning {
            do {
                try capture.start()
                Logs.event("capture started")
            } catch {
                Logs.event("capture failed: \(error.localizedDescription)")
                setDetail(error.localizedDescription)
            }
        }
        setDetail(session.mode == .sleeping ? "Say “\(addressWord), wake up.”" : "")
        refreshStatus()
    }

    private func connectStream() {
        streamEpoch += 1
        framesThisEpoch = 0
        stream.connect(url: phonon.streamURL, apiKey: phonon.apiKey)
    }

    private func restartAudioPath(reason: String) {
        Logs.event("restarting audio path: \(reason)")
        guard streamReady, !muted else { return }
        capture.stop()
        echo.resetSegment()
        apply(session.handle(.streamRestarted))
        startAudioIfReady()
    }

    private func streamClosed(epoch: Int, reason: String) {
        Logs.event("stream \(epoch) closed: \(reason)")
        guard epoch == streamEpoch, !muted, streamReady else { return }
        echo.resetSegment()
        apply(session.handle(.streamRestarted))
        // Reconnect shortly; the new epoch discards anything the old stream still delivers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, epoch == self.streamEpoch, self.streamReady, !self.muted else { return }
                self.connectStream()
            }
        }
    }

    // MARK: Recognizer frames

    private var framesThisEpoch = 0

    private func received(_ delivery: SpeechStream.Delivery) {
        guard delivery.epoch == streamEpoch else { return }
        framesThisEpoch += 1
        if framesThisEpoch == 1 {
            Logs.event("stream \(delivery.epoch) first frame at audio \(String(format: "%.1f", delivery.audioTime)) s")
        }
        if case .error(let message) = delivery.frame { Logs.event("stream error: \(message)") }

        let textOfFrame: String? = switch delivery.frame {
        case .partial(let t), .final(let t, _): t
        default: nil
        }
        if let t = textOfFrame {
            let isFinal = if case .final = delivery.frame { true } else { false }
            // Outside dictation an echo could trigger an action, so be strict there.
            if echo.shouldDrop(t, isFinal: isFinal, at: Self.now, strict: session.mode != .dictating) {
                if isFinal { Logs.metric("echo_dropped") }
                return
            }
        }

        // While enrolling, the user is reading a passage aloud; none of it is a command.
        if enrolling { return }
        let effects = session.handle(.asr(delivery.frame, audioTime: delivery.audioTime, speaker: delivery.speaker))
        let editsBefore = editsApplied
        apply(effects)
        if editsApplied > editsBefore {
            Logs.metric("frame_to_edit", ["ms": Int((Self.now - delivery.receivedAt) * 1000)])
            if let onset = pendingOnset {
                Logs.metric("onset_to_text", ["ms": Int((Self.now - onset) * 1000)])
                pendingOnset = nil
            }
        }
    }

    // MARK: Effects

    private var editsApplied = 0

    private func apply(_ effects: [SessionEffect]) {
        for effect in effects {
            switch effect {
            case .modeChanged(let mode):
                Logs.event("mode \(mode)")
                modeChanged(mode)
            case .speak(let phrase):
                feedback.say(phrase)
                setDetail(phrase)
            case .chime(let chime):
                Self.play(chime)
            case .overlay(let provisional, let held):
                overlay.model.transcript = provisional
                overlay.model.held = held
            case .prepareDictationTarget:
                switch text.prepare() {
                case .ready(let leading):
                    apply(session.handle(.dictationTargetReady(leadingContext: leading)))
                case .refused(let reason):
                    apply(session.handle(.dictationTargetRefused(reason: reason)))
                }
            case .releaseDictationTarget:
                text.release()
            case .edit(let edit):
                if let problem = text.apply(edit) {
                    Logs.event("edit refused: \(problem)")
                    apply(session.handle(.dictationInterrupted(reason: problem)))
                    return
                }
                editsApplied += 1
            case .perform(let command):
                let started = Self.now
                Task {
                    let problem = await executor.perform(command)
                    Logs.metric("action", ["ms": Int((Self.now - started) * 1000), "ok": problem == nil])
                    // Success is visible on screen; speak only when something went wrong.
                    if let problem { feedback.say(problem); setDetail(problem) }
                }
            case .cancelPending:
                executor.cancelAll()
            case .learnVoice:
                startEnrollment()
            case .quit:
                Logs.event("quit by voice")
                NSApp.terminate(nil)
            }
        }
    }

    private func modeChanged(_ mode: Mode) {
        validateTimer?.invalidate()
        validateTimer = nil
        if mode == .dictating {
            // Catch focus or caret changes between edits, so no buffered text lands elsewhere.
            validateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let problem = self.text.validate() else { return }
                    self.apply(self.session.handle(.dictationInterrupted(reason: problem)))
                }
            }
        }
        if mode == .sleeping { setDetail("Say “\(addressWord), wake up.”") }
        refreshStatus()
    }

    // MARK: Status UI

    private var addressWord: String { session.grammar.addressPhrase.joined(separator: " ").capitalized }

    private var modeLabel: String {
        if muted { return "Muted" }
        switch session.mode {
        case .sleeping: return "Sleeping"
        case .control: return "Listening"
        case .dictating: return "Dictating"
        }
    }

    private func refreshStatus() {
        let symbol = switch (muted, session.mode) {
        case (true, _): "mic.slash"
        case (_, .sleeping): "moon.zzz"
        case (_, .control): "waveform"
        case (_, .dictating): "pencil.line"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: modeLabel)
        overlay.model.mode = "Keyless · \(modeLabel)"
        overlay.model.muted = muted
        overlay.model.enrolled = gate?.isEnrolled == true
    }

    private func setDetail(_ detail: String) {
        overlay.model.detail = detail
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Keyless: \(modeLabel)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let mute = menu.addItem(withTitle: muted ? "Unmute Microphone" : "Mute Microphone (turns off voice wake)",
                                action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        menu.addItem(.separator())
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        let micItem = menu.addItem(withTitle: "Microphone: \(mic ? "allowed" : "needs permission")", action: #selector(openMicSettings), keyEquivalent: "")
        micItem.target = self
        let axItem = menu.addItem(withTitle: "Accessibility: \(ax ? "allowed" : "needs permission")", action: #selector(openAXSettings), keyEquivalent: "")
        axItem.target = self
        let speech = switch phonon.state {
        case .ready: "ready"
        case .starting: "loading"
        case .stopped: "stopped"
        case .failed(let m): m
        }
        menu.addItem(withTitle: "Speech: \(speech)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        if gate == nil {
            menu.addItem(withTitle: "Voice filter: unavailable (speaker model missing)", action: nil, keyEquivalent: "")
        } else {
            let enrolled = gate?.isEnrolled == true
            menu.addItem(withTitle: enrolled ? "Voice filter: on, commands only from your voice" : "Voice filter: off, any voice can give commands",
                         action: nil, keyEquivalent: "")
            let learn = menu.addItem(withTitle: enrolled ? "Re-learn My Voice…" : "Learn My Voice…", action: #selector(learnVoiceFromMenu), keyEquivalent: "")
            learn.target = self
            if enrolled {
                let forget = menu.addItem(withTitle: "Forget My Voice", action: #selector(forgetVoice), keyEquivalent: "")
                forget.target = self
            }
        }
        menu.addItem(.separator())
        let logs = menu.addItem(withTitle: "Open Logs Folder", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(withTitle: "Quit Keyless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func toggleMute() {
        muted.toggle()
        if muted {
            capture.stop()
            stream.close()
            apply(session.handle(.streamRestarted))
            setDetail("Microphone off. Voice wake won't work until you unmute from the menu.")
        } else {
            startAudioIfReady()
        }
        refreshStatus()
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(Logs.directory)
    }

    // MARK: Voice filter

    private func setUpVoiceFilter() {
        guard let url = Self.speakerModel(), let embedder = SpeakerEmbedder(modelURL: url) else {
            Logs.event("voice filter unavailable: no speaker model")
            return
        }
        let gate = SpeakerGate(embedder: embedder, streamQueue: stream.queue)
        gate.setVoiceprint(VoiceStore.load(model: gate.modelName))
        gate.onScore = { score, verdict in
            Logs.metric("speaker_score", ["score": Double(score), "verified": verdict == .verified])
        }
        stream.gate = gate
        self.gate = gate
        Logs.event("voice filter \(gate.isEnrolled ? "on" : "off (not enrolled)") model=\(gate.modelName)")
    }

    @objc private func learnVoiceFromMenu() {
        startEnrollment()
    }

    @objc private func forgetVoice() {
        VoiceStore.delete()
        gate?.setVoiceprint(nil)
        Logs.event("voiceprint deleted")
        setDetail("Voice forgotten. Any voice can give commands.")
        refreshStatus()
    }

    private func startEnrollment() {
        guard let gate, !enrolling else { return }
        guard capture.isRunning else {
            setDetail("The microphone is off. Unmute to learn your voice.")
            return
        }
        enrolling = true
        apply(session.handle(.streamRestarted))
        recorder.start()
        Self.play(.awake)
        overlay.model.prompt = Enrollment.passage
        overlay.setExpanded(true)
        Logs.event("enrollment started")

        Task {
            for remaining in stride(from: Enrollment.seconds, to: 0, by: -1) {
                setDetail("Learning your voice: \(remaining) s left")
                try? await Task.sleep(for: .seconds(1))
            }
            let samples = recorder.stop()
            overlay.model.prompt = ""
            overlay.setExpanded(false)
            setDetail("Checking your recording…")
            let message = await finishEnrollment(samples, gate: gate)
            enrolling = false
            echo.resetSegment()
            setDetail(message.text)
            if message.ok { Self.play(.dictationOn) } else { feedback.say(message.text) }
            refreshStatus()
        }
    }

    private func finishEnrollment(_ samples: [Float], gate: SpeakerGate) async -> (ok: Bool, text: String) {
        let voiced = Enrollment.voicedAudio(samples)
        var embeddings: [[Float]] = []
        for window in Enrollment.windows(voiced) {
            if let e = await gate.embed(window) { embeddings.append(e) }
        }
        Logs.metric("enrollment", ["recorded_s": samples.count / 16000, "voiced_s": voiced.count / 16000, "windows": embeddings.count])
        do {
            let print = try Voiceprint.build(model: gate.modelName, embeddings: embeddings)
            try VoiceStore.save(print)
            gate.setVoiceprint(print)
            let scores = print.enrollmentScores.sorted()
            Logs.metric("voiceprint", ["min": Double(scores.first ?? 0), "median": Double(scores[scores.count / 2]), "threshold": Double(print.threshold)])
            Logs.event("voiceprint saved")
            return (true, "Voice learned. Only your voice can give commands now.")
        } catch Voiceprint.BuildError.notEnoughSpeech {
            return (false, "I didn't hear enough speech. Try again and read the whole passage.")
        } catch Voiceprint.BuildError.inconsistent {
            return (false, "That recording had more than one voice or a lot of noise. Try again somewhere quieter.")
        } catch {
            return (false, "I couldn't save your voice.")
        }
    }

    static func speakerModel() -> URL? {
        if let url = Bundle.main.url(forResource: "3dspeaker-eres2net-en", withExtension: "onnx") { return url }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/sherpa-onnx/models/3dspeaker-eres2net-en.onnx")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// Built-in system sounds; distinct enough to tell apart without looking.
    static func play(_ chime: Chime) {
        let name = switch chime {
        case .awake: "Tink"
        case .asleep: "Bottle"
        case .dictationOn: "Pop"
        case .dictationOff: "Morse"
        case .cancelled: "Funk"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Configuration

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// The prototype uses the pinned spike virtualenv. Set at bundle time or by KEYLESS_FERMION.
    static func fermionExecutable() -> URL {
        if let env = ProcessInfo.processInfo.environment["KEYLESS_FERMION"] { return URL(fileURLWithPath: env) }
        if let path = Bundle.main.object(forInfoDictionaryKey: "KeylessFermionPath") as? String { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: "/usr/local/bin/fermion")
    }

    static func warmUpSamples() -> [Float]? {
        guard let url = Bundle.main.url(forResource: "warmup", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate == 16000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
