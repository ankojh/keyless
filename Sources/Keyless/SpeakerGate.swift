import Foundation
import KeylessCore

/// Attaches a speaker verdict to each recognizer frame, using the audio of that frame's segment.
///
/// Partials are never delayed: they carry the latest verdict already computed for the segment,
/// while a fresh one is computed in the background. Finals, which can carry commands, are verified
/// synchronously (about 30–80 ms) before delivery. Segment state is confined to `streamQueue`.
final class SpeakerGate: @unchecked Sendable {
    private let embedder: SpeakerEmbedder
    private let streamQueue: DispatchQueue
    private let work = DispatchQueue(label: "keyless.speaker", qos: .userInitiated)
    private let lock = NSLock()
    private var voiceprint: Voiceprint?

    private var segmentID = 0
    private var segmentStart: Int?
    private var lastFinalEnd = 0
    private var cached: SpeakerVerdict?
    private var cachedSamples = 0
    private var computing = false

    /// The first partial arrives ~0.4 s after speech onset; include a little audio before that.
    private static let preRoll = 14400
    /// Less than 1 s of audio gives no verdict.
    private static let minimumSamples = 16000
    /// After 4 s of a segment agree, later partials reuse the verdict.
    private static let settledSamples = 64000
    private static let partialWindow = 96000
    private static let finalWindow = 128000

    /// Each final's score, on the main queue, for local threshold tuning (numbers only).
    var onScore: (@MainActor (Float, SpeakerVerdict) -> Void)?

    init(embedder: SpeakerEmbedder, streamQueue: DispatchQueue) {
        self.embedder = embedder
        self.streamQueue = streamQueue
    }

    var modelName: String { embedder.modelName }
    var isEnrolled: Bool { lock.withLock { voiceprint != nil } }

    /// Any thread.
    func setVoiceprint(_ print: Voiceprint?) {
        lock.withLock { voiceprint = print }
    }

    /// Embeds enrollment audio on the speaker queue.
    func embed(_ samples: [Float]) async -> [Float]? {
        await withCheckedContinuation { continuation in
            work.async { continuation.resume(returning: self.embedder.embed(samples)) }
        }
    }

    // MARK: Stream queue only

    func streamStarted() {
        segmentID += 1
        segmentStart = nil
        lastFinalEnd = 0
        cached = nil
        cachedSamples = 0
    }

    /// `audio(start)` returns the stream's samples from absolute index `start` to now.
    func verdict(for frame: ASRFrame, samplesSent: Int, audio: (Int) -> [Float]) -> SpeakerVerdict {
        guard let print = lock.withLock({ voiceprint }) else { return .verified }
        switch frame {
        case .partial:
            if segmentStart == nil { segmentStart = max(lastFinalEnd, samplesSent - Self.preRoll) }
            let start = segmentStart!
            let length = samplesSent - start
            let settled = cached != nil && cachedSamples >= Self.settledSamples
            if length >= Self.minimumSamples, !settled, !computing {
                computing = true
                let id = segmentID
                let samples = audio(max(start, samplesSent - Self.partialWindow))
                work.async { [self] in
                    let verdict = embedder.embed(samples).map(print.verdict(for:)) ?? .unknown
                    streamQueue.async { [self] in
                        computing = false
                        guard id == segmentID else { return }
                        cached = verdict
                        cachedSamples = length
                    }
                }
            }
            return cached ?? .unknown
        case .final:
            let start = segmentStart ?? max(lastFinalEnd, samplesSent - Self.preRoll - Self.minimumSamples)
            let samples = audio(max(start, samplesSent - Self.finalWindow))
            segmentID += 1
            segmentStart = nil
            lastFinalEnd = samplesSent
            cached = nil
            cachedSamples = 0
            guard samples.count >= Self.minimumSamples,
                  let embedding = work.sync(execute: { embedder.embed(samples) })
            else { return .unknown }
            let score = print.score(embedding)
            let verdict: SpeakerVerdict = score >= print.threshold ? .verified : .rejected
            let callback = onScore
            DispatchQueue.main.async { MainActor.assumeIsolated { callback?(score, verdict) } }
            return verdict
        case .done, .error:
            return .unknown
        }
    }
}
