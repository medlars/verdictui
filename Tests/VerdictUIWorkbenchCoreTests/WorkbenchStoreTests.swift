import Foundation
import XCTest
import VerdictUICLICore
@testable import VerdictUIWorkbenchCore

final class WorkbenchStoreTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
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
