import Foundation
import XCTest
@testable import VerdictUIWorkbenchCore

final class WorkbenchResourcesTests: XCTestCase {
    private func fixture(_ relative: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let bundle = root.appendingPathComponent("Workbench.bundle")
        let assets = bundle.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Workbench</title>".utf8).write(to: assets.appendingPathComponent("index.html"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (bundle, assets)
    }

    func testFlatBundleUsesOneResourcesDirectory() throws {
        let (bundle, assets) = try fixture("Resources")
        XCTAssertEqual(try WorkbenchResources.directory(in: bundle).path, assets.path)
    }

    func testNestedBundleUsesCopiedDirectory() throws {
        let (bundle, assets) = try fixture("Contents/Resources/Resources")
        XCTAssertEqual(try WorkbenchResources.directory(in: bundle).path, assets.path)
    }

    func testAmbiguousBundleIsRefused() throws {
        let (bundle, _) = try fixture("Resources")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources/Resources"),
                                               withIntermediateDirectories: true)
        XCTAssertThrowsError(try WorkbenchResources.directory(in: bundle))
    }

    func testRedirectedAncestorIsRefused() throws {
        let (bundle, assets) = try fixture("Resources")
        let saved = bundle.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: assets, to: saved)
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: saved)
        XCTAssertThrowsError(try WorkbenchResources.directory(in: bundle))
    }

    func testRegularFileCannotServeAsResourceDirectory() throws {
        let (bundle, assets) = try fixture("Resources")
        try FileManager.default.removeItem(at: assets)
        try Data("not a directory".utf8).write(to: assets)
        XCTAssertThrowsError(try WorkbenchResources.directory(in: bundle))
    }

    func testMissingPageIsRefused() throws {
        let (bundle, assets) = try fixture("Resources")
        try FileManager.default.removeItem(at: assets.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try WorkbenchResources.directory(in: bundle))
    }

    func testRedirectedPageIsRefused() throws {
        let (bundle, assets) = try fixture("Resources")
        let page = assets.appendingPathComponent("index.html")
        let saved = assets.appendingPathComponent("saved.html")
        try FileManager.default.moveItem(at: page, to: saved)
        try FileManager.default.createSymbolicLink(at: page, withDestinationURL: saved)
        XCTAssertThrowsError(try WorkbenchResources.directory(in: bundle))
    }
}
