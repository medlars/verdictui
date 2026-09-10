import XCTest

@testable import VerdictUIWeb

final class CDPLiveIntegrationTests: XCTestCase {
    func testRealHeadlessBrowserAnswersCDP() async throws {
        let executable: URL
        do {
            executable = try BrowserLocator.locate(environment: [:])
        } catch let WebBrowserError.browserNotFound(channels) {
            throw XCTSkip("No browser binary found; searched: \(channels.joined(separator: ", "))")
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let profile = root.appendingPathComponent(".build/t2-live-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        // T1 opens this existing file for writing; it does not create the file.
        try Data().write(to: profile.appendingPathComponent(HeadlessBrowser.Options.stderrName))
        let browser = try await HeadlessBrowser.launch(.init(
            browser: executable, profileDirectory: profile, discoveryTimeout: 20))
        do {
            let endpoint = await browser.endpoint
            let transport = try CDPTransport(endpoint: endpoint)
            do {
                let version = try await transport.send(method: "Browser.getVersion", timeout: .seconds(10))
                guard case let .string(product) = version["product"], !product.isEmpty,
                    case let .string(protocolVersion) = version["protocolVersion"], !protocolVersion.isEmpty
                else { throw WebBrowserError.invalidCDPResponse(reason: "missing real browser version fields") }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                print("LIVE CDP Browser.getVersion: \(String(decoding: try encoder.encode(version), as: UTF8.self))")

                let targets = try await transport.send(method: "Target.getTargets", timeout: .seconds(10))
                guard case let .array(infos) = targets["targetInfos"] else {
                    throw WebBrowserError.invalidCDPResponse(reason: "missing targetInfos")
                }
                XCTAssertTrue(infos.contains { info in
                    guard case let .object(target) = info else { return false }
                    return target["type"] == .string("page") && target["url"] == .string("about:blank")
                }, "the real T1 about:blank page must be present")
                print("LIVE CDP Target.getTargets: \(String(decoding: try encoder.encode(targets), as: UTF8.self))")
                await transport.close()
            } catch {
                await transport.close()
                throw error
            }
            try await browser.terminate()
        } catch {
            try await browser.terminate()
            throw error
        }
    }
}
