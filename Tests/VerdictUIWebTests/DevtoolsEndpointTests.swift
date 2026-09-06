import XCTest

@testable import VerdictUIWeb

/// The DevToolsActivePort parse contract, tested pure.
final class DevtoolsEndpointTests: XCTestCase {
    func testATwoLineFileParsesToPortAndPath() throws {
        let endpoint = try DevtoolsEndpoint.parse("49668\n/devtools/browser/5f4e10aa")
        XCTAssertEqual(endpoint.port, 49668)
        XCTAssertEqual(endpoint.browserPath, "/devtools/browser/5f4e10aa")
        XCTAssertEqual(
            endpoint.httpOrigin, "http://127.0.0.1:49668")
        XCTAssertEqual(
            endpoint.websocketURL,
            "ws://127.0.0.1:49668/devtools/browser/5f4e10aa")
    }

    func testThePortMustBeAUsableTCPPort() {
        for bad in ["0", "65536", "70000", "", "abc", "-5"] {
            XCTAssertThrowsError(try DevtoolsEndpoint.parse(bad)) { error in
                guard case WebBrowserError.invalidDevtoolsPort = error else {
                    return XCTFail("wrong error: \(error)")
                }
            }
        }
    }

    func testAOneLineFileStillParsesWithoutABrowserPath() throws {
        let endpoint = try DevtoolsEndpoint.parse("8080\n")
        XCTAssertEqual(endpoint.port, 8080)
        XCTAssertEqual(endpoint.browserPath, "")
    }

    func testReadReturnsNilForAMissingFile() throws {
        let dir = NSTemporaryDirectory() + "vui-t1-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dirURL = URL(fileURLWithPath: dir)
        XCTAssertNil(DevtoolsEndpoint.read(in: dirURL))
    }

    func testReadParsesAWrittenFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "vui-t1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "4001\n/devtools/browser/x".write(
            to: dir.appendingPathComponent("DevToolsActivePort"),
            atomically: true, encoding: .utf8)
        let endpoint = try XCTUnwrap(DevtoolsEndpoint.read(in: dir))
        XCTAssertEqual(endpoint.port, 4001)
    }
}
