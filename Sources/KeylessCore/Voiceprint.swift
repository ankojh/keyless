import Foundation

/// Whether a recognizer segment was spoken by the enrolled user.
public enum SpeakerVerdict: Equatable, Sendable {
    case verified
    case rejected
    /// Too little audio to decide, or no voiceprint enrolled.
    case unknown
}

/// The enrolled user's voice: a unit-length mean speaker embedding plus the acceptance threshold.
/// Stored locally only. It is biometric data, so it never leaves the Mac.
public struct Voiceprint: Codable, Equatable, Sendable {
    public let model: String
    public let centroid: [Float]
    public var threshold: Float
    public let enrolledAt: Date
    /// Leave-one-out scores of the enrollment windows against the rest, for diagnostics and tuning.
    public let enrollmentScores: [Float]

    /// Short noisy commands scored an equal-error point near 0.54 in the Milestone 0 benchmark;
    /// start slightly below it so the user's own short commands aren't rejected.
    public static let defaultThreshold: Float = 0.5
    /// Fewer windows than this (about 10 s of speech) gives an unreliable centroid.
    public static let minimumWindows = 6

    public enum BuildError: Error, Equatable {
        case notEnoughSpeech(windows: Int)
        case inconsistent(medianScore: Float)
    }

    /// Builds a voiceprint from embeddings of overlapping enrollment windows.
    public static func build(model: String, embeddings: [[Float]], threshold: Float = defaultThreshold, now: Date = Date()) throws -> Voiceprint {
        let vectors = embeddings.map(normalized).filter { !$0.isEmpty }
        guard vectors.count >= minimumWindows else { throw BuildError.notEnoughSpeech(windows: vectors.count) }
        let centroid = normalized(mean(vectors))
        let loo = vectors.indices.map { i -> Float in
            let others = vectors.enumerated().filter { $0.offset != i }.map(\.element)
            return cosine(vectors[i], normalized(mean(others)))
        }
        let median = loo.sorted()[loo.count / 2]
        // Windows that don't agree with each other usually mean several voices or heavy noise.
        guard median >= 0.6 else { throw BuildError.inconsistent(medianScore: median) }
        return Voiceprint(model: model, centroid: centroid, threshold: threshold, enrolledAt: now, enrollmentScores: loo)
    }

    public func score(_ embedding: [Float]) -> Float {
        Self.cosine(Self.normalized(embedding), centroid)
    }

    public func verdict(for embedding: [Float]) -> SpeakerVerdict {
        guard embedding.count == centroid.count else { return .unknown }
        return score(embedding) >= threshold ? .verified : .rejected
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in sum.indices { sum[i] += v[i] } }
        return sum.map { $0 / Float(vectors.count) }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : []
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
