import Testing
@testable import KeylessCore

@Suite("Feedback echo guard")
struct EchoGuardTests {
    @Test func dropsOwnFeedbackWhileSpeakingAndShortlyAfter() {
        var guardrail = EchoGuard()
        guardrail.didStartSpeaking("Dictation paused. The cursor moved.", at: 10)
        #expect(guardrail.isEcho("Dictation paused.", at: 10.8))
        guardrail.didFinishSpeaking(at: 11.5)
        #expect(guardrail.isEcho("Dictation paused. The cursor moved.", at: 12.5))
        #expect(!guardrail.isEcho("Dictation paused.", at: 15.0), "too late to be echo")
    }

    @Test("Misheard feedback still counts as echo (observed loops)")
    func fuzzyEcho() {
        var guardrail = EchoGuard()
        guardrail.didStartSpeaking("Opened Safari.", at: 0)
        guardrail.didFinishSpeaking(at: 0.8)
        #expect(guardrail.isEcho("Open Safari.", at: 1.5))
        guardrail.didStartSpeaking("Sorry, I didn't get that.", at: 5)
        #expect(guardrail.isEcho("Sorry, I didn't get it.", at: 6))
    }

    @Test func unrelatedSpeechIsNotEcho() {
        var guardrail = EchoGuard()
        guardrail.didStartSpeaking("Opened Safari.", at: 0)
        #expect(!guardrail.isEcho("Open Mail.", at: 1))
        #expect(!guardrail.isEcho("Opened Safari. Wait, open Mail and scroll down.", at: 1))
    }

    @Test func addressedCommandsAreNeverDropped() {
        var guardrail = EchoGuard()
        guardrail.didStartSpeaking("Computer cancel", at: 0)
        #expect(!guardrail.isEcho("Computer, cancel.", at: 0.5))
        let drop1 = guardrail.shouldDrop("Computer, cancel.", isFinal: false, at: 0.5, strict: true)
        #expect(!drop1)
    }

    @Test("Outside dictation, a segment that began during feedback is dropped whole")
    func strictOverlap() {
        var guardrail = EchoGuard()
        guardrail.didStartSpeaking("That app couldn't be found.", at: 0)
        let drop2 = guardrail.shouldDrop("Something", isFinal: false, at: 0.6, strict: true)
        #expect(drop2)
        guardrail.didFinishSpeaking(at: 1.2)
        let drop3 = guardrail.shouldDrop("Something else entirely.", isFinal: true, at: 2.0, strict: true)
        #expect(drop3)
        // The next segment starts well after feedback ended.
        let drop4 = guardrail.shouldDrop("Open Mail.", isFinal: true, at: 5.0, strict: true)
        #expect(!drop4)
    }

    @Test("While dictating, overlapping user speech is kept unless it is echo")
    func lenientInDictation() {
        var guardrail = EchoGuard()
        guardrail.didStartSpeaking("Dictation paused.", at: 0)
        let drop5 = guardrail.shouldDrop("Dear Sam", isFinal: false, at: 0.6, strict: false)
        #expect(!drop5)
    }

    @Test func consecutivePhrasesMerge() {
        var guardrail = EchoGuard()
        guardrail.didStartSpeaking("Nothing to delete.", at: 0)
        guardrail.didFinishSpeaking(at: 0.8)
        guardrail.didStartSpeaking("Start dictation first.", at: 0.9)
        #expect(guardrail.isEcho("Nothing to delete. Start dictation first.", at: 1.5))
    }

    @Test func similarity() {
        #expect(EchoGuard.similar("open", "opened"))
        #expect(EchoGuard.similar("catch", "catches"))
        #expect(EchoGuard.similar("command", "commands"))
        #expect(!EchoGuard.similar("a", "the"))
        #expect(!EchoGuard.similar("mail", "safari"))
    }
}
