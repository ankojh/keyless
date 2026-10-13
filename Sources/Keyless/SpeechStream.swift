import Foundation
import KeylessCore

/// One live Phonon-2 WebSocket stream. All state is confined to `queue`.
///
/// Each connection gets an epoch; frames from an older epoch are dropped by the receiver, so a
/// reconnect can never replay text into the new session.
final class SpeechStream: @unchecked Sendable {
    struct Delivery: Sendable {
        let frame: ASRFrame
        let audioTime: Double
        let epoch: Int
        let receivedAt: Double
        let speaker: SpeakerVerdict
    }

    let queue = DispatchQueue(label: "keyless.speech-stream")
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var samplesSent = 0
    private var epoch = 0
    private var open = false

    /// Recent audio for speaker verification: `history[0]` is absolute sample `historyStart`.
    private var history: [Float] = []
    private var historyStart = 0
    private static let historyLimit = 16000 * 48
    private static let historyTrim = 16000 * 8

    /// Set once at startup; nil when no speaker model is available.
    var gate: SpeakerGate?

    /// Called on the main queue, in arrival order.
    var onFrame: (@MainActor (Delivery) -> Void)?
    /// Called on the main queue when the current stream ends for any reason.
    var onClosed: (@MainActor (_ epoch: Int, _ reason: String) -> Void)?

    func connect(url: URL, apiKey: String) {
        queue.async { [self] in
            task?.cancel(with: .goingAway, reason: nil)
            epoch += 1
            samplesSent = 0
            history.removeAll(keepingCapacity: true)
            historyStart = 0
            gate?.streamStarted()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)
            self.task = task
            open = true
            task.resume()
            task.send(.string(#"{"sample_rate": 16000, "format": "pcm_f32le"}"#)) { _ in }
            receive(task, epoch: epoch)
        }
    }

    func close() {
        queue.async { [self] in
            open = false
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
        }
    }

    /// Sends 16 kHz mono float samples. Dropped while disconnected.
    func send(_ samples: [Float]) {
        queue.async { [self] in
            guard open, let task else { return }
            samplesSent += samples.count
            if gate != nil {
                history.append(contentsOf: samples)
                if history.count > Self.historyLimit {
                    history.removeFirst(Self.historyTrim)
                    historyStart += Self.historyTrim
                }
            }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            task.send(.data(data)) { _ in }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, epoch: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard epoch == self.epoch else { return }
                switch result {
                case .success(.string(let text)):
                    let receivedAt = ProcessInfo.processInfo.systemUptime
                    let audioTime = Double(self.samplesSent) / 16000
                    let frame = (try? ASRFrameDecoder.decode(text)) ?? .error("Undecodable frame")
                    let speaker = self.gate?.verdict(for: frame, samplesSent: self.samplesSent, audio: self.audio(from:)) ?? .verified
                    self.deliver(Delivery(frame: frame, audioTime: audioTime, epoch: epoch, receivedAt: receivedAt, speaker: speaker))
                    if case .error(let message) = frame { self.finish(epoch: epoch, reason: message) } else { self.receive(task, epoch: epoch) }
                case .success:
                    self.receive(task, epoch: epoch)
                case .failure(let error):
                    let code = task.closeCode.rawValue
                    self.finish(epoch: epoch, reason: code != 0 ? "closed \(code)" : error.localizedDescription)
                }
            }
        }
    }

    /// Samples from absolute index `start` to now (clamped to what's retained).
    private func audio(from start: Int) -> [Float] {
        let offset = max(0, start - historyStart)
        return offset < history.count ? Array(history[offset...]) : []
    }

    private func finish(epoch: Int, reason: String) {
        open = false
        task = nil
        let callback = onClosed
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(epoch, reason) } }
    }

    private func deliver(_ delivery: Delivery) {
        let callback = onFrame
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(delivery) } }
    }

    /// Streams a short clip through the live path and waits for `done`, so the first real stream is
    /// warm. Measured: the first stream after server start took 2.9 s to its first partial.
    static func warmUp(url: URL, apiKey: String, samples: [Float]) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        do {
            try await task.send(.string(#"{"sample_rate": 16000, "format": "pcm_f32le"}"#))
            for start in stride(from: 0, to: samples.count, by: 3200) {
                let chunk = Array(samples[start ..< min(start + 3200, samples.count)])
                try await task.send(.data(chunk.withUnsafeBufferPointer { Data(buffer: $0) }))
            }
            try await task.send(.string(#"{"type": "end"}"#))
            while true {
                if case .string(let text) = try await task.receive(), case .done = try ASRFrameDecoder.decode(text) {
                    return true
                }
            }
        } catch {
            return false
        }
    }
}
