import Foundation
import VerdictUIKernel

/// DOMSnapshot records a wrapped inline element's union, not its border fragments.
/// Read native Element client rects in an isolated world; never substitute text
/// descendants (which omit padding, borders, empty boxes and replaced content).
/// https://www.w3.org/TR/cssom-view/#dom-element-getclientrects
enum WebInlineGeometry {
    typealias Command = @Sendable (String, [String: CDPValue], Duration) async throws -> [String: CDPValue]

    struct Budget {
        var candidates = 4096
        var fragments = 100_000
        let deadline: ContinuousClock.Instant
        init(deadline: ContinuousClock.Instant = .now + WebTiming.current.captureDeadline) { self.deadline = deadline }
        mutating func reserveCandidates(_ count: Int) throws {
            guard count >= 0, count <= candidates else { throw unavailable("inline element limit exceeded") }
            candidates -= count
        }
        mutating func reserveFragments(_ count: Int) throws {
            guard count >= 0, count <= fragments else { throw unavailable("inline fragment limit exceeded") }
            fragments -= count
        }
        func timeout() throws -> Duration {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw unavailable("inline geometry capture deadline exceeded") }
            return min(remaining, WebTiming.current.requestCap)
        }
    }

    // Fixed source, no page/user strings interpolated. The isolated realm's
    // prototypes are not replaceable by scripts in the page's main world.
    static let reader = """
    function(limit, ...elements) {
      const read = Element.prototype.getClientRects;
      const rows = [];
      let remaining = limit;
      for (const element of elements) {
        if (!(element instanceof Element) || !element.isConnected) throw new Error('inline node detached');
        if (!(element instanceof HTMLElement)) { rows.push(null); continue; }
        if (getComputedStyle(element).display !== 'inline') throw new Error('inline display changed');
        const rects = read.call(element);
        if (!rects.length || rects.length > remaining) throw new Error('inline fragment limit exceeded');
        remaining -= rects.length;
        rows.push(Array.from(rects, r => [r.x, r.y, r.width, r.height]));
      }
      return rows;
    }
    """

    static func enrich(_ payload: [String: CDPValue], viewport: Rect, budget: inout Budget,
                       command: @escaping Command) async throws -> [String: CDPValue] {
        // Validate the full columnar snapshot before using any identity for CDP.
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        let candidates = tree.flattened().filter { $0.attributes["web.inlineCandidate"] == .bool(true) }
        try budget.reserveCandidates(candidates.count)
        var byFrame: [String: [Int64]] = [:]
        for node in candidates {
            guard let frame = node.attributes["web.frame"]?.stringValue,
                  let raw = node.attributes["web.backendID"]?.numberValue, let id = Int64(exactly: raw) else {
                throw unavailable("invalid inline node identity")
            }
            byFrame[frame, default: []].append(id)
        }
        var result = payload
        guard case var .array(documents) = payload["documents"], case let .array(strings) = payload["strings"] else {
            throw unavailable("invalid inline document inventory")
        }
        for index in documents.indices {
            guard case var .object(document) = documents[index],
                  let rawFrame = document["frameId"]?.doubleValue, let frameIndex = Int(exactly: rawFrame),
                  strings.indices.contains(frameIndex), let frame = strings[frameIndex].stringValue else {
                throw unavailable("missing inline document frame identity")
            }
            let ids = byFrame[frame] ?? []
            let records = try await collect(ids: ids, frame: frame, budget: &budget, command: command)
            document["verdictInlineFragments"] = .object(records)
            documents[index] = .object(document)
        }
        result["documents"] = .array(documents)
        return result
    }

    static func collect(ids: [Int64], frame: String, budget: inout Budget,
                        command: @escaping Command) async throws -> [String: CDPValue] {
        guard !ids.isEmpty else { return [:] }
        let world = try await command("Page.createIsolatedWorld", ["frameId": .string(frame),
            "worldName": .string("VerdictUI inline border measurements")], try budget.timeout())
        guard case let .integer(context) = world["executionContextId"], context > 0 else {
            throw unavailable("missing inline isolated context")
        }
        let group = "verdictui-inline-" + UUID().uuidString
        var records: [String: CDPValue] = [:]
        do {
            // At most 64 concurrent resolutions; one native reader call per batch.
            for start in stride(from: 0, to: ids.count, by: 64) {
                let batch = Array(ids[start..<min(start + 64, ids.count)])
                let timeout = try budget.timeout()
                let references = try await withThrowingTaskGroup(of: (Int, String).self) { tasks in
                    for (offset, id) in batch.enumerated() {
                        tasks.addTask {
                            let resolved = try await command("DOM.resolveNode", ["backendNodeId": .integer(id),
                                "executionContextId": .integer(context), "objectGroup": .string(group)], timeout)
                            guard case let .object(object) = resolved["object"], let objectID = object["objectId"]?.stringValue,
                                  !objectID.isEmpty else { throw unavailable("inline node resolution failed") }
                            return (offset, objectID)
                        }
                    }
                    var references = Array(repeating: "", count: batch.count)
                    for try await (offset, objectID) in tasks { references[offset] = objectID }
                    return references
                }
                let arguments: [CDPValue] = [.object(["value": .integer(Int64(budget.fragments))])]
                    + references.map { .object(["objectId": .string($0)]) }
                let response = try await command("Runtime.callFunctionOn", ["functionDeclaration": .string(reader),
                    "executionContextId": .integer(context), "arguments": .array(arguments),
                    "returnByValue": .bool(true), "objectGroup": .string(group)], try budget.timeout())
                guard response["exceptionDetails"] == nil,
                      case let .object(returned) = response["result"], case let .array(rows) = returned["value"],
                      rows.count == batch.count else { throw unavailable("incomplete inline border measurement") }
                for (offset, row) in rows.enumerated() {
                    if row != .null {
                        guard case let .array(rects) = row, !rects.isEmpty else { throw unavailable("missing inline border fragments") }
                        try budget.reserveFragments(rects.count)
                    }
                    records[String(batch[offset])] = row
                }
            }
            _ = try budget.timeout()
        } catch {
            try await release(group, command: command)
            throw error
        }
        try await release(group, command: command)
        return records
    }

    private static func release(_ group: String, command: @escaping Command) async throws {
        // Cancellation must not skip release of already-resolved remote objects.
        _ = try await Task.detached {
            try await command("Runtime.releaseObjectGroup", ["objectGroup": .string(group)], .seconds(1))
        }.value
    }

    private static func unavailable(_ reason: String) -> WebBrowserError {
        .invalidCDPResponse(reason: "inline border geometry: " + reason)
    }
}
