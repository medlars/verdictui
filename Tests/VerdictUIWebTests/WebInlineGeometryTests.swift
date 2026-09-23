import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

private actor InlineCommands {
    var methods: [String] = []
    var failure: String?
    var automaticRows = false
    var pauseReader = false
    var readerStarted = false
    var releaseWasCancelled = false
    var activeResolutions = 0
    var maximumResolutions = 0
    var invalidContext = false
    var incompleteNode = false
    var scriptException = false
    var rows: [CDPValue]
    init(rows: [CDPValue] = [.array([.array([0, 0, 40, 20].map { .integer(Int64($0)) })])], failure: String? = nil) {
        self.rows = rows; self.failure = failure
    }
    func configure(automaticRows: Bool = false, pauseReader: Bool = false) {
        self.automaticRows = automaticRows; self.pauseReader = pauseReader
    }
    func inject(_ kind: String) {
        invalidContext = kind == "context"; incompleteNode = kind == "node"; scriptException = kind == "exception"
    }
    func call(_ method: String, _ params: [String: CDPValue], _ timeout: Duration) async throws -> [String: CDPValue] {
        methods.append(method)
        if failure == method { throw WebBrowserError.invalidCDPResponse(reason: "injected reader failure") }
        switch method {
        case "Page.createIsolatedWorld":
            XCTAssertNil(params["grantUniveralAccess"])
            return ["executionContextId": .integer(invalidContext ? -1 : 7)]
        case "DOM.resolveNode":
            activeResolutions += 1; maximumResolutions = max(maximumResolutions, activeResolutions)
            try await Task.sleep(for: .milliseconds(1))
            activeResolutions -= 1
            XCTAssertEqual(params["executionContextId"], .integer(7))
            XCTAssertNotNil(params["backendNodeId"])
            XCTAssertNotNil(params["objectGroup"])
            return ["object": .object(["objectId": .string(incompleteNode ? "" : "owned-node")])]
        case "Runtime.callFunctionOn":
            XCTAssertEqual(params["functionDeclaration"], .string(WebInlineGeometry.reader))
            XCTAssertEqual(params["returnByValue"], .bool(true))
            readerStarted = true
            if pauseReader { try await Task.sleep(for: .seconds(10)) }
            if automaticRows, case let .array(arguments) = params["arguments"] {
                return ["result": .object(["value": .array(Array(repeating: rows[0], count: arguments.count - 1))])]
            }
            return scriptException ? ["exceptionDetails": .object([:]), "result": .object(["value": .array(rows)])] : ["result": .object(["value": .array(rows)])]
        case "Runtime.releaseObjectGroup": releaseWasCancelled = Task.isCancelled; return [:]
        default: XCTFail("unexpected command \(method)"); return [:]
        }
    }
}

final class WebInlineGeometryTests: XCTestCase {
    func testCollectionUsesExactNodesAndReleasesObjectsOnSuccessAndEveryFailure() async throws {
        for failure in [nil, "DOM.resolveNode", "Runtime.callFunctionOn"] {
            let commands = InlineCommands(failure: failure)
            var budget = WebInlineGeometry.Budget()
            do {
                let rows = try await WebInlineGeometry.collect(ids: [42], frame: "frame", budget: &budget, command: { try await commands.call($0, $1, $2) })
                XCTAssertNil(failure)
                XCTAssertNotNil(rows["42"])
                XCTAssertEqual(budget.fragments, 99_999)
            } catch { XCTAssertNotNil(failure, "\(error)") }
            let methods = await commands.methods
            XCTAssertEqual(methods.last, "Runtime.releaseObjectGroup")
            XCTAssertEqual(methods.filter { $0 == "Runtime.releaseObjectGroup" }.count, 1)
        }
    }

    func testIncompleteAndOversizedMeasurementsFailWithoutPartialRecords() async throws {
        for rows: [CDPValue] in [[], [.array([])], [.array([.array([]), .array([])])]] {
            let commands = InlineCommands(rows: rows)
            var budget = WebInlineGeometry.Budget(); budget.fragments = 1
            do {
                _ = try await WebInlineGeometry.collect(ids: [42], frame: "frame", budget: &budget, command: { try await commands.call($0, $1, $2) })
                XCTFail("missing or oversized measurements cannot succeed")
            } catch { XCTAssertTrue(String(describing: error).contains("inline")) }
            let methods = await commands.methods
            XCTAssertEqual(methods.last, "Runtime.releaseObjectGroup")
        }
    }

    func testInvalidRemoteContextNodeAndScriptExceptionRemainUnavailable() async throws {
        for kind in ["context", "node", "exception"] {
            let commands = InlineCommands(); await commands.inject(kind)
            var budget = WebInlineGeometry.Budget()
            do {
                _ = try await WebInlineGeometry.collect(ids: [42], frame: "frame", budget: &budget,
                    command: { try await commands.call($0, $1, $2) })
                XCTFail("incomplete remote identity or exception must fail: \(kind)")
            } catch { XCTAssertTrue(String(describing: error).contains("inline")) }
            let methods = await commands.methods
            if kind != "context" { XCTAssertEqual(methods.last, "Runtime.releaseObjectGroup") }
        }
    }

    func testResolutionBatchesAreBoundedAndCancellationStillReleasesObjects() async throws {
        let commands = InlineCommands(); await commands.configure(automaticRows: true)
        var budget = WebInlineGeometry.Budget()
        let ids = (1...130).map(Int64.init)
        let records = try await WebInlineGeometry.collect(ids: ids, frame: "frame", budget: &budget,
            command: { try await commands.call($0, $1, $2) })
        XCTAssertEqual(Set(records.keys), Set(ids.map(String.init)))
        let methods = await commands.methods, maximum = await commands.maximumResolutions
        XCTAssertEqual(methods.filter { $0 == "Runtime.callFunctionOn" }.count, 3)
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 64)
        let cancelled = InlineCommands(); await cancelled.configure(pauseReader: true)
        let task = Task {
            var budget = WebInlineGeometry.Budget()
            return try await WebInlineGeometry.collect(ids: [42], frame: "frame", budget: &budget,
                command: { try await cancelled.call($0, $1, $2) })
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await cancelled.readerStarted), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let started = await cancelled.readerStarted
        XCTAssertTrue(started)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled measurement must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelledMethods = await cancelled.methods, cancelledRelease = await cancelled.releaseWasCancelled
        XCTAssertEqual(cancelledMethods.last, "Runtime.releaseObjectGroup")
        XCTAssertFalse(cancelledRelease, "remote release must survive caller cancellation")
    }

    func testNonHTMLIsExplicitAndBudgetsAreGlobalAndDeadlineBounded() async throws {
        let commands = InlineCommands(rows: [.null])
        var budget = WebInlineGeometry.Budget()
        let rows = try await WebInlineGeometry.collect(ids: [42], frame: "frame", budget: &budget, command: { try await commands.call($0, $1, $2) })
        XCTAssertEqual(rows["42"], .null)
        XCTAssertEqual(budget.fragments, 100_000)
        try budget.reserveCandidates(4095); try budget.reserveCandidates(1)
        XCTAssertThrowsError(try budget.reserveCandidates(1))
        try budget.reserveFragments(99_999); try budget.reserveFragments(1)
        XCTAssertThrowsError(try budget.reserveFragments(1))
        XCTAssertThrowsError(try WebInlineGeometry.Budget(deadline: .now - .seconds(1)).timeout())
    }
}
