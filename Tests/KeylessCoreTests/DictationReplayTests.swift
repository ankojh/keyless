import Testing
@testable import KeylessCore

@Suite("Dictation replay against recorded Phonon-2 frames")
struct DictationReplayTests {
    private func finals(_ frames: [Fixtures.TimedFrame]) -> [String] {
        frames.compactMap { if case .final(let t, _) = $0.frame { t } else { nil } }
    }

    @Test("Every recorded frame decodes")
    func decodesFixtures() throws {
        for name in ["short.f32.jsonl", "short.s16.jsonl", "continuous15.f32.jsonl", "long35.f32.jsonl", "pause.f32.jsonl"] {
            #expect(try !Fixtures.frames(name).isEmpty, "\(name)")
        }
    }

    @Test("Continuous speech updates the field repeatedly before it ends, then matches the final")
    func continuousUpdatesLive() throws {
        let frames = try Fixtures.frames("continuous15.f32.jsonl")
        var replay = try Replay.dictating(field: SimulatedField(before: "Notes: ", after: " [end]"))
        try replay.play(frames)

        let final = try #require(finals(frames).first)
        #expect(replay.field.text == "Notes: " + final + " [end]")
        // Acceptance test 2: text changes many times while speech is still in progress.
        let firstFinalIndex = frames.firstIndex { if case .final = $0.frame { true } else { false } }!
        let partialsBeforeFinal = frames[..<firstFinalIndex].count
        #expect(replay.field.editCount >= partialsBeforeFinal - 2)
        #expect(replay.field.history.first!.hasPrefix("Notes: We should"))
    }

    @Test("A revised early word leaves no duplicate and preserves surrounding text")
    func revisionsReplaceInPlace() throws {
        let frames = try Fixtures.frames("continuous15.f32.jsonl")
        var replay = try Replay.dictating(field: SimulatedField(before: "A", after: "Z"))
        try replay.play(frames)
        // "in view" and "the game" were provisional; neither survives.
        #expect(!replay.field.text.contains("in view"))
        #expect(!replay.field.text.contains("plan the game"))
        #expect(replay.field.text.hasPrefix("A We should plan"))
        #expect(replay.field.text.hasSuffix("close.Z"))
        #expect(replay.field.text.components(separatedBy: "quarterly").count == 2)
    }

    @Test("Crossing the 30 s segment cap drops the repeated boundary word")
    func forcedBoundaryDeduplicates() throws {
        let frames = try Fixtures.frames("long35.f32.jsonl")
        var replay = try Replay.dictating()
        try replay.play(frames)

        let f = finals(frames)
        try #require(f.count == 2)
        #expect(f[0].hasSuffix("month and after."), "fixture premise: Phonon repeats the word")
        #expect(f[1].hasPrefix("After that"))
        let expected = f[0].split(separator: " ").dropLast().joined(separator: " ") + " after" + f[1].dropFirst("After".count)
        #expect(replay.field.text == expected)
        #expect(!replay.field.text.contains("after. After"))
        // No intermediate state showed the duplicate either.
        #expect(!replay.field.history.contains { $0.contains("after. After") })
    }

    @Test("Commands in the pause fixture are consumed and never typed")
    func addressedCommandsAreConsumed() throws {
        let frames = try Fixtures.frames("pause.f32.jsonl")
        var replay = Replay()
        try replay.feed(.asr(.final("Computer, wake up.", segment: 1), audioTime: 0))
        // Segment 1 "Computer, start dictation." asks the app for a target.
        try replay.play(Array(frames.prefix { if case .final = $0.frame { false } else { true } }))
        try replay.feed(.asr(frames.first { if case .final = $0.frame { true } else { false } }!.frame, audioTime: 2.5))
        #expect(replay.effects.contains(.prepareDictationTarget))
        try replay.feed(.dictationTargetReady(leadingContext: nil))
        #expect(replay.controller.mode == .dictating)

        let rest = frames.drop { f in
            if case .final(_, let seg) = f.frame { return seg != 1 } else { return true }
        }.dropFirst()
        try replay.play(Array(rest))
        #expect(replay.field.text == "Dear Sam, thanks for the update.\n")
        #expect(!replay.field.history.contains { $0.contains("Computer") })
        // The "Yeah." onset partial was shown briefly but did not survive.
        #expect(!replay.field.text.contains("Yeah"))
    }
}
