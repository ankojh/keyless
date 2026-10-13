import AppKit
import ApplicationServices
import KeylessCore

/// Edits the focused text control through Accessibility, touching only the range one dictation
/// session owns. Every edit checks focus, caret and owned text first, and verifies the result after.
@MainActor
final class FocusedTextAdapter {
    struct Target {
        let element: AXUIElement
        let pid: pid_t
        let appName: String
        let singleLine: Bool
        /// UTF-16 offset where the session's text starts.
        let anchor: Int
        /// The text this session believes is at `anchor`.
        var owned: String
    }

    enum Prepared {
        case ready(leadingContext: Character?)
        case refused(String)
    }

    private(set) var target: Target?

    /// Terminals and REPLs are excluded from the MVP: a newline there can execute a command.
    private static let excludedBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]

    func prepare() -> Prepared {
        target = nil
        guard AXIsProcessTrusted() else { return .refused("I need Accessibility permission to type.") }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element: AXUIElement = AX.attribute(system, kAXFocusedUIElementAttribute) else {
            return .refused("I can't find a focused text field.")
        }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return .refused("Focus a text field in another app first.") }
        if let bundle = app?.bundleIdentifier, Self.excludedBundles.contains(bundle) {
            return .refused("Terminals aren't supported for dictation.")
        }

        let role: String = AX.attribute(element, kAXRoleAttribute) ?? ""
        let subrole: String = AX.attribute(element, kAXSubroleAttribute) ?? ""
        if subrole == kAXSecureTextFieldSubrole as String { return .refused("That's a password field. I won't type there.") }
        guard [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) else {
            return .refused("The focused control isn't a supported text field.")
        }
        guard AX.isSettable(element, kAXSelectedTextRangeAttribute), AX.isSettable(element, kAXSelectedTextAttribute) else {
            return .refused("This field doesn't allow safe editing.")
        }
        guard let selection = AX.selectedRange(element) else { return .refused("I can't read the cursor position.") }
        guard selection.length == 0 else { return .refused("Clear the selection first, then start dictation.") }

        let anchor = selection.location
        let leading = anchor > 0 ? AX.string(element, location: anchor - 1, length: 1)?.last : nil
        target = Target(element: element, pid: pid, appName: app?.localizedName ?? "the app",
                        singleLine: role != kAXTextAreaRole as String, anchor: anchor, owned: "")
        return .ready(leadingContext: leading)
    }

    func release() {
        target = nil
    }

    /// Returns nil on success, or why dictation must pause.
    func apply(_ edit: TextEdit) -> String? {
        guard var t = target else { return "No dictation target." }
        if t.singleLine, edit.replacement.contains("\n") { return "This field is single-line." }
        if let problem = check(t) { return problem }

        guard AX.setSelectedRange(t.element, location: t.anchor + edit.location, length: edit.length),
              AX.setAttribute(t.element, kAXSelectedTextAttribute, edit.replacement as CFString)
        else { return "\(t.appName) refused the edit." }
        guard let updated = edit.apply(to: t.owned) else { return "Internal edit mismatch." }
        t.owned = updated
        target = t
        let end = t.anchor + updated.utf16.count
        _ = AX.setSelectedRange(t.element, location: end, length: 0)

        guard AX.string(t.element, location: t.anchor, length: updated.utf16.count) == updated else {
            return "I couldn't verify the text in \(t.appName)."
        }
        return nil
    }

    /// Periodic check between edits. Returns why dictation must pause, if it must.
    func validate() -> String? {
        guard let t = target else { return nil }
        return check(t)
    }

    private func check(_ t: Target) -> String? {
        let system = AXUIElementCreateSystemWide()
        guard let focused: AXUIElement = AX.attribute(system, kAXFocusedUIElementAttribute), CFEqual(focused, t.element) else {
            return "The focused field changed."
        }
        let end = t.anchor + t.owned.utf16.count
        guard let selection = AX.selectedRange(t.element), selection.location == end, selection.length == 0 else {
            return "The cursor moved."
        }
        if !t.owned.isEmpty, AX.string(t.element, location: t.anchor, length: t.owned.utf16.count) != t.owned {
            return "The text changed."
        }
        return nil
    }
}

/// Thin Accessibility helpers.
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func setAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    static func setSelectedRange(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return setAttribute(element, kAXSelectedTextRangeAttribute, value)
    }

    /// Text in a UTF-16 range, using the parameterized attribute and falling back to the full value.
    static func string(_ element: AXUIElement, location: Int, length: Int) -> String? {
        if length == 0 { return "" }
        var range = CFRange(location: location, length: length)
        if let param = AXValueCreate(.cfRange, &range) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &value) == .success,
               let s = value as? String {
                return s
            }
        }
        guard let full: String = attribute(element, kAXValueAttribute) else { return nil }
        let units = Array(full.utf16)
        guard location >= 0, location + length <= units.count else { return nil }
        return String(utf16CodeUnits: Array(units[location ..< location + length]), count: length)
    }
}
