import AppKit
import CoreFoundation
import CryptoKit
import Foundation
import XCTest
@testable import VerdictUIWorkbenchCore

@MainActor
final class WorkbenchAcceptanceSupportTests: XCTestCase {
    private struct Sentinel: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    private final class LifetimeProbe {
        var deliveries = 0
    }

    @MainActor
    private final class WeakProbe {
        weak var value: LifetimeProbe?
        init(_ value: LifetimeProbe?) { self.value = value }
    }

    @MainActor
    private final class RetainedWindow: NSWindow {
        var closeCalls = 0
        var onClose: (() -> Void)?
        override func close() {
            closeCalls += 1
            onClose?()
            super.close()
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func window() -> RetainedWindow {
        _ = NSApplication.shared
        let value = RetainedWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                                   styleMask: .borderless, backing: .buffered, defer: true)
        value.isReleasedWhenClosed = false
        return value
    }

    private func publisher(_ center: NotificationCenter, _ name: Notification.Name) -> WorkbenchMotionPublisher {
        WorkbenchMotionPublisher(center: center, name: name)
    }

    private func receiving(_ probe: LifetimeProbe, after: @escaping () -> Void = {}) -> @MainActor () -> Void {
        { probe.deliveries += 1; after() }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "private notification callback did not settle")
    }

    private func failure(_ operation: () async throws -> Void) async -> WorkbenchMotionFailure? {
        do { try await operation(); XCTFail("expected unavailable observation") }
        catch let error as WorkbenchMotionFailure { return error }
        catch { XCTFail("unexpected error: \(error)") }
        return nil
    }

    private func rawSample(_ recorder: WorkbenchMotionRecorder, in root: URL) throws -> [String: Any] {
        let sample = try XCTUnwrap(recorder.samples.last)
        let artifact = try XCTUnwrap(sample["raw_artifact"] as? [String: String])
        let path = try XCTUnwrap(artifact["path"])
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let actualHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(artifact["sha256"], actualHash)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func testMediaBooleanPreservesBothRealCFBooleanValues() throws {
        XCTAssertTrue(try WorkbenchAcceptanceValues.mediaBoolean(kCFBooleanTrue))
        XCTAssertFalse(try WorkbenchAcceptanceValues.mediaBoolean(kCFBooleanFalse))
    }

    func testMediaBooleanRejectsNumericAndUnknownValues() {
        let values: [Any?] = [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 0.5),
                              "false", NSNull(), nil]
        for value in values {
            XCTAssertThrowsError(try WorkbenchAcceptanceValues.mediaBoolean(value), "accepted \(String(describing: value))")
        }
    }

    func testSuccessfulCaptureAppendsRealHashBoundSidecars() async throws {
        let root = try directory()
        var nativeReads = 0
        let recorder = WorkbenchMotionRecorder(readNative: {
            nativeReads += 1
            return ["reading": nativeReads]
        }, write: { bytes, name in try bytes.write(to: root.appendingPathComponent(name), options: .atomic) })
        let raw = "{\"reduced\":true,\"animations\":[]}"
        try await recorder.observe("first") { raw }
        try await recorder.observe("second") { raw }
        XCTAssertEqual(recorder.samples.count, 2)
        let retained = try rawSample(recorder, in: root)
        XCTAssertEqual(retained["checkpoint"] as? String, "second")
        XCTAssertEqual(retained["web_json"] as? String, raw)
        XCTAssertEqual((retained["native_before"] as? [String: Int])?["reading"], 3)
        XCTAssertEqual((retained["native_after"] as? [String: Int])?["reading"], 4)
        XCTAssertEqual((recorder.samples.last?["web"] as? [String: Any])?["reduced"] as? Bool, true)
        XCTAssertNil(recorder.samples.last?["capture_error"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       ["motion-sample-0.json", "motion-sample-1.json"])
    }

    func testThrownEvaluationIsRetainedBeforeUnavailable() async throws {
        let root = try directory()
        var nativeReads = 0
        let recorder = WorkbenchMotionRecorder(readNative: {
            nativeReads += 1
            return ["reading": nativeReads]
        }, write: { bytes, name in try bytes.write(to: root.appendingPathComponent(name), options: .atomic) })
        let error = await failure {
            try await recorder.observe("capture-failure") { throw Sentinel(description: "synthetic evaluator error") }
        }
        XCTAssertEqual(error?.stage, .capture)
        XCTAssertEqual(recorder.samples.count, 1)
        let retained = try rawSample(recorder, in: root)
        XCTAssertEqual(retained["evaluation_error"] as? String, "synthetic evaluator error")
        XCTAssertEqual(retained["checkpoint"] as? String, "capture-failure")
        XCTAssertEqual((retained["native_before"] as? [String: Int])?["reading"], 1)
        XCTAssertEqual((retained["native_after"] as? [String: Int])?["reading"], 2)
        XCTAssertEqual(retained["web_json"] as? String, "")
        XCTAssertEqual(recorder.samples.first?["capture_error"] as? String, "synthetic evaluator error")
        XCTAssertNil(recorder.samples.first?["web"])
    }

    func testMalformedReturnRetainsOriginalBytesAsParseFailure() async throws {
        let root = try directory()
        let recorder = WorkbenchMotionRecorder(readNative: { ["reading": 1] },
            write: { bytes, name in try bytes.write(to: root.appendingPathComponent(name), options: .atomic) })
        let error = await failure { try await recorder.observe("malformed") { "{not JSON" } }
        XCTAssertEqual(error?.stage, .parse)
        let retained = try rawSample(recorder, in: root)
        XCTAssertEqual(retained["web_json"] as? String, "{not JSON")
        XCTAssertNil(retained["evaluation_error"])
        XCTAssertNil(recorder.samples.first?["web"])
        XCTAssertNotNil(recorder.samples.first?["capture_error"])
    }

    func testSerializationFailureCannotInventRawArtifactAndPreservesEvaluationError() async throws {
        let root = try directory()
        var writes = 0
        let recorder = WorkbenchMotionRecorder(readNative: { ["invalid": Date(timeIntervalSince1970: 0)] },
            write: { bytes, name in
                writes += 1
                try bytes.write(to: root.appendingPathComponent(name), options: .atomic)
            })
        let error = await failure {
            try await recorder.observe("serialization") { throw Sentinel(description: "original capture error") }
        }
        XCTAssertEqual(error?.stage, .serialization)
        XCTAssertEqual(error?.evaluationError, "original capture error")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(recorder.samples.count, 1)
        XCTAssertNil(recorder.samples.first?["raw_artifact"])
        XCTAssertEqual((recorder.samples.first?["archival_error"] as? [String: String])?["stage"], "serialization")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(recorder.samples))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRealWriteFailureCannotInventRawArtifactAndPreservesEvaluationError() async throws {
        let root = try directory()
        let missing = root.appendingPathComponent("absent-parent")
        let recorder = WorkbenchMotionRecorder(readNative: { ["reading": 1] },
            write: { bytes, name in try bytes.write(to: missing.appendingPathComponent(name), options: .atomic) })
        let error = await failure {
            try await recorder.observe("write") { throw Sentinel(description: "original capture error") }
        }
        XCTAssertEqual(error?.stage, .write)
        XCTAssertEqual(error?.evaluationError, "original capture error")
        XCTAssertEqual(recorder.samples.count, 1)
        XCTAssertNil(recorder.samples.first?["raw_artifact"])
        XCTAssertEqual((recorder.samples.first?["archival_error"] as? [String: String])?["stage"], "write")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testOwnedWindowReplacesAndDetachesViewsAndClosesExactlyOnce() {
        let center = NotificationCenter()
        let retained = window()
        let unrelated = window()
        defer { unrelated.close() }
        var creations = 0
        let resources = WorkbenchMotionResources(mode: .invisibleWindow,
            publisher: publisher(center, Notification.Name(UUID().uuidString)), makeWindow: { _ in
                creations += 1
                return retained
            }, receive: {})
        let first = NSView(frame: retained.frame)
        let second = NSView(frame: retained.frame)
        resources.attach(first)
        XCTAssertTrue(first.window === retained)
        resources.attach(second)
        XCTAssertNil(first.window)
        XCTAssertTrue(second.window === retained)
        resources.close()
        resources.close()
        XCTAssertEqual(creations, 1)
        XCTAssertNil(second.window)
        XCTAssertNil(retained.contentView)
        XCTAssertEqual(retained.closeCalls, 1)
        XCTAssertNil(resources.window)
        XCTAssertEqual(unrelated.closeCalls, 0)
        XCTAssertFalse(retained.isVisible || retained.isKeyWindow || retained.isMainWindow)
    }

    func testDetachedAndClosedResourcesNeverCreateAWindow() {
        let center = NotificationCenter()
        for mode in [WorkbenchMotionResources.HostMode.detached, .invisibleWindow] {
            var creations = 0
            let resources = WorkbenchMotionResources(mode: mode,
                publisher: publisher(center, Notification.Name(UUID().uuidString)),
                makeWindow: { _ in creations += 1; return self.window() }, receive: {})
            if mode == .invisibleWindow { resources.close() }
            resources.attach(NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
            resources.close()
            XCTAssertEqual(creations, 0)
            XCTAssertNil(resources.window)
        }
    }

    func testCancellationRemovesActualRegistrationAndReleasesCallbackWhileTokenRetained() async throws {
        let center = NotificationCenter()
        let name = Notification.Name(UUID().uuidString)
        var probe: LifetimeProbe? = LifetimeProbe()
        let weakProbe = WeakProbe(probe)
        let token = publisher(center, name).observe(receiving(try XCTUnwrap(probe)))
        probe = nil
        center.post(name: name, object: nil)
        try await waitFor { weakProbe.value?.deliveries == 1 }
        token.cancel()
        token.cancel()
        try await waitFor { weakProbe.value == nil }
        // The token remains alive, so release cannot be explained by dropping it.
        withExtendedLifetime(token) { XCTAssertNil(weakProbe.value) }
    }

    func testAlreadyQueuedCallbackCannotDeliverAfterCloseAndUnrelatedObserverSurvives() async throws {
        let center = NotificationCenter()
        let name = Notification.Name(UUID().uuidString)
        var deliveries = 0
        var unrelatedDeliveries = 0
        var probe: LifetimeProbe? = LifetimeProbe()
        let weakProbe = WeakProbe(probe)
        let resources = WorkbenchMotionResources(mode: .detached, publisher: publisher(center, name),
            receive: receiving(try XCTUnwrap(probe)) { deliveries += 1 })
        probe = nil
        let unrelated = publisher(center, name).observe { unrelatedDeliveries += 1 }
        defer { unrelated.cancel() }
        center.post(name: name, object: nil)
        // Posting synchronously queues delivery; do not yield until after close.
        resources.close()
        try await waitFor { weakProbe.value == nil && unrelatedDeliveries == 1 }
        XCTAssertEqual(deliveries, 0)
        center.post(name: name, object: nil)
        try await waitFor { unrelatedDeliveries == 2 }
        XCTAssertEqual(deliveries, 0)
    }

    func testSuccessfulScopeAwaitsShutdownBeforeRealClose() async throws {
        try await assertScopeCleanup(throwFromBody: false)
    }

    func testThrowingScopeAwaitsShutdownBeforeRealCloseAndPreservesError() async throws {
        try await assertScopeCleanup(throwFromBody: true)
    }

    private func assertScopeCleanup(throwFromBody: Bool) async throws {
        let retained = window()
        let center = NotificationCenter()
        let name = Notification.Name(UUID().uuidString)
        var order: [String] = []
        retained.onClose = { order.append("close") }
        var probe: LifetimeProbe? = LifetimeProbe()
        let weakProbe = WeakProbe(probe)
        let resources = WorkbenchMotionResources(mode: .invisibleWindow, publisher: publisher(center, name),
            makeWindow: { _ in retained }, receive: receiving(try XCTUnwrap(probe)))
        probe = nil
        let view = NSView(frame: retained.frame)
        resources.attach(view)
        do {
            try await resources.withCleanup(body: {
                order.append("body")
                if throwFromBody { throw Sentinel(description: "body error") }
            }, shutdown: {
                order.append("shutdown-start")
                await Task.yield()
                XCTAssertEqual(retained.closeCalls, 0)
                XCTAssertTrue(view.window === retained)
                order.append("shutdown-end")
            })
            XCTAssertFalse(throwFromBody)
        } catch let error as Sentinel {
            XCTAssertTrue(throwFromBody)
            XCTAssertEqual(error.description, "body error")
        }
        XCTAssertEqual(order, ["body", "shutdown-start", "shutdown-end", "close"])
        XCTAssertEqual(retained.closeCalls, 1)
        XCTAssertNil(view.window)
        XCTAssertNil(resources.window)
        XCTAssertNil(weakProbe.value)
        XCTAssertFalse(retained.isVisible || retained.isKeyWindow || retained.isMainWindow)
    }
}
