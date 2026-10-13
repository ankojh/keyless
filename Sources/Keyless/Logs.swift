import Foundation

/// Local diagnostics under ~/Library/Logs/Keyless. Never records audio or transcript text.
enum Logs {
    static let directory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Keyless")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func handle(named name: String) -> FileHandle? {
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// Appends one JSON line of numbers and labels to metrics.jsonl.
    @MainActor
    static func metric(_ kind: String, _ fields: [String: Any] = [:]) {
        var record = fields
        record["kind"] = kind
        record["t"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        metricsHandle?.write(data + Data("\n".utf8))
    }

    @MainActor private static let metricsHandle = handle(named: "metrics.jsonl")

    @MainActor
    static func event(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        eventsHandle?.write(Data(line.utf8))
    }

    @MainActor private static let eventsHandle = handle(named: "events.log")
}
