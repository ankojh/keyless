import Testing
@testable import KeylessCore

@Suite("Command grammar")
struct CommandGrammarTests {
    let grammar = CommandGrammar()

    @Test(arguments: [
        ("wake up", Command.wake), ("Go to sleep.", .sleep), ("never mind", .cancel),
        ("start dictating", .startDictation), ("Stop dictation.", .stopDictation),
        ("new line", .newLine), ("New paragraph.", .newParagraph), ("delete last word", .deleteLastWord),
        ("scratch that", .scratchThat), ("open Safari", .openApp("Safari")), ("switch to Visual Studio Code", .openApp("Visual Studio Code")),
        ("focus on the search field", .focus("search field")), ("scroll down", .scroll(.down)),
        ("click 12", .click(12)), ("click twenty one", .click(21)), ("press seven", .click(7)),
        ("confirm send", .confirm("send")), ("show numbers", .showNumbers),
        ("quit Keyless", .quit), ("learn my voice", .learnVoice),
        ("open a tab in Safari", .newTab(app: "Safari")), ("Open a new tab.", .newTab(app: nil)),
        ("new tab", .newTab(app: nil)), ("new tab in Google Chrome", .newTab(app: "Google Chrome")),
        ("open the new tab in Safari", .newTab(app: "Safari")), ("open Safari", .openApp("Safari")),
        ("close Slack", .quitApp("Slack")), ("Quit Slack.", .quitApp("Slack")), ("close the tab", .closeTab),
        ("close this window", .closeWindow), ("close Visual Studio Code", .quitApp("Visual Studio Code")),
    ])
    func parses(_ text: String, _ expected: Command) {
        #expect(grammar.parse(text) == .complete(expected))
    }

    @Test(arguments: ["open", "go to", "start", "click", "delete last", "click twenty"])
    func incompletePrefixes(_ text: String) {
        let result = grammar.parse(text)
        #expect(result == .incomplete || { if case .complete = result { true } else { false } }())
    }

    @Test(arguments: ["the weather is nice", "delete everything", "click the button", "send it"])
    func notCommands(_ text: String) {
        #expect(grammar.parse(text) == .notCommand)
    }

    @Test func addressMatching() {
        #expect(grammar.addressMatch("Computer, new line.")?.matched == true)
        #expect(grammar.addressMatch("Computer, new line.")?.rest == "new line")
        #expect(grammar.addressMatch("Computers are fast") == nil)
        #expect(grammar.addressMatch("My computer") == nil)
        let custom = CommandGrammar(addressPhrase: "hey keyless")
        #expect(custom.addressMatch("Hey", allowPrefix: true)?.matched == false)
        #expect(custom.addressMatch("Hey Keyless, open Mail.")?.rest == "open Mail")
    }
}

@Suite("Text edits")
struct TextEditTests {
    @Test(arguments: [
        ("", "Hello"), ("Hello", ""), ("Open safari and", "Open Safari and focus"),
        ("Computer.", "Computer"), ("a 👍🏽 b", "a 👍🏾 b"), ("same", "same"), ("in view.", "invite everyone."),
    ])
    func diffRoundTrips(_ old: String, _ new: String) throws {
        guard let edit = TextEdit.diff(from: old, to: new) else {
            #expect(old == new)
            return
        }
        #expect(edit.apply(to: old) == new)
    }

    @Test func minimalEdit() {
        let edit = TextEdit.diff(from: "Open safari and", to: "Open Safari and focus")!
        #expect(edit.location == 5)
        #expect(edit.expected == "safari and")
        #expect(edit.replacement == "Safari and focus")
    }

    @Test func refusesWhenFieldChanged() {
        let edit = TextEdit(location: 0, length: 5, expected: "Hello", replacement: "Howdy")
        #expect(edit.apply(to: "Help!") == nil)
    }

    @Test func emojiOffsetsAreUTF16() {
        let edit = TextEdit.diff(from: "👋 hi", to: "👋 hey")!
        #expect(edit.location == 4) // 👋 is two UTF-16 units, then a space, then "h".
    }
}
