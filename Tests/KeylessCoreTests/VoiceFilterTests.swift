import Foundation
import Testing
@testable import KeylessCore

@Suite("Voice filter: commands only from the enrolled voice, dictation stays live")
struct VoiceFilterTests {
    private func final(_ text: String, _ speaker: SpeakerVerdict) -> SessionInput {
        .asr(.final(text, segment: 1), audioTime: 0, speaker: speaker)
    }
    private func partial(_ text: String, _ speaker: SpeakerVerdict) -> SessionInput {
        .asr(.partial(text), audioTime: 0, speaker: speaker)
    }

    @Test("Another voice can't wake, command, or quit")
    func otherVoicesCantCommand() throws {
        var replay = Replay()
        try replay.feed(final("Computer, wake up.", .rejected))
        #expect(replay.controller.mode == .sleeping)
        try replay.feed(final("Computer, wake up.", .verified))
        #expect(replay.controller.mode == .control)
        for speaker in [SpeakerVerdict.rejected, .unknown] {
            try replay.feed(final("Open Safari.", speaker))
            try replay.feed(final("Computer, quit Keyless.", speaker))
            try replay.feed(final("Computer, do a backflip.", speaker))
            try replay.feed(partial("Computer, cancel.", speaker))
        }
        #expect(replay.performed.isEmpty)
        #expect(!replay.effects.contains(.quit))
        #expect(!replay.effects.contains(.cancelPending))
        #expect(replay.spoken.isEmpty, "no replies to other voices")
    }

    @Test("Dictation shows text live, then removes a segment rejected as another voice")
    func rejectedDictationIsRemoved() throws {
        var replay = try Replay.dictating()
        try replay.feed(final("My sentence.", .verified))
        try replay.feed(partial("And now the", .unknown))
        #expect(replay.field.text == "My sentence. And now the", "live while undecided")
        try replay.feed(partial("And now the weather", .rejected))
        #expect(replay.field.text == "My sentence.")
        try replay.feed(partial("And now the weather for", .verified))
        #expect(replay.field.text == "My sentence.", "a rejected segment stays rejected")
        try replay.feed(final("And now the weather for Tuesday.", .verified))
        #expect(replay.field.text == "My sentence.")
        // The next segment starts fresh.
        try replay.feed(final("Back to me.", .unknown))
        #expect(replay.field.text == "My sentence. Back to me.")
    }

    @Test("While dictating, an addressed command from another voice is neither run nor typed")
    func otherVoiceCommandDuringDictation() throws {
        var replay = try Replay.dictating()
        try replay.feed(final("Hello.", .verified))
        try replay.feed(final("Computer, stop dictation.", .unknown))
        try replay.feed(final("Computer, new line.", .rejected))
        #expect(replay.controller.mode == .dictating)
        #expect(replay.field.text == "Hello.")
        try replay.feed(final("Computer, stop dictation.", .verified))
        #expect(replay.controller.mode == .control)
    }
}

@Suite("Voiceprint")
struct VoiceprintTests {
    /// Unit vectors near `base`, with small deterministic perturbations.
    private func cluster(_ base: [Float], count: Int, spread: Float) -> [[Float]] {
        (0 ..< count).map { i in base.enumerated().map { j, x in x + spread * sin(Float(i * 7 + j * 3)) } }
    }

    @Test func buildsAndVerifies() throws {
        let me: [Float] = [1, 0, 0, 0.2]
        let other: [Float] = [0, 1, 0.3, 0]
        let print = try Voiceprint.build(model: "test", embeddings: cluster(me, count: 8, spread: 0.1), now: Date(timeIntervalSince1970: 0))
        #expect(print.enrollmentScores.count == 8)
        #expect(print.verdict(for: [0.95, 0.05, 0, 0.2]) == .verified)
        #expect(print.verdict(for: other) == .rejected)
        #expect(print.verdict(for: [1, 0]) == .unknown, "wrong dimension")
    }

    @Test func refusesTooLittleSpeech() {
        #expect(throws: Voiceprint.BuildError.notEnoughSpeech(windows: 3)) {
            try Voiceprint.build(model: "test", embeddings: [[1, 0], [1, 0.1], [0.9, 0]])
        }
    }

    @Test("Refuses enrollment that mixes very different voices")
    func refusesInconsistentEnrollment() {
        let mixed: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [-1, 0, 0], [0, -1, 0], [0, 0, -1]]
        #expect(throws: Voiceprint.BuildError.self) { try Voiceprint.build(model: "test", embeddings: mixed) }
    }

    @Test func roundTripsThroughJSON() throws {
        let print = try Voiceprint.build(model: "m", embeddings: cluster([1, 0, 0.5], count: 6, spread: 0.05), now: Date(timeIntervalSince1970: 1))
        let decoded = try JSONDecoder().decode(Voiceprint.self, from: JSONEncoder().encode(print))
        #expect(decoded == print)
    }
}
