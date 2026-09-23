import XCTest
@testable import VerdictUIWeb

final class WebCredentialsTests: XCTestCase {
    func testReferenceResolutionDoesNotTreatReferenceAsSecret() async throws {
        let value = UUID().uuidString
        let resolver = WebCredentials(environment: ["VERDICTUI_WEB_CRED_TEST": value], onePassword: nil)
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
        let resolver = WebCredentials(environment: [:], sharedFile: file, onePassword: nil)
        let resolved = try await resolver.resolve("test")
        XCTAssertEqual(resolved, value)
        let refResolver = WebCredentials(environment: ["VERDICTUI_WEB_CRED_TEST": "op://vault/item/password"],
                                        sharedFile: file, onePassword: URL(fileURLWithPath: "/does/not/exist"))
        do { _ = try await refResolver.resolve("test"); XCTFail("silently fell back from configured 1Password reference") }
        catch { XCTAssertEqual(error as? WebBrowserError, .credentialUnavailable) }
    }
    func testOnePasswordNamedItemWinsBeforeSharedFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("op")
        try "#!/bin/sh\nprintf '%s' \"$TEST_OP_VALUE\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let first = UUID().uuidString
        let fallback = UUID().uuidString
        let resolver = WebCredentials(environment: ["TEST_OP_VALUE": first, "VERDICTUI_WEB_CRED_TEST": fallback], onePassword: executable)
        let value = try await resolver.resolve("test")
        XCTAssertEqual(value, first)
        let failed = WebCredentials(environment: ["VERDICTUI_WEB_CRED_TEST": fallback], onePassword: URL(fileURLWithPath: "/nonexistent"))
        let recovered = try await failed.resolve("test")
        XCTAssertEqual(recovered, fallback)
    }

}
