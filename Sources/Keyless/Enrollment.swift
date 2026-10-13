import Foundation
import KeylessCore

/// Collects microphone samples only while an enrollment is running. Safe to call from the audio queue.
final class EnrollmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float]?

    func start() { lock.withLock { samples = [] } }

    func append(_ chunk: [Float]) {
        lock.withLock { samples?.append(contentsOf: chunk) }
    }

    func stop() -> [Float] {
        lock.withLock {
            defer { samples = nil }
            return samples ?? []
        }
    }
}

enum Enrollment {
    static let seconds = 25

    static let passage = """
    Read this aloud in your normal voice: \
    I'm teaching my computer to recognize my voice, so it only listens to me. \
    When I say open Safari, start dictation, or go to sleep, it should answer me and nobody else. \
    The quick brown fox jumps over the lazy dog, and numbers like seventeen, forty two, and ninety nine \
    should all sound clear. If someone else is talking in the room, or a video is playing, it should ignore them.
    """

    /// Keeps voiced 20 ms frames (plus a short hangover) so silence doesn't dilute the voiceprint.
    static func voicedAudio(_ samples: [Float]) -> [Float] {
        let frame = 320
        let count = samples.count / frame
        guard count > 0 else { return [] }
        let rms = (0 ..< count).map { i -> Float in
            let slice = samples[i * frame ..< (i + 1) * frame]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot()
        }
        let floor = rms.sorted()[count / 5]
        let threshold = max(0.008, floor * 3)
        var out: [Float] = []
        var hangover = 0
        for i in 0 ..< count {
            if rms[i] >= threshold { hangover = 10 }
            if hangover > 0 {
                out.append(contentsOf: samples[i * frame ..< (i + 1) * frame])
                hangover -= 1
            }
        }
        return out
    }

    /// 3 s windows with a 1.5 s hop, matching the benchmark's enrollment.
    static func windows(_ voiced: [Float]) -> [[Float]] {
        stride(from: 0, through: voiced.count - 48000, by: 24000).map { Array(voiced[$0 ..< $0 + 48000]) }
    }
}

/// The voiceprint file, readable only by this user. It never leaves the Mac.
enum VoiceStore {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyless", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("voiceprint.json")
    }()

    static func load(model: String) -> Voiceprint? {
        guard let data = try? Data(contentsOf: url), let print = try? JSONDecoder().decode(Voiceprint.self, from: data) else { return nil }
        // A voiceprint from a different model isn't comparable.
        return print.model == model ? print : nil
    }

    static func save(_ print: Voiceprint) throws {
        let data = try JSONEncoder().encode(print)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
