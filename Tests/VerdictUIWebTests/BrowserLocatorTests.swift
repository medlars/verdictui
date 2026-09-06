import XCTest

@testable import VerdictUIWeb

/// Discovery: override wins, table order, fail-closed when absent.
final class BrowserLocatorTests: XCTestCase {
    func testTheOverrideWinsWhenTheBinaryExists() throws {
        let url = try BrowserLocator.locate(
            environment: ["VERDICTUI_WEB_BROWSER": "/bin/echo"],
            channels: [],
            fileExists: { _ in true })
        XCTAssertEqual(url.path, "/bin/echo")
    }

    func testAMissingOverrideFailsClosedWithoutFallingBack() {
        XCTAssertThrowsError(
            try BrowserLocator.locate(
                environment: ["VERDICTUI_WEB_BROWSER": "/no/such/browser"],
                channels: [BrowserLocator.Channel(name: "present", path: "/bin/echo")],
                fileExists: { path in path != "/no/such/browser" })
        ) { error in
            guard case WebBrowserError.overrideNotExecutable(let path) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(path, "/no/such/browser")
        }
    }

    func testTheTableOrderIsHonored() throws {
        let url = try BrowserLocator.locate(
            environment: [:],
            channels: [
                BrowserLocator.Channel(name: "first", path: "/bin/echo"),
                BrowserLocator.Channel(name: "second", path: "/bin/test"),
            ],
            fileExists: { _ in true })
        XCTAssertEqual(url.path, "/bin/echo")
    }

    func testAbsentEverywhereFailsClosedNamingTheChannels() {
        XCTAssertThrowsError(
            try BrowserLocator.locate(
                environment: [:],
                channels: [
                    BrowserLocator.Channel(name: "chrome-stable", path: "/nope"),
                    BrowserLocator.Channel(name: "chromium", path: "/nada"),
                ],
                fileExists: { _ in false })
        ) { error in
            guard case WebBrowserError.browserNotFound(let channels) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(channels, ["chrome-stable", "chromium"])
        }
    }

    /// The real machine: whatever the search table finds must be a real
    /// executable. Skips with an explicit marker when no browser is
    /// installed — "browser not installed — unverified", never a silent pass.
    func testTheRealMachineFindsAnExecutableBrowser() throws {
        let channels = BrowserLocator.candidateChannels
        let installed = channels.contains {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
        try XCTSkipIf(!installed, "browser not installed — unverified")
        let url = try BrowserLocator.locate()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: url.path),
            "located \(url.path) is not executable")
    }
}
