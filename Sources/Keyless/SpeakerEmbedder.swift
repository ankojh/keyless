import CSherpaOnnx
import Foundation

/// Speaker embeddings from a sherpa-onnx model (3D-Speaker ERES2Net, chosen in
/// spike/evidence/speaker-models.json). Not thread-safe; callers confine it to one queue.
final class SpeakerEmbedder: @unchecked Sendable {
    let modelName: String
    let dimension: Int
    private let extractor: OpaquePointer

    init?(modelURL: URL, threads: Int32 = 2) {
        modelName = modelURL.deletingPathExtension().lastPathComponent
        let created: OpaquePointer? = modelURL.path.withCString { model in
            "cpu".withCString { provider in
                var config = SherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, num_threads: threads, debug: 0, provider: provider)
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
            }
        }
        guard let created else { return nil }
        extractor = created
        dimension = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(created))
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor)
    }

    /// Embedding of 16 kHz mono audio, or nil if the model needs more audio than given.
    func embed(_ samples: [Float]) -> [Float]? {
        let ex = extractor
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ex) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(ex, stream) == 1,
              let vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ex, stream)
        else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
        return Array(UnsafeBufferPointer(start: vector, count: dimension))
    }
}
