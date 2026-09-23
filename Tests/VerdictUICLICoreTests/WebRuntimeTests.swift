import XCTest
import VerdictUIWeb
@testable import VerdictUICLICore

final class WebRuntimeTests: XCTestCase {
    func testMCPRejectsWrongTypesWithoutCoercion() {
        for field in ["profile", "url", "action", "node", "text", "credential", "key", "modifiers", "expect_text"] {
            XCTAssertThrowsError(try ExtendedMCP.webRequest([field: .bool(true)]))
        }
        XCTAssertEqual(try ExtendedMCP.webRequest([:]).profile, "default")
    }

    func testCredentialAndActionBoundaries() {
        for request in [WebRequest(action: "type", text: "x"),
                        WebRequest(action: "type", node: "x", text: "x", credential: "secret"),
                        WebRequest(action: "credential", node: "x"),
                        WebRequest(action: "credential", node: "x", text: "secret", credential: "key"),
                        WebRequest(action: "key"), WebRequest(action: "unknown")] {
            XCTAssertThrowsError(try WebRuntime.action(request))
        }
        XCTAssertNoThrow(try WebRuntime.action(WebRequest(action: "credential", node: "x", credential: "key")))
        XCTAssertNoThrow(try WebRuntime.action(WebRequest(action: "type", node: "x", text: "hello")))
        XCTAssertNoThrow(try WebRuntime.action(WebRequest(action: "click", node: "x")))
        XCTAssertNoThrow(try WebRuntime.action(WebRequest(action: "submit", node: "x")))
        XCTAssertNoThrow(try WebRuntime.action(WebRequest(action: "key", key: "Enter")))
    }

    @MainActor
    func testMissingBrowserSessionIsUnavailableNeverPassing() async {
        let engine = CommandEnvironment.standard().engine
        let response = await VerdictDaemon.handle(DaemonRequest(method: "web_verify", web: WebRequest(profile: "absent")), engine: engine)
        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.findings?.first?.rule, "web-unavailable")
    }
}
