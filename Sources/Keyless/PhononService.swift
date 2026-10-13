import Foundation

/// Runs one warm `fermion serve phonon-2` process bound to loopback, restarting it if it exits.
///
/// The process gets a fresh random API key at each launch. It's passed as an argument because
/// fermion 0.2.11 has no other way to receive it; macOS only shows process arguments to the same user.
@MainActor
final class PhononService {
    enum State: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    let executable: URL
    let port: Int
    let apiKey: String
    private(set) var state: State = .stopped { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?

    private var process: Process?
    private var stopping = false
    private var restarts = 0

    init(executable: URL) {
        self.executable = executable
        self.port = Self.freeLoopbackPort() ?? 8765
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.apiKey = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var streamURL: URL { URL(string: "ws://127.0.0.1:\(port)/v1/audio/stream")! }

    func start() {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            state = .failed("Phonon runtime not found at \(executable.path). See spike/README.md.")
            return
        }
        stopping = false
        state = .starting
        Self.terminateStaleServer()

        let process = Process()
        process.executableURL = executable
        // Explicit arguments, no shell.
        process.arguments = ["serve", "phonon-2", "--host", "127.0.0.1", "--port", String(port), "--api-key", apiKey]
        if let log = Logs.handle(named: "phonon.log") {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processExited(status: status) }
            }
        }
        do {
            try process.run()
        } catch {
            state = .failed("Couldn't start Phonon: \(error.localizedDescription)")
            return
        }
        self.process = process
        try? String(process.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)
        Task { await waitUntilHealthy() }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
        state = .stopped
    }

    private static let pidFile = Logs.directory.appendingPathComponent("phonon.pid")

    /// A server left behind by a crashed or force-quit Keyless holds 1.3 GB; stop it before starting
    /// another. Only a process that is still running our fermion executable is signalled.
    private static func terminateStaleServer() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return }
        let args = String(decoding: buffer.prefix(size).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if args.contains("fermion"), args.contains("serve"), args.contains("phonon-2") {
            kill(pid, SIGTERM)
        }
    }

    private func processExited(status: Int32) {
        process = nil
        guard !stopping else { return }
        restarts += 1
        if restarts > 5 {
            state = .failed("Phonon keeps exiting (status \(status)). See ~/Library/Logs/Keyless/phonon.log.")
            return
        }
        state = .failed("Phonon exited (status \(status)); restarting.")
        let delay = min(8.0, pow(2.0, Double(restarts - 1)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func waitUntilHealthy() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: 1)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Model load is documented at 10–40 s; allow 120 s for a first-run download.
        for _ in 0 ..< 240 {
            if process == nil { return }
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                restarts = 0
                state = .ready
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        state = .failed("Phonon didn't become ready in 120 s.")
    }

    private static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
}
