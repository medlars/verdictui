import XCTest
@testable import VerdictUIWeb

final class WebCredentialsTests: XCTestCase {
    func testReferenceResolutionDoesNotTreatReferenceAsSecret() async throws {
        let value = UUID().uuidString
        let resolver = WebCredentials(environment: ["VERDICTUI_WEB_CRED_TEST": value])
        let resolved = try await resolver.resolve("test")
        XCTAssertEqual(resolved, value)
        for reference in ["", "literal-password!", "../escape", "op://unconfigured/item/password"] {
            do { _ = try await WebCredentials(environment: [:], onePassword: URL(fileURLWithPath: "/does/not/exist")).resolve(reference)
                XCTFail("accepted unavailable credential")
            } catch { XCTAssertEqual(error as? WebBrowserError, .credentialUnavailable) }
        }
    }

    func testSharedFileFallbackAndOnePasswordReferencePrecedence() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let value = UUID().uuidString
        try "export VERDICTUI_WEB_CRED_TEST='\(value)'\n".write(to: file, atomically: true, encoding: .utf8)
        let resolver = WebCredentials(environment: [:], sharedFile: file)
        let resolved = try await resolver.resolve("test")
        XCTAssertEqual(resolved, value)
        let refResolver = WebCredentials(environment: ["VERDICTUI_WEB_CRED_TEST": "op://vault/item/password"],
                                        sharedFile: file, onePassword: URL(fileURLWithPath: "/does/not/exist"))
        do { _ = try await refResolver.resolve("test"); XCTFail("silently fell back from configured 1Password reference") }
        catch { XCTAssertEqual(error as? WebBrowserError, .credentialUnavailable) }
    }
}
