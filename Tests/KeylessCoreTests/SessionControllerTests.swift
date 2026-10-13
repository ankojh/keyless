import Testing
@testable import KeylessCore

@Suite("Session modes and command collisions")
struct SessionControllerTests {
    private func final(_ text: String, _ t: Double = 0) -> SessionInput { .asr(.final(text, segment: 1), audioTime: t) }
    private func partial(_ text: String, _ t: Double = 0) -> SessionInput { .asr(.partial(text), audioTime: t) }

    @Test("Sleeping ignores everything except the addressed wake phrase")
    func sleepingOnlyWakes() throws {
        var replay = Replay()
        for text in ["Open Safari.", "Wake up.", "Computer, open Safari.", "Start dictation."] {
            try replay.feed(final(text))
        }
        #expect(replay.controller.mode == .sleeping)
        #expect(replay.performed.isEmpty)
        try replay.feed(final("Computer, wake up."))
        #expect(replay.controller.mode == .control)
    }

    @Test("Ordinary words that look like commands stay dictation")
    func commandWordsInDictation() throws {
        var replay = try Replay.dictating()
        for text in ["We should delete that later.", "Stop by the store and send it.", "Cancel the meeting."] {
            try replay.feed(partial(text))
            try replay.feed(final(text))
        }
        #expect(replay.field.text == "We should delete that later. Stop by the store and send it. Cancel the meeting.")
        #expect(replay.performed.isEmpty)
        #expect(!replay.effects.contains(.cancelPending))
        #expect(replay.controller.mode == .dictating)
    }

    @Test("A sentence that starts with the address word but isn't a command is typed after the final")
    func addressWordAsDictation() throws {
        var replay = try Replay.dictating()
        try replay.feed(partial("Computer"))
        #expect(replay.field.text.isEmpty, "held while it could still be a command")
        try replay.feed(partial("Computer is slow today."))
        #expect(replay.field.text == "Computer is slow today.", "released once it can't be a command")
        try replay.feed(final("Computer is slow today."))
        #expect(replay.field.text == "Computer is slow today.")
    }

    @Test("The address phrase alone asks for a command instead of typing")
    func addressAlone() throws {
        var replay = try Replay.dictating()
        try replay.feed(partial("Computer."))
        try replay.feed(final("Computer."))
        #expect(replay.field.text.isEmpty)
        #expect(replay.spoken == ["Sorry, I didn't get that."])
    }

    @Test("Literal escape dictates a reserved phrase as plain words")
    func literalEscape() throws {
        var replay = try Replay.dictating()
        try replay.feed(final("Computer, literal computer, new line."))
        #expect(replay.field.text == "computer new line")
    }

    @Test("Addressed cancel acts on the partial, ends dictation, and its final is ignored")
    func earlyCancel() throws {
        var replay = try Replay.dictating()
        try replay.feed(final("Hello there."))
        try replay.feed(partial("Computer, cancel."))
        #expect(replay.effects.contains(.cancelPending))
        #expect(replay.controller.mode == .control)
        let count = replay.effects.count
        try replay.feed(final("Computer, cancel."))
        #expect(replay.effects.count == count)
        #expect(replay.field.text == "Hello there.")
    }

    @Test("Delete last word and scratch that only touch session text")
    func corrections() throws {
        var replay = try Replay.dictating(field: SimulatedField(before: "Existing text. "))
        try replay.feed(final("First sentence here."))
        try replay.feed(final("Second sentence there."))
        try replay.feed(final("Computer, delete last word."))
        #expect(replay.field.text == "Existing text. First sentence here. Second sentence")
        try replay.feed(final("Computer, scratch that."))
        #expect(replay.field.text == "Existing text. First sentence here.")
        try replay.feed(final("Computer, scratch that."))
        try replay.feed(final("Computer, scratch that."))
        #expect(replay.field.text == "Existing text. ")
        #expect(replay.spoken.contains("Nothing to scratch."))
    }

    @Test("Interruption pauses dictation and later speech is not typed")
    func interruptionStopsTyping() throws {
        var replay = try Replay.dictating()
        try replay.feed(final("Keep this."))
        try replay.feed(.dictationInterrupted(reason: "The focused field changed."))
        #expect(replay.controller.mode == .control)
        #expect(replay.effects.contains(.releaseDictationTarget))
        try replay.feed(partial("This must not appear."))
        try replay.feed(final("This must not appear."))
        #expect(replay.field.text == "Keep this.")
    }

    @Test("A stream restart retracts provisional text but keeps finals")
    func streamRestart() throws {
        var replay = try Replay.dictating()
        try replay.feed(final("Kept."))
        try replay.feed(partial("Half a sent"))
        #expect(replay.field.text == "Kept. Half a sent")
        try replay.feed(.streamRestarted)
        #expect(replay.field.text == "Kept.")
    }

    @Test("done frames never insert text")
    func doneIgnored() throws {
        var replay = try Replay.dictating()
        try replay.feed(final("One."))
        try replay.feed(.asr(.done("One."), audioTime: 1))
        #expect(replay.field.text == "One.")
    }

    @Test("Control mode routes commands without the address phrase and refuses edits")
    func controlCommands() throws {
        var replay = Replay()
        try replay.feed(final("Computer, wake up."))
        try replay.feed(final("Open Safari."))
        try replay.feed(final("Click twelve."))
        try replay.feed(final("New line."))
        #expect(replay.performed == [.openApp("Safari"), .click(12)])
        #expect(replay.spoken.contains("Start dictation first."))
    }

    @Test("Unaddressed speech that isn't a command gets no reply; addressed speech does")
    func quietUnlessAddressed() throws {
        var replay = Replay()
        try replay.feed(final("Computer, wake up."))
        try replay.feed(final("I was just talking to someone else."))
        try replay.feed(final("Yeah."))
        #expect(replay.spoken.isEmpty)
        #expect(replay.performed.isEmpty)
        try replay.feed(final("Computer, do a backflip."))
        #expect(replay.spoken == ["Sorry, I didn't get that."])
    }

    @Test("Routine state changes use chimes, not speech")
    func chimes() throws {
        var replay = Replay()
        try replay.feed(final("Computer, wake up."))
        try replay.feed(final("Start dictation."))
        try replay.feed(.dictationTargetReady(leadingContext: nil))
        try replay.feed(final("Computer, stop dictation."))
        try replay.feed(final("Go to sleep."))
        let chimes = replay.effects.compactMap { if case .chime(let c) = $0 { c } else { nil } }
        #expect(chimes == [.awake, .dictationOn, .dictationOff, .asleep])
        #expect(replay.spoken.isEmpty)
    }

    @Test("Quit requires the address phrase, in control and in dictation")
    func quitIsAddressed() throws {
        var replay = Replay()
        try replay.feed(final("Computer, wake up."))
        try replay.feed(final("Quit Keyless."))
        #expect(!replay.effects.contains(.quit))
        try replay.feed(final("Computer, quit Keyless."))
        #expect(replay.effects.contains(.quit))

        var dictating = try Replay.dictating()
        try dictating.feed(final("Remember to quit keyless tonight."))
        #expect(!dictating.effects.contains(.quit))
        try dictating.feed(final("Computer, quit Keyless."))
        #expect(dictating.effects.contains(.quit))
    }

    @Test("A refused target keeps control mode")
    func refusedTarget() throws {
        var replay = Replay()
        try replay.feed(final("Computer, wake up."))
        try replay.feed(final("Start dictation."))
        try replay.feed(.dictationTargetRefused(reason: "That's a password field."))
        #expect(replay.controller.mode == .control)
        #expect(replay.spoken.contains("That's a password field."))
    }
}
