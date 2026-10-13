import Foundation
@testable import KeylessCore

/// Loads recorded protocol fixtures from spike/fixtures/protocol.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spike/fixtures/protocol")

    struct TimedFrame {
        let time: Double
        let frame: ASRFrame
    }

    /// Server frames in arrival order, with times relative to the stream's connection.
    static func frames(_ name: String) throws -> [TimedFrame] {
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return try text.split(separator: "\n").compactMap { line in
            let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard let frame = record["frame"] else { return nil }
            let json = String(data: try JSONSerialization.data(withJSONObject: frame), encoding: .utf8)!
            return TimedFrame(time: record["t"] as! Double, frame: try ASRFrameDecoder.decode(json))
        }
    }
}

/// A text field that applies `TextEdit`s at an anchor and verifies the expected text first,
/// like the Accessibility adapter does.
struct SimulatedField {
    private(set) var text: String
    let anchor: Int
    /// Text before the caret when dictation started.
    let before: String
    private(set) var editCount = 0
    /// Every intermediate value, to check that text appears while speech is still in progress.
    private(set) var history: [String] = []

    init(before: String = "", after: String = "") {
        text = before + after
        anchor = before.utf16.count
        self.before = before
    }

    mutating func apply(_ edit: TextEdit) throws {
        let shifted = TextEdit(location: anchor + edit.location, length: edit.length, expected: edit.expected, replacement: edit.replacement)
        guard let updated = shifted.apply(to: text) else {
            throw FieldError.mismatch(edit: edit, field: text)
        }
        text = updated
        editCount += 1
        history.append(text)
    }

    enum FieldError: Error { case mismatch(edit: TextEdit, field: String) }
}

/// Drives a `SessionController` with frames and applies its effects to a simulated field.
struct Replay {
    var controller = SessionController()
    var field: SimulatedField
    private(set) var effects: [SessionEffect] = []

    init(field: SimulatedField = SimulatedField()) {
        self.field = field
    }

    /// Starts in control mode with a dictation session on `field`.
    static func dictating(field: SimulatedField = SimulatedField()) throws -> Replay {
        var replay = Replay(field: field)
        try replay.feed(.asr(.final("Computer, wake up.", segment: 1), audioTime: 0))
        try replay.feed(.asr(.final("Start dictation.", segment: 2), audioTime: 0))
        try replay.feed(.dictationTargetReady(leadingContext: field.before.last))
        replay.effects.removeAll()
        return replay
    }

    mutating func feed(_ input: SessionInput) throws {
        for effect in controller.handle(input) {
            effects.append(effect)
            if case .edit(let edit) = effect { try field.apply(edit) }
        }
    }

    mutating func play(_ frames: [Fixtures.TimedFrame]) throws {
        for f in frames { try feed(.asr(f.frame, audioTime: f.time)) }
    }

    var spoken: [String] { effects.compactMap { if case .speak(let s) = $0 { s } else { nil } } }
    var performed: [Command] { effects.compactMap { if case .perform(let c) = $0 { c } else { nil } } }
}
