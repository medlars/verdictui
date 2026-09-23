import Foundation
import XCTest
import WebKit
import VerdictUICLICore
@testable import VerdictUIWorkbenchCore

final class WorkbenchStoreTests: XCTestCase {
    @MainActor
    private final class SilentBridge: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    @MainActor
    func testPaintReviewCannotAppearAsAnUnqualifiedPassInRenderedWorkbench() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(SilentBridge(), name: "verdictui")
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/VerdictUIWorkbench/Resources")
        view.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        func evaluate(_ script: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                view.evaluateJavaScript(script) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await evaluate("typeof window.verdictui") == "object" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ready = try await evaluate("typeof window.verdictui")
        XCTAssertEqual(ready, "object", "the real bundled workbench must load")
        _ = try await evaluate("window.verdictui.receive({type:'state',projects:[],selectedProject:'/tmp/paint-check',checks:[],history:[],version:'fixture'}); 'ok'")
        for (status, uncertain) in [("pass", true), ("fail", true), ("pass", false)] {
            let findings: [[String: String]] = uncertain ? [["rule": "web-paint-unverified", "severity": "warning", "nodeID": "web/overlay", "message": "Occlusion unverified"]] : []
            let report: [String: Any] = ["status": status, "checks": [["name": "Home", "status": status, "verdict": ["findings": findings]]]]
            let data = try JSONSerialization.data(withJSONObject: ["type": "result", "report": report])
            let json = String(decoding: data, as: UTF8.self)
            _ = try await evaluate("window.verdictui.receive(\(json)); 'ok'")
            let stage = try await evaluate("document.getElementById('verification-stage').dataset.status")
            XCTAssertEqual(stage, status == "pass" && uncertain ? "unavailable" : status)
            let label = try await evaluate("document.getElementById('status-label').textContent")
            XCTAssertEqual(label.contains("Paint unverified"), status == "pass" && uncertain)
            let chip = try await evaluate("document.querySelector('.check-chip').textContent")
            XCTAssertEqual(chip.contains("paint unverified"), status == "pass" && uncertain)
            let history: [String: Any] = ["type": "state", "projects": [], "selectedProject": "/tmp/paint-check", "checks": [], "history": [["project": "/tmp/paint-check", "timestamp": "2026-09-23T12:00:00Z", "report": report]]]
            let historyJSON = String(decoding: try JSONSerialization.data(withJSONObject: history), as: UTF8.self)
            _ = try await evaluate("window.verdictui.receive(\(historyJSON)); 'ok'")
            let badge = try await evaluate("document.querySelector('.history-row .severity').textContent")
            XCTAssertEqual(badge, status == "pass" && uncertain ? "paint review" : status)
        }
        configuration.userContentController.removeScriptMessageHandler(forName: "verdictui")
        view.stopLoading()
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    func testBridgeAcceptsOnlyTheBundledLocalMainFrame() throws {
        let root = try temporary()
        let page = root.appendingPathComponent("index.html")
        let bridge = WorkbenchBridge(store: WorkbenchStore(stateURL: root.appendingPathComponent("state.json")),
                                     executable: root.appendingPathComponent("verdictui"), page: page)
        XCTAssertTrue(bridge.allowsPage(page, isMainFrame: true))
        XCTAssertFalse(bridge.allowsPage(page, isMainFrame: false))
        XCTAssertFalse(bridge.allowsPage(nil, isMainFrame: true))
        XCTAssertFalse(bridge.allowsPage(root.appendingPathComponent("other.html"), isMainFrame: true))
        XCTAssertFalse(bridge.allowsPage(URL(string: "https://example.test" + page.path), isMainFrame: true))
        XCTAssertFalse(bridge.allowsPage(URL(string: "file://example.test" + page.path), isMainFrame: true))
        XCTAssertFalse(bridge.allowsPage(URL(string: page.absoluteString + "?injected=1"), isMainFrame: true))
    }

    @MainActor
    func testProjectAndChecksPersistAcrossWebViewLifetimes() throws {
        let root = try temporary()
        let file = root.appendingPathComponent("state.json")
        let store = WorkbenchStore(stateURL: file)
        XCTAssertNil(store.selectedProject)
        try store.addProject(root)
        try store.addProject(root)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertNil(try store.checks())
        try store.saveChecks(Data(#"{"checks":[{"name":"site","kind":"web","url":"https://example.test"}]}"#.utf8))
        let reopened = WorkbenchStore(stateURL: file)
        XCTAssertEqual(reopened.selectedProject, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(try reopened.checks()?.checks.first?.name, "site")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testUnselectedAndMalformedConfigurationCannotWrite() throws {
        let root = try temporary()
        let store = WorkbenchStore(stateURL: root.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try store.select(root.path))
        XCTAssertThrowsError(try store.saveChecks(Data()))
        XCTAssertThrowsError(try store.addProject(root.appendingPathComponent("absent")))
        try store.addProject(root)
        XCTAssertThrowsError(try store.saveChecks(Data(#"{"checks":[]}"#.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".verdictui/checks.json").path))
    }

    @MainActor
    func testHistoryIsBoundedAndMalformedSavedStateIsVisible() throws {
        let root = try temporary()
        let file = root.appendingPathComponent("state.json")
        try Data("broken".utf8).write(to: file)
        let store = WorkbenchStore(stateURL: file)
        XCTAssertNotNil(store.loadError)
        let report = try JSONDecoder().decode(ProjectCheckReport.self,
            from: Data(#"{"status":"unavailable","checks":[],"error":"not configured"}"#.utf8))
        for _ in 0..<25 { try store.record(report, project: root.path) }
        XCTAssertEqual(store.history.count, 20)
        XCTAssertEqual(WorkbenchStore(stateURL: file).history.count, 20)
        XCTAssertEqual(store.history.first?.status, "unavailable")
    }
}
