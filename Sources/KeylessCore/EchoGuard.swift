import Foundation

/// Drops recognizer text that is the assistant's own spoken feedback picked up by the microphone.
///
/// The recognizer doesn't hear feedback verbatim: "Opened Safari" came back as "Open Safari" and
/// was executed again, in a loop. So matching is fuzzy, and outside dictation any segment that began
/// while feedback was playing is dropped outright. Addressed speech always passes, so cancellation
/// keeps working while feedback plays.
public struct EchoGuard: Sendable {
    private struct Utterance: Sendable {
        let words: [String]
        let start: Double
        var end: Double?
    }

    private var recent: [Utterance] = []
    private let grammar: CommandGrammar
    /// Whether the current recognizer segment began while feedback was audible; nil between segments.
    private var segmentOverlapsFeedback: Bool?

    /// How long after feedback ends its echo can still arrive (Phonon finalizes ~0.7 s after speech).
    public var tail: Double = 2.5
    /// Phonon's first partial arrives ~0.4 s after speech onset.
    static let onsetLag = 0.4
    static let audibleTail = 0.5

    public init(grammar: CommandGrammar = CommandGrammar()) {
        self.grammar = grammar
    }

    public mutating func didStartSpeaking(_ phrase: String, at time: Double) {
        recent.removeAll { u in u.end.map { time - $0 > tail } ?? false }
        recent.append(Utterance(words: Self.words(phrase), start: time))
    }

    public mutating func didFinishSpeaking(at time: Double) {
        if let i = recent.lastIndex(where: { $0.end == nil }) { recent[i].end = time }
    }

    /// Forget the in-flight segment, e.g. after a stream restart.
    public mutating func resetSegment() {
        segmentOverlapsFeedback = nil
    }

    /// Decides whether to drop a frame. `strict` (outside dictation) also drops any unaddressed
    /// segment that started while feedback was audible.
    public mutating func shouldDrop(_ text: String, isFinal: Bool, at time: Double, strict: Bool) -> Bool {
        if segmentOverlapsFeedback == nil { segmentOverlapsFeedback = feedbackAudible(at: time - Self.onsetLag) }
        let overlaps = segmentOverlapsFeedback ?? false
        if isFinal { segmentOverlapsFeedback = nil }
        if grammar.addressMatch(text)?.matched == true { return false }
        if strict && overlaps { return true }
        return isEcho(text, at: time)
    }

    public func isEcho(_ text: String, at time: Double) -> Bool {
        let heard = Self.words(text)
        guard !heard.isEmpty else { return false }
        if grammar.addressMatch(text)?.matched == true { return false }
        let active = recent.filter { u in time >= u.start && (u.end.map { time - $0 <= tail } ?? true) }
        // Several feedback phrases can run together into one segment.
        let spoken = active.flatMap(\.words)
        guard !spoken.isEmpty else { return false }
        let matched = Self.orderedMatches(heard, spoken)
        // Allow one misheard word in four; a single heard word must match.
        return Double(matched) >= (heard.count == 1 ? 1 : 0.75 * Double(heard.count))
    }

    private func feedbackAudible(at time: Double) -> Bool {
        recent.contains { u in time >= u.start - 0.1 && (u.end.map { time <= $0 + Self.audibleTail } ?? true) }
    }

    /// Greedy in-order count of heard words that resemble spoken words.
    private static func orderedMatches(_ heard: [String], _ spoken: [String]) -> Int {
        var j = 0, count = 0
        for word in heard {
            if let k = spoken[j...].firstIndex(where: { similar(word, $0) }) {
                count += 1
                j = k + 1
            }
            if j >= spoken.count { break }
        }
        return count
    }

    /// Equal, an inflection of the same stem ("open"/"opened"), or one edit apart for longer words.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 3, long.hasPrefix(short), long.count - short.count <= 3 { return true }
        return short.count >= 4 && editDistance(a, b) <= 1
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0 ... b.count)
        for i in 1 ... max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1 ... max(b.count, 1) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    static func words(_ text: String) -> [String] {
        CommandGrammar.tokenize(text).map(\.normalized)
    }
}
