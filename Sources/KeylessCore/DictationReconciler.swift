import Foundation

/// Turns Phonon segment hypotheses into edits of the text one dictation session owns.
///
/// The owned text is rendered from finalized pieces plus the current provisional segment. Every
/// update re-renders and emits one minimal `TextEdit`, so a revised early word replaces only the
/// characters that changed and nothing outside the owned range is touched.
public struct DictationReconciler: Sendable {
    struct Piece: Sendable {
        enum Kind: Sendable { case speech, literal, newline }
        let kind: Kind
        /// Text as the recognizer or command produced it.
        let original: String
        /// Words dropped from the end because the next segment repeated them across a forced boundary.
        var trimmedTailWords = 0
        /// True when the recognizer closed this segment at its length cap rather than at a pause.
        let forcedEnd: Bool
    }

    private var pieces: [Piece] = []
    private var provisional = ""
    /// Character immediately before the insertion point when the session began, if any.
    private let leadingContext: Character?

    public init(leadingContext: Character? = nil) {
        self.leadingContext = leadingContext
    }

    public var ownedText: String { render() }
    public var hasCommittedText: Bool { !pieces.isEmpty }

    // MARK: Recognizer input

    /// Shows the latest whole-segment hypothesis. An empty string retracts provisional text.
    public mutating func updateProvisional(_ text: String) -> TextEdit? {
        mutate { $0.provisional = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Commits a segment. `forced` means the recognizer hit its segment cap mid-speech.
    public mutating func commitFinal(_ text: String, forced: Bool) -> TextEdit? {
        mutate { state in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            state.provisional = ""
            guard !trimmed.isEmpty else { return }
            let overlap = state.boundaryOverlap(with: trimmed)
            if overlap > 0 { state.pieces[state.pieces.count - 1].trimmedTailWords = overlap }
            state.pieces.append(Piece(kind: .speech, original: trimmed, forcedEnd: forced))
        }
    }

    // MARK: Editing commands

    public mutating func insertNewline(count: Int = 1) -> TextEdit? {
        mutate { state in
            state.provisional = ""
            state.pieces.append(Piece(kind: .newline, original: String(repeating: "\n", count: count), forcedEnd: false))
        }
    }

    public mutating func insertLiteral(_ text: String) -> TextEdit? {
        mutate { state in
            state.provisional = ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            state.pieces.append(Piece(kind: .literal, original: trimmed, forcedEnd: false))
        }
    }

    /// Removes the last word this session inserted. Returns nil and changes nothing if there is none.
    public mutating func deleteLastWord() -> TextEdit? {
        mutate { state in
            state.provisional = ""
            while let last = state.pieces.last {
                if last.kind == .newline {
                    state.pieces.removeLast()
                    return
                }
                var words = state.visibleText(of: last).split(separator: " ", omittingEmptySubsequences: true)
                if words.isEmpty {
                    state.pieces.removeLast()
                    continue
                }
                words.removeLast()
                state.pieces.removeLast()
                if !words.isEmpty {
                    state.pieces.append(Piece(kind: last.kind, original: words.joined(separator: " "), forcedEnd: false))
                }
                return
            }
        }
    }

    /// Removes the last segment, newline or literal this session inserted.
    public mutating func scratchLast() -> TextEdit? {
        mutate { state in
            state.provisional = ""
            if !state.pieces.isEmpty { state.pieces.removeLast() }
        }
    }

    // MARK: Rendering

    private mutating func mutate(_ change: (inout DictationReconciler) -> Void) -> TextEdit? {
        let before = render()
        change(&self)
        return TextEdit.diff(from: before, to: render())
    }

    private func render() -> String {
        var out = ""
        var previous: Character? = leadingContext
        var previousPiece: Piece?
        for piece in pieces {
            var text = visibleText(of: piece)
            if let prior = previousPiece, prior.trimmedTailWords > 0 { text = Self.continueSentence(text, after: prior) }
            out += Self.separator(after: previous, before: text) + text
            previous = out.last ?? previous
            previousPiece = piece
        }
        if !provisional.isEmpty {
            var text = provisional
            if let prior = pieces.last, prior.forcedEnd, prior.kind == .speech {
                // Preview the de-duplication the final will apply, so the field doesn't flash a repeat.
                let overlap = boundaryOverlap(with: text)
                if overlap > 0 {
                    var trimmedPrior = prior
                    trimmedPrior.trimmedTailWords = overlap
                    out = Self.renderReplacingLast(in: self, with: trimmedPrior)
                    previous = out.last ?? leadingContext
                    text = Self.continueSentence(text, after: trimmedPrior)
                }
            }
            out += Self.separator(after: previous, before: text) + text
        }
        return out
    }

    private static func renderReplacingLast(in reconciler: DictationReconciler, with piece: Piece) -> String {
        var copy = reconciler
        copy.pieces[copy.pieces.count - 1] = piece
        copy.provisional = ""
        return copy.render()
    }

    private func visibleText(of piece: Piece) -> String {
        guard piece.trimmedTailWords > 0 else { return piece.original }
        let words = piece.original.split(separator: " ", omittingEmptySubsequences: true)
        return words.dropLast(piece.trimmedTailWords).joined(separator: " ")
    }

    // MARK: Segment-boundary de-duplication

    /// At a forced segment boundary Phonon can end one segment with the first word(s) of the next
    /// ("…month and after." / "After that we…"). Returns how many tail words of the last piece the
    /// new segment repeats, up to three, always leaving at least one word.
    private func boundaryOverlap(with next: String) -> Int {
        guard let last = pieces.last, last.kind == .speech, last.forcedEnd else { return 0 }
        let tail = last.original.split(separator: " ").map(Self.normalize)
        let head = next.split(separator: " ").map(Self.normalize)
        for k in stride(from: min(3, tail.count - 1, head.count), through: 1, by: -1) {
            if Array(tail.suffix(k)) == Array(head.prefix(k)), !tail.suffix(k).contains("") { return k }
        }
        return 0
    }

    /// After trimming a repeated tail, the next segment continues the same sentence; drop the
    /// capital the recognizer gave its first word unless the trimmed word itself was capitalized.
    private static func continueSentence(_ text: String, after prior: Piece) -> String {
        let words = prior.original.split(separator: " ")
        let firstTrimmed = words[words.count - prior.trimmedTailWords]
        guard let first = text.first, first.isUppercase,
              let trimmedFirst = firstTrimmed.first, trimmedFirst.isLowercase,
              !text.hasPrefix("I ") && !text.hasPrefix("I'")
        else { return text }
        return first.lowercased() + text.dropFirst()
    }

    static func normalize(_ word: Substring) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
    }

    static func separator(after previous: Character?, before text: String) -> String {
        guard let previous, let first = text.first else { return "" }
        if previous.isWhitespace || previous.isNewline { return "" }
        if first.isNewline || ",.;:!?)".contains(first) { return "" }
        return " "
    }
}
