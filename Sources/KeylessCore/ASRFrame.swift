import Foundation

/// One server frame from the Phonon-2 live WebSocket, as measured in docs/milestone-0.md.
///
/// A partial carries the whole current hypothesis for the in-flight segment, not a delta.
/// `done` repeats every final joined with spaces and must never be inserted as text.
public enum ASRFrame: Equatable, Sendable {
    case partial(String)
    case final(String, segment: Int)
    case done(String)
    case error(String)
}

public enum ASRFrameDecodingError: Error, Equatable {
    case notJSONObject
    case missingField(String)
    case unknownType(String)
}

public enum ASRFrameDecoder {
    public static func decode(_ text: String) throws -> ASRFrame {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ASRFrameDecodingError.notJSONObject }
        guard let type = object["type"] as? String else { throw ASRFrameDecodingError.missingField("type") }

        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw ASRFrameDecodingError.missingField(key) }
            return value
        }

        switch type {
        case "partial":
            return .partial(try string("text"))
        case "final":
            guard let segment = object["segment"] as? Int else { throw ASRFrameDecodingError.missingField("segment") }
            return .final(try string("text"), segment: segment)
        case "done":
            return .done(try string("text"))
        case "error":
            return .error(try string("message"))
        default:
            throw ASRFrameDecodingError.unknownType(type)
        }
    }
}
