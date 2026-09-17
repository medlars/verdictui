import XCTest

@testable import VerdictUIWeb

final class ProfileRegistryTests: XCTestCase {
    private func tempRegistry() -> ProfileRegistry {
        ProfileRegistry(
            root: URL(fileURLWithPath: NSTemporaryDirectory() + "vui-t1-\(UUID().uuidString)"))
    }

    func testProfileAndLockPathsLiveUnderTheRoot() {
        let registry = tempRegistry()
        XCTAssertEqual(
            registry.profileDirectory(for: "work").path.hasSuffix(
                "/work"),
            true,
            registry.profileDirectory(for: "work").path)
        XCTAssertEqual(
            registry.lockPath(for: "work").path.hasSuffix("/locks/work.lock"),
            true,
            registry.lockPath(for: "work").path)
    }

    func testDefaultRootIsTheAppSupportPath() {
        let root = ProfileRegistry.defaultRoot(home: "/Users/x")
        XCTAssertEqual(
            root.path,
            "/Users/x/Library/Application Support/VerdictUI/web-profiles")
    }

    func testMakeProfileDirectoryCreatesTheDirectoryIdempotently() throws {
        let registry = tempRegistry()
        defer { try? FileManager.default.removeItem(at: registry.root) }
        let dir = try registry.makeProfileDirectory(named: "work")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        _ = try registry.makeProfileDirectory(named: "work")
    }

    func testTraversalNamesAreRefused() {
        let registry = tempRegistry()
        for bad in ["../escape", "a/b", "..", ".", ""] {
            XCTAssertThrowsError(try registry.makeProfileDirectory(named: bad)) { error in
                guard case WebBrowserError.invalidProfileName = error else {
                    return XCTFail("wrong error: \(error)")
                }
            }
        }
    }
}
