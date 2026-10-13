import Foundation

/// A replacement inside the text owned by one dictation session.
///
/// `location` and `length` are UTF-16 offsets relative to the start of the owned range, matching
/// Accessibility's CFRange units. The adapter adds the session's anchor offset, checks the field
/// still contains `expected` at that range, and only then writes `replacement`.
public struct TextEdit: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let expected: String
    public let replacement: String

    public init(location: Int, length: Int, expected: String, replacement: String) {
        self.location = location
        self.length = length
        self.expected = expected
        self.replacement = replacement
    }

    /// The smallest single replacement that turns `old` into `new`, split on grapheme boundaries.
    public static func diff(from old: String, to new: String) -> TextEdit? {
        if old == new { return nil }
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let removed = String(a[prefix ..< a.count - suffix])
        let inserted = String(b[prefix ..< b.count - suffix])
        let location = String(a[..<prefix]).utf16.count
        return TextEdit(location: location, length: removed.utf16.count, expected: removed, replacement: inserted)
    }

    /// Applies the edit to a string that is expected to match; returns nil if it does not.
    public func apply(to text: String) -> String? {
        let utf16 = Array(text.utf16)
        guard location >= 0, location + length <= utf16.count else { return nil }
        let start = String(utf16CodeUnits: Array(utf16[..<location]), count: location)
        let middle = String(utf16CodeUnits: Array(utf16[location ..< location + length]), count: length)
        let end = String(utf16CodeUnits: Array(utf16[(location + length)...]), count: utf16.count - location - length)
        guard middle == expected else { return nil }
        return start + replacement + end
    }
}
