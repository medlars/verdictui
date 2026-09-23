import Darwin
import Foundation
import VerdictUIWeb

/// Owns signal cleanup for a foreground server, including its headless children.
@MainActor
final class RuntimeShutdown {
    private let sessions: WebSessionManager
    private let socketPath: String?
    private var sources: [any DispatchSourceSignal] = []
    // SIG_DFL is represented by a nil function pointer in Darwin's Swift import.
    private var previous: [(Int32, sig_t?)] = []
    private var stopping = false

    init(sessions: WebSessionManager, socketPath: String? = nil) {
        self.sessions = sessions
        self.socketPath = socketPath
        for number in [SIGTERM, SIGINT] {
            previous.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                Task { @MainActor in await self?.shutdown(signal: number) }
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for (number, handler) in previous { signal(number, handler) }
        previous.removeAll()
    }

    private func shutdown(signal number: Int32) async {
        guard !stopping else { return }
        stopping = true
        let failures = await sessions.closeAll()
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data("verdictui: browser shutdown incomplete\n".utf8))
        }
        Darwin.exit(128 + number)
    }
}
