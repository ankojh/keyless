import Foundation

public enum ScrollDirection: String, Equatable, Sendable { case up, down }

/// Commands the local grammar recognizes. Free-form arguments are literal spans of the transcript.
public enum Command: Equatable, Sendable {
    case wake, sleep, cancel, quit
    /// Record the user's voice so only they can command the assistant.
    case learnVoice
    case startDictation, stopDictation
    case newLine, newParagraph, deleteLastWord, scratchThat
    case literal(String)
    case openApp(String)
    /// New tab in the named app, or the frontmost app when nil.
    case newTab(app: String?)
    case closeTab, closeWindow
    /// A polite quit; the app can still ask to save unsaved work.
    case quitApp(String)
    case focus(String)
    case scroll(ScrollDirection)
    case showNumbers, hideNumbers
    case click(Int)
    case confirm(String)

    /// Commands that only make sense while dictating, because they edit the session's text.
    public var isDictationEdit: Bool {
        switch self {
        case .newLine, .newParagraph, .deleteLastWord, .scratchThat, .literal: true
        default: false
        }
    }
}

public enum ParseResult: Equatable, Sendable {
    /// The words cannot become a command.
    case notCommand
    /// The words so far are the start of at least one command; wait for more.
    case incomplete
    case complete(Command)
}

/// A whitespace token with its original spelling and a normalized form for matching.
struct Token: Equatable {
    let original: String
    let normalized: String
}

public struct CommandGrammar: Sendable {
    public let addressPhrase: [String]

    public init(addressPhrase: String = "computer") {
        self.addressPhrase = Self.tokenize(addressPhrase).map(\.normalized)
    }

    /// Whether the utterance starts with the address phrase (or a prefix of it, if `allowPrefix`).
    public func addressMatch(_ text: String, allowPrefix: Bool = false) -> (matched: Bool, rest: String)? {
        let tokens = Self.tokenize(text)
        if tokens.count >= addressPhrase.count,
           Array(tokens.prefix(addressPhrase.count).map(\.normalized)) == addressPhrase {
            return (true, tokens.dropFirst(addressPhrase.count).map(\.original).joined(separator: " "))
        }
        if allowPrefix, tokens.count < addressPhrase.count, !tokens.isEmpty,
           Array(addressPhrase.prefix(tokens.count)) == tokens.map(\.normalized) {
            return (false, "")
        }
        return nil
    }

    /// Parses an utterance with the address phrase already removed.
    public func parse(_ text: String) -> ParseResult {
        let tokens = Self.tokenize(text)
        if tokens.isEmpty { return .incomplete }
        var anyIncomplete = false
        for rule in Self.rules {
            switch rule.match(tokens) {
            case .complete(let command): return .complete(command)
            case .incomplete: anyIncomplete = true
            case .notCommand: break
            }
        }
        return anyIncomplete ? .incomplete : .notCommand
    }

    static func tokenize(_ text: String) -> [Token] {
        text.replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { raw in
                let original = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"“”"))
                let normalized = DictationReconciler.normalize(Substring(original))
                return normalized.isEmpty ? nil : Token(original: original, normalized: normalized)
            }
    }

    // MARK: Rules

    enum Element: Sendable {
        case word(Set<String>)
        /// One or more trailing words, captured with their original spelling.
        case text
        /// One trailing number, spelled as digits or words.
        case number
    }

    struct Rule: Sendable {
        let elements: [Element]
        let build: @Sendable (String) -> Command?

        init(_ elements: [Element], _ build: @escaping @Sendable (String) -> Command?) {
            self.elements = elements
            self.build = build
        }

        init(_ words: String, _ command: Command) {
            self.elements = words.split(separator: " ").map { .word(Set($0.split(separator: "|").map(String.init))) }
            self.build = { _ in command }
        }

        func match(_ tokens: [Token]) -> ParseResult {
            var i = 0
            for element in elements {
                switch element {
                case .word(let options):
                    if i == tokens.count { return .incomplete }
                    guard options.contains(tokens[i].normalized) else { return .notCommand }
                    i += 1
                case .text:
                    if i == tokens.count { return .incomplete }
                    let captured = tokens[i...].map(\.original).joined(separator: " ")
                    return build(captured).map(ParseResult.complete) ?? .notCommand
                case .number:
                    if i == tokens.count { return .incomplete }
                    guard let n = CommandGrammar.number(tokens[i...].map(\.normalized)) else {
                        return CommandGrammar.isNumberPrefix(tokens[i...].map(\.normalized)) ? .incomplete : .notCommand
                    }
                    return build(String(n)).map(ParseResult.complete) ?? .notCommand
                }
            }
            return i == tokens.count ? (build("").map(ParseResult.complete) ?? .notCommand) : .notCommand
        }
    }

    static let rules: [Rule] = [
        Rule("wake up", .wake),
        Rule("go to sleep", .sleep),
        Rule("sleep", .sleep),
        Rule("quit keyless", .quit),
        Rule("learn my voice", .learnVoice),
        Rule("cancel", .cancel),
        Rule("cancel that", .cancel),
        Rule("never mind", .cancel),
        Rule("start dictation|dictating", .startDictation),
        Rule("dictate", .startDictation),
        Rule("stop dictation|dictating", .stopDictation),
        Rule("new line", .newLine),
        Rule("new paragraph", .newParagraph),
        Rule("delete last word", .deleteLastWord),
        Rule("scratch that", .scratchThat),
        Rule("show numbers", .showNumbers),
        Rule("hide numbers", .hideNumbers),
        Rule("scroll up", .scroll(.up)),
        Rule("scroll down", .scroll(.down)),
        Rule([.word(["literal"]), .text]) { .literal($0) },
        Rule("new tab", .newTab(app: nil)),
        Rule([.word(["new"]), .word(["tab"]), .word(["in"]), .text]) { .newTab(app: $0) },
        Rule([.word(["open", "launch"]), .text]) { Self.openTarget($0) },
        Rule([.word(["close"]), .text]) { Self.closeTarget($0) },
        Rule([.word(["quit"]), .text]) { .quitApp(Self.dropLeading(["the"], from: $0)) },
        Rule([.word(["switch"]), .word(["to"]), .text]) { .openApp($0) },
        Rule([.word(["focus"]), .text]) { .focus(Self.dropLeading(["on", "the"], from: $0)) },
        Rule([.word(["click", "press"]), .number]) { Int($0).map(Command.click) },
        Rule([.word(["confirm"]), .text]) { .confirm($0.lowercased()) },
    ]

    /// "open a new tab in Safari" is a tab, not an app called "a new tab in Safari".
    private static func openTarget(_ text: String) -> Command {
        var words = text.split(separator: " ").map(String.init)
        if let first = words.first?.lowercased(), ["a", "the"].contains(first) { words.removeFirst() }
        if words.first?.lowercased() == "new" { words.removeFirst() }
        guard words.first?.lowercased() == "tab" else { return .openApp(text) }
        words.removeFirst()
        if words.first?.lowercased() == "in" { words.removeFirst() }
        return .newTab(app: words.isEmpty ? nil : words.joined(separator: " "))
    }

    private static func closeTarget(_ text: String) -> Command {
        let rest = dropLeading(["the", "this"], from: text)
        switch rest.lowercased() {
        case "tab": return .closeTab
        case "window": return .closeWindow
        default: return .quitApp(rest)
        }
    }

    private static func dropLeading(_ fillers: Set<String>, from text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while let first = words.first, fillers.contains(first.lowercased()), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    // MARK: Numbers

    private static let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
                                "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
                                "nineteen": 19, "to": 2, "too": 2, "for": 4, "won": 1]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                               "eighty": 80, "ninety": 90]

    /// Parses 1–99 written as digits ("12") or words ("twelve", "twenty one").
    static func number(_ words: [String]) -> Int? {
        if words.count == 1, let n = Int(words[0]), (0 ... 999).contains(n) { return n }
        if words.count == 1 { return units[words[0]] ?? tens[words[0]] }
        if words.count == 2, let t = tens[words[0]], let u = units[words[1]], (1 ... 9).contains(u) { return t + u }
        return nil
    }

    static func isNumberPrefix(_ words: [String]) -> Bool {
        words.count == 1 && tens[words[0]] != nil
    }
}
