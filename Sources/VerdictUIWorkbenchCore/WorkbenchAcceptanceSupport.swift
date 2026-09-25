import AppKit
import CoreFoundation
import CryptoKit
import Foundation

/// Internal acceptance mechanisms shared with their native behavioral witnesses.
@MainActor
package enum WorkbenchAcceptanceValues {
    package static func mediaBoolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw WorkbenchMotionFailure(stage: .media, detail: "native reduced-motion media value unavailable")
        }
        return number.boolValue
    }
}

package struct WorkbenchMotionFailure: Error, CustomStringConvertible {
    package enum Stage: String, Sendable { case media, capture, parse, serialization, write }
    package let stage: Stage
    package let detail: String
    package var evaluationError: String? = nil
    package var description: String {
        "motion observation \(stage.rawValue) unavailable: \(detail)"
            + (evaluationError.map { "; evaluation error: \($0)" } ?? "")
    }
}

@MainActor
package final class WorkbenchMotionRecorder {
    private let readNative: () -> [String: Any]
    private let write: (Data, String) throws -> Void
    package private(set) var samples: [[String: Any]] = []

    package init(readNative: @escaping () -> [String: Any],
                 write: @escaping (Data, String) throws -> Void) {
        self.readNative = readNative
        self.write = write
    }

    package func observe(_ checkpoint: String, evaluate: () async throws -> Any?) async throws {
        let before = readNative()
        var value: Any?
        var evaluationError: String?
        do { value = try await evaluate() }
        catch { evaluationError = String(describing: error) }
        let after = readNative()
        let raw = value as? String
        var retained: [String: Any] = ["checkpoint": checkpoint, "native_before": before,
                                      "web_json": raw ?? "", "native_after": after]
        if let evaluationError { retained["evaluation_error"] = evaluationError }
        let bytes: Data
        do { bytes = try JSONSerialization.data(withJSONObject: retained, options: [.prettyPrinted, .sortedKeys]) }
        catch {
            throw archiveFailure(.serialization, checkpoint: checkpoint, error: error, evaluationError: evaluationError)
        }
        let name = "motion-sample-\(samples.count).json"
        do { try write(bytes, name) }
        catch {
            throw archiveFailure(.write, checkpoint: checkpoint, error: error, evaluationError: evaluationError)
        }
        var sample: [String: Any] = ["checkpoint": checkpoint, "native_before": before,
                                    "native_after": after,
                                    "raw_artifact": ["path": name, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]]
        guard evaluationError == nil, let raw,
              let data = raw.data(using: .utf8),
              let web = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let detail = evaluationError ?? "motion observation did not return a JSON object"
            sample["capture_error"] = detail
            samples.append(sample)
            throw WorkbenchMotionFailure(stage: evaluationError == nil ? .parse : .capture,
                                         detail: "\(detail); retained \(name)", evaluationError: evaluationError)
        }
        sample["web"] = web
        samples.append(sample)
    }

    private func archiveFailure(_ stage: WorkbenchMotionFailure.Stage, checkpoint: String,
                                error: Error, evaluationError: String?) -> WorkbenchMotionFailure {
        let failure = WorkbenchMotionFailure(stage: stage, detail: String(describing: error), evaluationError: evaluationError)
        // Failed serialization or writing cannot supply a raw-artifact descriptor.
        // Keep this error sample JSON-safe even when a native value was not.
        var sample: [String: Any] = ["checkpoint": checkpoint,
                                    "archival_error": ["stage": stage.rawValue, "error": failure.detail]]
        if let evaluationError { sample["capture_error"] = evaluationError }
        samples.append(sample)
        return failure
    }
}

@MainActor
package final class WorkbenchMotionObservationToken {
    private var cancellation: (() -> Void)?

    fileprivate init(cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    package func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }
}

@MainActor
package struct WorkbenchMotionPublisher {
    private let center: NotificationCenter
    private let name: Notification.Name

    package init(center: NotificationCenter, name: Notification.Name) {
        self.center = center
        self.name = name
    }

    @MainActor
    private final class Delivery {
        var active = true
        let receive: @MainActor () -> Void
        init(receive: @escaping @MainActor () -> Void) { self.receive = receive }
        func deliver() {
            guard active else { return }
            receive()
        }
    }

    package func observe(_ receive: @escaping @MainActor () -> Void) -> WorkbenchMotionObservationToken {
        let delivery = Delivery(receive: receive)
        let opaqueToken = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in delivery.deliver() }
        }
        return WorkbenchMotionObservationToken {
            delivery.active = false
            center.removeObserver(opaqueToken)
        }
    }
}

@MainActor
package final class WorkbenchMotionResources {
    package enum HostMode { case detached, invisibleWindow }
    private let mode: HostMode
    private let makeWindow: (NSRect) -> NSWindow
    private var observation: WorkbenchMotionObservationToken?
    private var closed = false
    package private(set) var window: NSWindow?

    package init(mode: HostMode, publisher: WorkbenchMotionPublisher,
                 makeWindow: @escaping (NSRect) -> NSWindow = { frame in
                     let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
                     window.isReleasedWhenClosed = false
                     return window
                 }, receive: @escaping @MainActor () -> Void) {
        self.mode = mode
        self.makeWindow = makeWindow
        observation = publisher.observe(receive)
    }

    package func attach(_ view: NSView) {
        guard !closed, mode == .invisibleWindow else { return }
        if window == nil { window = makeWindow(view.frame) }
        // The owned acceptance window is never ordered, shown, made key or activated.
        window?.contentView = view
    }

    package func close() {
        closed = true
        observation?.cancel()
        observation = nil
        window?.contentView = nil
        window?.close()
        window = nil
    }

    /// Bridge shutdown must finish before owned resources are closed, including on failure.
    package func withCleanup(body: () async throws -> Void, shutdown: () async -> Void) async rethrows {
        do { try await body() }
        catch {
            await shutdown()
            close()
            throw error
        }
        await shutdown()
        close()
    }
}
