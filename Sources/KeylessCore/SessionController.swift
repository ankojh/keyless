import Foundation

public enum Mode: Equatable, Sendable {
    /// Listening only for the addressed wake phrase. No cloud requests or desktop actions.
    case sleeping
    /// Interpreting commands; the address phrase is optional.
    case control
    /// Speech goes to the focused input; only addressed commands are consumed.
    case dictating
}

public enum Chime: Equatable, Sendable {
    case awake, asleep, dictationOn, dictationOff, cancelled
}

public enum SessionInput: Equatable, Sendable {
    /// A recognizer frame. `audioTime` is seconds of audio sent on this stream when it arrived.
    /// `speaker` is the voice filter's verdict on the segment so far; `.verified` when no voice is enrolled.
    case asr(ASRFrame, audioTime: Double, speaker: SpeakerVerdict = .verified)
    /// The recognizer stream was replaced; any in-flight segment is gone.
    case streamRestarted
    /// The app found a supported focused input. `leadingContext` is the character before the caret.
    case dictationTargetReady(leadingContext: Character?)
    case dictationTargetRefused(reason: String)
    /// Focus, caret or field text changed under the session, or an edit failed verification.
    case dictationInterrupted(reason: String)
}

public enum SessionEffect: Equatable, Sendable {
    case modeChanged(Mode)
    /// Spoken only when the user needs to know something: a problem or a clarification.
    case speak(String)
    /// A short non-verbal sound for routine state changes. Sounds don't echo into the recognizer as words.
    case chime(Chime)
    /// Live transcript for the status overlay. `held` is text withheld as a possible command.
    case overlay(provisional: String, held: Bool)
    /// Ask the app to capture the focused input and reply with a target event.
    case prepareDictationTarget
    case releaseDictationTarget
    case edit(TextEdit)
    /// A desktop action for the app's executor. Policy gating happens there.
    case perform(Command)
    /// Stop queued actions and invalidate outstanding requests.
    case cancelPending
    /// Quit the app. Only ever produced by an addressed "quit Keyless".
    case quit
    /// Begin voice enrollment.
    case learnVoice
}

public struct SessionController: Sendable {
    public private(set) var mode: Mode = .sleeping
    public let grammar: CommandGrammar

    private var reconciler: DictationReconciler?
    private var awaitingTarget = false

    // Current recognizer segment.
    private var segmentText = ""
    private var segmentFirstPartialTime: Double?
    /// The segment started with the address phrase and is withheld from the field.
    private var segmentHeld = false
    /// An early cancel already acted on this segment; ignore its final.
    private var segmentConsumed = false
    /// The voice filter rejected this segment; nothing more from it is shown or acted on.
    private var segmentRejected = false

    /// Phonon caps segments at 30 s. A final this long after the segment's first partial is
    /// treated as forced, which enables boundary de-duplication.
    static let forcedSegmentSeconds = 27.0

    public init(grammar: CommandGrammar = CommandGrammar()) {
        self.grammar = grammar
    }

    public mutating func handle(_ input: SessionInput) -> [SessionEffect] {
        switch input {
        case .asr(.partial(let text), let time, let speaker):
            return handlePartial(text, at: time, speaker: speaker)
        case .asr(.final(let text, _), let time, let speaker):
            defer { resetSegment() }
            return handleFinal(text, at: time, speaker: speaker)
        case .asr(.done, _, _), .asr(.error, _, _):
            // `done` repeats the finals and is never inserted. Errors are handled by the stream owner.
            resetSegment()
            return []
        case .streamRestarted:
            var effects: [SessionEffect] = []
            if mode == .dictating, segmentText.isEmpty == false, !segmentHeld, var r = reconciler {
                if let edit = r.updateProvisional("") { effects.append(.edit(edit)) }
                reconciler = r
            }
            resetSegment()
            return effects + [.overlay(provisional: "", held: false)]
        case .dictationTargetReady(let leading):
            guard awaitingTarget else { return [.releaseDictationTarget] }
            awaitingTarget = false
            reconciler = DictationReconciler(leadingContext: leading)
            return setMode(.dictating) + [.chime(.dictationOn)]
        case .dictationTargetRefused(let reason):
            awaitingTarget = false
            return [.speak(reason)]
        case .dictationInterrupted(let reason):
            guard mode == .dictating else { return [] }
            return endDictation() + [.speak("Dictation paused. \(reason)")]
        }
    }

    // MARK: Segments

    private mutating func handlePartial(_ text: String, at time: Double, speaker: SpeakerVerdict) -> [SessionEffect] {
        if segmentFirstPartialTime == nil { segmentFirstPartialTime = time }
        segmentText = text
        if segmentConsumed || segmentRejected { return [] }
        if speaker == .rejected {
            // Someone else is talking: take back any live text from this segment and ignore the rest.
            segmentRejected = true
            return retractProvisional() + [.overlay(provisional: "", held: false)]
        }

        switch mode {
        case .sleeping:
            return []
        case .control:
            // Commands wait for the final; only an addressed cancel acts early, because it only stops things.
            if speaker == .verified, case .complete(.cancel) = addressedParse(text) {
                segmentConsumed = true
                return [.cancelPending, .chime(.cancelled)]
            }
            return [.overlay(provisional: text, held: false)]
        case .dictating:
            if let addressed = grammar.addressMatch(text, allowPrefix: true) {
                let rest = addressed.matched ? grammar.parse(addressed.rest) : .incomplete
                if speaker == .verified, case .complete(.cancel) = rest {
                    segmentConsumed = true
                    return retractProvisional() + [.cancelPending] + endDictation() + [.chime(.cancelled)]
                }
                if rest != .notCommand {
                    segmentHeld = true
                    return retractProvisional() + [.overlay(provisional: text, held: true)]
                }
            }
            // Not (or no longer) a possible command: it's dictation.
            segmentHeld = false
            return showProvisional(text)
        }
    }

    private mutating func handleFinal(_ text: String, at time: Double, speaker: SpeakerVerdict) -> [SessionEffect] {
        if segmentConsumed { return [] }
        if segmentRejected || speaker == .rejected {
            return retractProvisional() + [.overlay(provisional: "", held: false)]
        }
        let forced = segmentFirstPartialTime.map { time - $0 >= Self.forcedSegmentSeconds } ?? false
        // Commands need a positive match; dictation only needs not to be rejected.
        let mayCommand = speaker == .verified

        switch mode {
        case .sleeping:
            if mayCommand, case .complete(.wake) = addressedParse(text) {
                return setMode(.control) + [.chime(.awake)]
            }
            return []
        case .control:
            guard mayCommand else { return [.overlay(provisional: "", held: false)] }
            var parsed = addressedParse(text)
            if case .complete(.quit) = parsed { return [.cancelPending, .quit] }
            if case .complete = parsed {} else { parsed = grammar.parse(text) }
            // Quitting needs the address phrase even in control mode, so stray speech can't close the app.
            if case .complete(.quit) = parsed { return [] }
            guard case .complete(let command) = parsed else {
                // Unaddressed speech that isn't a command is probably not meant for us: stay quiet.
                // Only answer when the user addressed the assistant. Milestone 3 adds Jev routing here.
                let addressed = grammar.addressMatch(text)?.matched == true
                return [.overlay(provisional: "", held: false)] + (addressed ? [.speak("Sorry, I didn't get that.")] : [])
            }
            return [.overlay(provisional: "", held: false)] + runControl(command)
        case .dictating:
            if let addressed = grammar.addressMatch(text), addressed.matched {
                let parsed = grammar.parse(addressed.rest)
                if parsed != .notCommand, !mayCommand {
                    // An addressed command we can't attribute to the user: neither run it nor type it.
                    return retractProvisional() + [.overlay(provisional: "", held: false)]
                }
                switch parsed {
                case .complete(let command):
                    return retractProvisional() + [.overlay(provisional: "", held: false)] + runDictation(command)
                case .incomplete:
                    // The address phrase alone, or a command cut short: don't type it, ask instead.
                    return retractProvisional() + [.overlay(provisional: "", held: false), .speak("Sorry, I didn't get that.")]
                case .notCommand:
                    break
                }
            }
            // A held segment that never completed a command is ordinary dictation after all.
            guard var r = reconciler else { return [] }
            let edit = r.commitFinal(text, forced: forced)
            reconciler = r
            return (edit.map { [.edit($0)] } ?? []) + [.overlay(provisional: "", held: false)]
        }
    }

    private func addressedParse(_ text: String) -> ParseResult {
        guard let addressed = grammar.addressMatch(text), addressed.matched else { return .notCommand }
        return grammar.parse(addressed.rest)
    }

    // MARK: Commands

    private mutating func runControl(_ command: Command) -> [SessionEffect] {
        switch command {
        case .wake:
            return [.chime(.awake)]
        case .sleep:
            return [.cancelPending] + setMode(.sleeping) + [.chime(.asleep)]
        case .cancel:
            return [.cancelPending, .chime(.cancelled)]
        case .startDictation:
            awaitingTarget = true
            return [.prepareDictationTarget]
        case .learnVoice:
            return [.learnVoice]
        case .stopDictation:
            return [.speak("I'm not dictating.")]
        case _ where command.isDictationEdit:
            return [.speak("Start dictation first.")]
        default:
            return [.perform(command)]
        }
    }

    private mutating func runDictation(_ command: Command) -> [SessionEffect] {
        switch command {
        case .stopDictation:
            return endDictation() + [.chime(.dictationOff)]
        case .sleep:
            return endDictation() + [.cancelPending] + setMode(.sleeping) + [.chime(.asleep)]
        case .cancel:
            return endDictation() + [.cancelPending, .chime(.cancelled)]
        case .quit:
            return endDictation() + [.cancelPending, .quit]
        default:
            break
        }
        guard var r = reconciler else { return [] }
        defer { reconciler = r }
        switch command {
        case .newLine:
            return r.insertNewline().map { [.edit($0)] } ?? []
        case .newParagraph:
            return r.insertNewline(count: 2).map { [.edit($0)] } ?? []
        case .deleteLastWord:
            return r.deleteLastWord().map { [.edit($0)] } ?? [.speak("Nothing to delete.")]
        case .scratchThat:
            return r.scratchLast().map { [.edit($0)] } ?? [.speak("Nothing to scratch.")]
        case .literal(let text):
            return r.insertLiteral(text).map { [.edit($0)] } ?? []
        default:
            return [.speak("Stop dictation first.")]
        }
    }

    // MARK: Helpers

    private mutating func showProvisional(_ text: String) -> [SessionEffect] {
        guard var r = reconciler else { return [] }
        let edit = r.updateProvisional(text)
        reconciler = r
        return (edit.map { [.edit($0)] } ?? []) + [.overlay(provisional: text, held: false)]
    }

    private mutating func retractProvisional() -> [SessionEffect] {
        guard var r = reconciler else { return [] }
        let edit = r.updateProvisional("")
        reconciler = r
        return edit.map { [.edit($0)] } ?? []
    }

    private mutating func endDictation() -> [SessionEffect] {
        guard mode == .dictating else { return [] }
        reconciler = nil
        return [.releaseDictationTarget] + setMode(.control)
    }

    private mutating func setMode(_ new: Mode) -> [SessionEffect] {
        guard new != mode else { return [] }
        if mode == .dictating, new != .dictating { reconciler = nil }
        mode = new
        return [.modeChanged(new)]
    }

    private mutating func resetSegment() {
        segmentText = ""
        segmentFirstPartialTime = nil
        segmentHeld = false
        segmentConsumed = false
        segmentRejected = false
    }
}
