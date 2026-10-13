@preconcurrency import AVFoundation
import Foundation

/// Microphone capture converted to 16 kHz mono float. The audio callback only copies the buffer;
/// conversion and delivery happen on `queue`, never on the real-time thread.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "keyless.audio")
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?

    // Energy-based onset detection, used only for latency metrics.
    private var quietSamples = 0
    private var inSpeech = false
    private static let onsetRMS: Float = 0.015

    /// 16 kHz mono samples, called on the audio queue.
    var onSamples: (@Sendable ([Float]) -> Void)?
    /// Uptime of an energy onset after at least 0.4 s of quiet, called on the main queue.
    var onSpeechOnset: (@MainActor (Double) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Keyless", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let copy = Self.copy(buffer) else { return }
            self.queue.async { self.process(copy) }
        }
        engine.prepare()
        try engine.start()

        if configObserver == nil {
            // Input device or format changed: rebuild the tap and converter.
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.engine.stop()
                do { try self.start() } catch {
                    let message = error.localizedDescription
                    MainActor.assumeIsolated { self.onError?("Microphone restart failed: \(message)") }
                }
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        detectOnset(samples)
        onSamples?(samples)
    }

    private func detectOnset(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        if rms >= Self.onsetRMS {
            if !inSpeech, quietSamples >= 6400 {
                let now = ProcessInfo.processInfo.systemUptime
                let callback = onSpeechOnset
                DispatchQueue.main.async { MainActor.assumeIsolated { callback?(now) } }
            }
            inSpeech = true
            quietSamples = 0
        } else {
            quietSamples += samples.count
            if quietSamples >= 6400 { inSpeech = false }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        // Interleaved buffers keep every channel in the first pointer.
        let interleaved = buffer.format.isInterleaved
        let pointers = interleaved ? 1 : Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength) * (interleaved ? Int(buffer.format.channelCount) : 1)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0 ..< pointers { dst[c].update(from: src[c], count: count) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0 ..< pointers { dst[c].update(from: src[c], count: count) }
        } else {
            return nil
        }
        return copy
    }
}
