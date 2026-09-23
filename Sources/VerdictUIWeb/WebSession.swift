import Foundation
import VerdictUIKernel

public struct WebSessionInfo: Codable, Equatable, Sendable {
    public let profile: String
    public let pid: Int32
    /// Auth, query and fragment are removed before this crosses the boundary.
    public let url: String
}

public enum WebAction: Sendable {
    case click(nodeID: String)
    case type(nodeID: String, text: String)
    case credential(nodeID: String, reference: String)
    case key(nodeID: String?, key: String, modifiers: [String])
    case submit(nodeID: String)
}

/// A warm browser owned by one profile lock. Public operations reject concurrent
/// commands for the same identity rather than interleaving navigation and input.
/// Distinct WebSession actors run independently.
public actor WebSession {
    let profile: String
    let browser: HeadlessBrowser
    let transport: CDPTransport
    let pageSessionID: String
    private let lock: ProfileLock
    private let credentials: WebCredentials
    private let viewport: Rect
    private var currentURL: URL
    private var secrets: [String] = []
    private var frameSessions: [String: String] = [:]
    private var remoteSessions: [String: String] = [:]
    private var busy = false
    private var closed = false

    private init(profile: String, browser: HeadlessBrowser, transport: CDPTransport,
                 pageSessionID: String, lock: ProfileLock, credentials: WebCredentials,
                 viewport: Rect, url: URL) {
        self.profile = profile; self.browser = browser; self.transport = transport
        self.pageSessionID = pageSessionID; self.lock = lock; self.credentials = credentials
        self.viewport = viewport; currentURL = url
    }

    static func open(profile: String, url: URL, registry: ProfileRegistry,
                     environment: [String: String], width: Int, height: Int) async throws -> WebSession {
        try validateURL(url)
        guard (100...8192).contains(width), (100...8192).contains(height) else {
            throw WebBrowserError.invalidWebOperation(reason: "viewport must be 100...8192 CSS pixels")
        }
        let lock = try ProfileLock.acquire(profile: profile, registry: registry)
        var browser: HeadlessBrowser?
        var transport: CDPTransport?
        do {
            let directory = try registry.makeProfileDirectory(named: profile)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let launched = try await HeadlessBrowser.launch(.init(
                browser: BrowserLocator.locate(environment: environment), profileDirectory: directory))
            browser = launched
            let connection = try CDPTransport(endpoint: launched.endpoint)
            transport = connection
            let targets = try await connection.send(method: "Target.getTargets")
            guard case let .array(infos) = targets["targetInfos"],
                let target = infos.compactMap({ value -> [String: CDPValue]? in
                    if case let .object(info) = value, info["type"] == .string("page") { return info }
                    return nil
                }).first,
                let targetID = target["targetId"]?.stringValue else {
                throw WebBrowserError.invalidCDPResponse(reason: "browser has no page target")
            }
            let attached = try await connection.send(method: "Target.attachToTarget", params: [
                "targetId": .string(targetID), "flatten": .bool(true)])
            guard let sessionID = attached["sessionId"]?.stringValue, !sessionID.isEmpty else {
                throw WebBrowserError.invalidCDPResponse(reason: "no page session identifier")
            }
            let session = WebSession(profile: profile, browser: launched, transport: connection,
                                     pageSessionID: sessionID, lock: lock,
                                     credentials: WebCredentials(environment: environment),
                                     viewport: Rect(x: 0, y: 0, width: Double(width), height: Double(height)), url: url)
            _ = try await session.command("Page.enable")
            await connection.setNetworkRootFrame(targetID, sessionID: sessionID)
            _ = try await session.command("Network.enable")
            _ = try await session.command("Emulation.setDeviceMetricsOverride", [
                "width": .integer(Int64(width)), "height": .integer(Int64(height)),
                "deviceScaleFactor": .number(1), "mobile": .bool(false)])
            try await session.navigate(url: url)
            return session
        } catch {
            if let transport { await transport.close() }
            if let browser {
                do { try await browser.terminate(grace: 1) }
                catch { throw error } // Retain the lock if the process refuses death.
            }
            lock.release()
            throw sanitized(error)
        }
    }

    public func info() async -> WebSessionInfo {
        WebSessionInfo(profile: profile, pid: browser.pid,
                       url: WebRedaction.clean(WebRedaction.safeURL(currentURL), secrets: secrets))
    }

    /// A dead child cannot become live again. Retire its transport and lock
    /// before the manager exposes or reopens this profile.
    func isAvailable() async -> Bool {
        guard !closed else { return false }
        guard await browser.isRunning() else {
            closed = true
            await transport.close()
            lock.release()
            secrets.removeAll()
            return false
        }
        return !closed
    }

    public func navigate(url: URL) async throws {
        try begin()
        defer { busy = false }
        do {
            try Self.validateURL(url)
            let result = try await command("Page.navigate", ["url": .string(url.absoluteString)])
            guard result["errorText"] == nil else {
                throw WebBrowserError.invalidWebOperation(reason: "browser rejected navigation")
            }
            currentURL = url
            _ = try await settledTree()
        } catch { try await handle(error) }
    }

    public func render() async throws -> SemanticNode {
        try begin()
        defer { busy = false }
        do { return try await settledTree() }
        catch { try await handle(error); throw Self.sanitized(error) }
    }

    public func verify(expectText: String? = nil) async throws -> Verdict {
        try validateExpectation(expectText)
        try begin()
        defer { busy = false }
        do { return verdict(tree: try await observedTree(expectText: expectText), expectText: expectText) }
        catch { try await handle(error); throw Self.sanitized(error) }
    }

    public func act(_ action: WebAction, expectText: String? = nil) async throws -> Verdict {
        try validateExpectation(expectText)
        try begin()
        defer { busy = false }
        do {
            let before = try await settledTree()
            switch action {
            case let .click(id): try await click(target(id, in: before))
            case let .type(id, text):
                let node = try target(id, in: before)
                guard node.attributes["web.password"] != .bool(true) else {
                    throw WebBrowserError.invalidWebOperation(reason: "password fields require a credential reference")
                }
                try await type(text, into: node)
            case let .credential(id, reference):
                let node = try target(id, in: before)
                let value = try await credentials.resolve(reference)
                try await type(value, into: node)
            case let .key(id, key, modifiers):
                if let id { try await focus(target(id, in: before)) }
                try await dispatchKey(key, modifiers: modifiers)
            case let .submit(id):
                let node = try target(id, in: before)
                if node.role == .button { try await click(node) }
                else if node.role == .textField { try await focus(node); try await dispatchKey("Enter", modifiers: []) }
                else {
                    guard let button = node.flattened().first(where: { $0.role == .button && $0.isVisible }) else {
                        throw WebBrowserError.invalidWebOperation(reason: "submit requires a button, editable field, or form with a button")
                    }
                    try await click(button)
                }
            }
            let after = try await observedTree(expectText: expectText)
            var result = verdict(tree: after, expectText: expectText)
            if expectText == nil {
                result = Verdict(scenario: result.scenario, findings: result.findings + [Finding(
                    rule: "web-outcome-unasserted", severity: .warning, nodeID: after.id,
                    message: "Input was delivered and the page was observed; no expected task outcome was asserted.",
                    suggestion: "Provide expectText to verify the application's resulting state.")], tree: after, timing: result.timing)
            }
            // Redact the pre-action tree too: a newly resolved credential may
            // already have been reflected by the page before this operation.
            let safeBefore = try redactTree(before)
            result.delta = TreeDiff.compute(before: safeBefore, after: after)
            return result
        } catch { try await handle(error); throw Self.sanitized(error) }
    }

    public func close() async throws {
        guard !closed else { return }
        closed = true
        await transport.close()
        do { try await browser.terminate(grace: 1); lock.release() }
        catch { closed = false; throw Self.sanitized(error) }
        secrets.removeAll()
    }

    private func begin() throws {
        guard !closed else { throw WebBrowserError.invalidWebOperation(reason: "session is closed") }
        guard !busy else { throw WebBrowserError.invalidWebOperation(reason: "session is busy; wait for its current operation") }
        busy = true
    }

    private func command(_ method: String, _ params: [String: CDPValue] = [:], session: String? = nil) async throws -> [String: CDPValue] {
        do { return try await transport.send(method: method, params: params, timeout: .seconds(5), sessionID: session ?? pageSessionID) }
        catch { throw Self.sanitized(error) }
    }

    private func settledTree() async throws -> SemanticNode {
        let deadline = ContinuousClock.now + .seconds(10)
        var previous: SemanticNode?
        var stable = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let ready = try await command("Runtime.evaluate", [
                "expression": .string("document.readyState === 'complete' && (!document.fonts || document.fonts.status === 'loaded')"),
                "returnByValue": .bool(true)])
            let pendingNetwork = await transport.pendingNetworkRequests(sessionID: pageSessionID)
            if case let .object(result) = ready["result"], result["value"] == .bool(true), pendingNetwork == 0 {
                let tree = try await captureTree()
                var networkQuiet = true
                for session in Set(frameSessions.values) {
                    if await transport.pendingNetworkRequests(sessionID: session) > 0 { networkQuiet = false }
                }
                if !networkQuiet { stable = 0; previous = nil; try await Task.sleep(for: .milliseconds(100)); continue }
                stable = tree == previous ? stable + 1 : 0
                if stable >= 2 {
                    let frames = try await command("Page.getFrameTree")
                    if case let .object(frameTree) = frames["frameTree"],
                        case let .object(frame) = frameTree["frame"],
                        let rawURL = frame["url"]?.stringValue, let url = URL(string: rawURL) { currentURL = url }
                    return tree
                }
                previous = tree
            } else { stable = 0; previous = nil }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WebBrowserError.invalidWebOperation(reason: "page did not finish loading and settle within 10 seconds")
    }

    private func snapshot(session: String) async throws -> [String: CDPValue] {
        try await command("DOMSnapshot.captureSnapshot", [
            "computedStyles": .array(DOMSnapshotAssembly.computedStyles.map(CDPValue.string)),
            "includePaintOrder": .bool(false), "includeDOMRects": .bool(true)], session: session)
    }

    private func documentFrames(_ snapshot: [String: CDPValue]) -> Set<String> {
        guard case let .array(strings) = snapshot["strings"], case let .array(documents) = snapshot["documents"] else { return [] }
        return Set(documents.compactMap { value in
            guard case let .object(document) = value, case let .integer(index) = document["frameId"],
                let offset = Int(exactly: index), strings.indices.contains(offset) else { return nil }
            return strings[offset].stringValue
        })
    }

    private func captureTree() async throws -> SemanticNode {
        let main = try await snapshot(session: pageSessionID)
        var tree = try DOMSnapshotAssembly.assemble(main, viewport: viewport, redacting: secrets)
        var known = documentFrames(main)
        var routing = Dictionary(uniqueKeysWithValues: known.map { ($0, pageSessionID) })
        let targets = try await transport.send(method: "Target.getTargets")
        guard case let .array(infos) = targets["targetInfos"] else {
            throw WebBrowserError.invalidCDPResponse(reason: "missing frame target inventory")
        }
        var remaining = infos.compactMap { value -> [String: CDPValue]? in
            if case let .object(info) = value, info["type"] == .string("iframe") { return info }
            return nil
        }
        var activeRemote: Set<String> = []
        for _ in 0..<256 {
            guard let index = remaining.firstIndex(where: {
                known.contains($0["parentFrameId"]?.stringValue ?? "") || known.contains($0["parentId"]?.stringValue ?? "")
            }) else { break }
            let target = remaining.remove(at: index)
            guard let frame = target["targetId"]?.stringValue,
                let parent = target["parentFrameId"]?.stringValue ?? target["parentId"]?.stringValue,
                let parentSession = routing[parent] else {
                throw WebBrowserError.invalidCDPResponse(reason: "invalid frame target relationship")
            }
            let session: String
            if let existing = remoteSessions[frame] { session = existing }
            else {
                let attached = try await transport.send(method: "Target.attachToTarget", params: ["targetId": .string(frame), "flatten": .bool(true)])
                guard let attachedID = attached["sessionId"]?.stringValue else {
                    throw WebBrowserError.invalidCDPResponse(reason: "cannot attach embedded frame")
                }
                session = attachedID
                remoteSessions[frame] = session
                _ = try await command("Page.enable", session: session)
                await transport.setNetworkRootFrame(frame, sessionID: session)
                _ = try await command("Network.enable", session: session)
            }
            activeRemote.insert(frame)
            let frameSnapshot = try await snapshot(session: session)
            let descendants = try DOMSnapshotAssembly.assemble(frameSnapshot, viewport: viewport, redacting: secrets)
            let owner = try await command("DOM.getFrameOwner", ["frameId": .string(frame)], session: parentSession)
            guard let backendID = owner["backendNodeId"]?.doubleValue else {
                throw WebBrowserError.invalidCDPResponse(reason: "embedded frame has no owner element")
            }
            let (grafted, found) = WebFrameGeometry.graft(descendants.children, ownerBackend: backendID, ownerFrame: parent, into: tree)
            guard found else { throw WebBrowserError.invalidCDPResponse(reason: "embedded frame owner absent from snapshot") }
            tree = grafted
            for id in documentFrames(frameSnapshot) { known.insert(id); routing[id] = session }
        }
        // Detach obsolete frame sessions (navigation can change renderer
        // ownership). A detached session never becomes another frame's route.
        for frame in Set(remoteSessions.keys).subtracting(activeRemote) {
            remoteSessions.removeValue(forKey: frame)
        }
        frameSessions = routing
        return tree.withAssignedStructuralPaths()
    }

    private func nodeSession(_ node: SemanticNode) throws -> String {
        guard let frame = node.attributes["web.frame"]?.stringValue, let session = frameSessions[frame] else {
            throw WebBrowserError.invalidWebOperation(reason: "target frame was detached; render again")
        }
        return session
    }

    private func validateExpectation(_ text: String?) throws {
        guard let text else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 4096 else {
            throw WebBrowserError.invalidWebOperation(reason: "expected text must be nonempty and at most 4096 bytes")
        }
    }

    private func contains(_ text: String, in tree: SemanticNode) -> Bool {
        tree.flattened().contains { $0.isVisible && ($0.text?.contains(text) == true || $0.attributes["accessibilityLabel"]?.stringValue?.contains(text) == true) }
    }

    private func observedTree(expectText: String?) async throws -> SemanticNode {
        let deadline = ContinuousClock.now + .seconds(10)
        var tree = try await settledTree()
        guard let expectText else { return tree }
        while !contains(expectText, in: tree), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            tree = try await settledTree()
        }
        return tree
    }

    private func verdict(tree: SemanticNode, expectText: String?) -> Verdict {
        let context = LintContext(scenario: "web/\(profile)", viewport: viewport)
        var result = RuleEngine.run(rules: RuleEngine.standardRules, on: tree, context: context, includeTree: true)
        if let expectText, !contains(expectText, in: tree) {
            result = Verdict(scenario: result.scenario, findings: result.findings + [Finding(
                rule: "web-expectation", severity: .error, nodeID: tree.id,
                message: "The expected visible text was absent after the operation.",
                suggestion: "Inspect the returned tree and the application's outcome.")], tree: tree, timing: result.timing)
        }
        return result
    }

    private func target(_ id: String, in tree: SemanticNode) throws -> SemanticNode {
        guard !id.isEmpty, let node = tree.flattened().first(where: { $0.id == id || $0.structuralPath == id }),
            node.id != tree.id, node.isVisible, node.attributes["web.enabled"] != .bool(false) else {
            throw WebBrowserError.invalidWebOperation(reason: "target is missing, hidden, or disabled; render again")
        }
        return node
    }

    private func backend(_ node: SemanticNode) throws -> CDPValue {
        guard let raw = node.attributes["web.backendID"]?.numberValue, raw.isFinite,
            raw > 0, raw <= Double(Int64.max), let id = Int64(exactly: raw) else {
            throw WebBrowserError.invalidWebOperation(reason: "target has no browser identity")
        }
        return .integer(id)
    }

    private func focus(_ node: SemanticNode) async throws {
        _ = try await command("DOM.focus", ["backendNodeId": backend(node)], session: nodeSession(node))
    }

    private func click(_ node: SemanticNode) async throws {
        let id = try backend(node)
        _ = try await command("DOM.scrollIntoViewIfNeeded", ["backendNodeId": id], session: nodeSession(node))
        // Scrolling an embedded document can also scroll its parent page. Read
        // geometry again before converting renderer-local event coordinates.
        let latest = try await settledTree()
        let fresh = try target(node.id.isEmpty ? node.structuralPath : node.id, in: latest)
        let session = try nodeSession(fresh)
        let result = try await command("DOM.getContentQuads", ["backendNodeId": id], session: session)
        guard case let .array(quads) = result["quads"], case let .array(points) = quads.first,
            points.count == 8, points.allSatisfy({ $0.doubleValue?.isFinite == true }) else {
            throw WebBrowserError.invalidWebOperation(reason: "target has no clickable geometry")
        }
        let coordinates = points.compactMap(\.doubleValue)
        let localX = stride(from: 0, to: 8, by: 2).reduce(0.0) { $0 + coordinates[$1] } / 4
        let localY = stride(from: 1, to: 8, by: 2).reduce(0.0) { $0 + coordinates[$1] } / 4
        let inputWidth = fresh.attributes["web.inputWidth"]?.numberValue ?? fresh.frame.width
        let inputHeight = fresh.attributes["web.inputHeight"]?.numberValue ?? fresh.frame.height
        let scaleX = inputWidth > 0 ? fresh.frame.width / inputWidth : 1
        let scaleY = inputHeight > 0 ? fresh.frame.height / inputHeight : 1
        let x = fresh.frame.x + (localX - (fresh.attributes["web.inputX"]?.numberValue ?? fresh.frame.x)) * scaleX
        let y = fresh.frame.y + (localY - (fresh.attributes["web.inputY"]?.numberValue ?? fresh.frame.y)) * scaleY
        guard x >= 0, y >= 0, x < viewport.width, y < viewport.height else {
            throw WebBrowserError.invalidWebOperation(reason: "target is outside the viewport after scrolling")
        }
        let hit = try await command("DOM.getNodeForLocation", ["x": .integer(Int64(localX)), "y": .integer(Int64(localY))], session: session)
        guard let hitID = hit["backendNodeId"], try fresh.flattened().contains(where: { try backend($0) == hitID }) else {
            throw WebBrowserError.invalidWebOperation(reason: "target is covered by another element")
        }
        let rootHit = try await command("DOM.getNodeForLocation", ["x": .integer(Int64(x)), "y": .integer(Int64(y))])
        guard let rootBackend = rootHit["backendNodeId"]?.doubleValue,
            let rootFrame = rootHit["frameId"]?.stringValue,
            let hitNode = latest.flattened().first(where: {
                $0.attributes["web.backendID"]?.numberValue == rootBackend && $0.attributes["web.frame"]?.stringValue == rootFrame
            }),
            hitNode.flattened().contains(where: { $0.id == fresh.id }) || fresh.flattened().contains(where: { $0.id == hitNode.id }) else {
            throw WebBrowserError.invalidWebOperation(reason: "target frame is covered by another element")
        }
        for type in ["mousePressed", "mouseReleased"] {
            _ = try await command("Input.dispatchMouseEvent", [
                "type": .string(type), "x": .number(x), "y": .number(y),
                "button": .string("left"), "clickCount": .integer(1)])
        }
    }

    private func type(_ text: String, into node: SemanticNode) async throws {
        guard node.role == .textField, text.utf8.count <= 65_536 else {
            throw WebBrowserError.invalidWebOperation(reason: "typing requires an editable field and at most 65536 bytes")
        }
        if !text.isEmpty { secrets.append(text) }
        try await focus(node)
        try await dispatchKey("a", modifiers: ["meta"])
        try await dispatchKey("Backspace", modifiers: [])
        // CDP insertText is trusted input and supports composed/non-Latin text;
        // unlike DOM.value assignment it fires the browser's normal input path.
        _ = try await command("Input.insertText", ["text": .string(text)])
    }

    private func dispatchKey(_ key: String, modifiers: [String]) async throws {
        let modifierBits = ["alt": 1, "control": 2, "meta": 4, "shift": 8]
        guard modifiers.allSatisfy({ modifierBits[$0.lowercased()] != nil }) else {
            throw WebBrowserError.invalidWebOperation(reason: "unknown key modifier")
        }
        let flags = Set(modifiers.map { $0.lowercased() }).reduce(0) { $0 | (modifierBits[$1] ?? 0) }
        let known = ["Enter": 13, "Tab": 9, "Escape": 27, "Backspace": 8, "Delete": 46,
                     "ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40,
                     "Home": 36, "End": 35, "PageUp": 33, "PageDown": 34, "Space": 32]
        guard known[key] != nil || (key.count == 1 && key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 })) else {
            throw WebBrowserError.invalidWebOperation(reason: "unsupported key name")
        }
        let keyValue = key == "Space" ? " " : key
        let code = known[key] ?? Int(key.uppercased().utf8.first ?? 0)
        var parameters: [String: CDPValue] = ["key": .string(keyValue), "modifiers": .integer(Int64(flags)),
                                            "windowsVirtualKeyCode": .integer(Int64(code))]
        parameters["type"] = .string("keyDown")
        if key.lowercased() == "a" && flags & 6 != 0 {
            parameters["commands"] = .array([.string("selectAll")])
        }
        if key == "Enter" { parameters["text"] = .string("\r") }
        else if keyValue.count == 1 && flags & 7 == 0 { parameters["text"] = .string(keyValue) }
        _ = try await command("Input.dispatchKeyEvent", parameters)
        parameters["type"] = .string("keyUp")
        parameters.removeValue(forKey: "text")
        parameters.removeValue(forKey: "commands")
        _ = try await command("Input.dispatchKeyEvent", parameters)
    }

    private func redactTree(_ tree: SemanticNode) throws -> SemanticNode {
        var result = tree
        result.text = tree.text.map { WebRedaction.clean($0, secrets: secrets) }
        result.attributes = tree.attributes.mapValues { value in
            if case let .string(text) = value { return .string(WebRedaction.clean(text, secrets: secrets)) }
            return value
        }
        result.children = try tree.children.map(redactTree)
        return result
    }

    private func handle(_ error: any Error) async throws {
        let available = await isAvailable()
        if Task.isCancelled && available {
            try await close()
        }
        throw Self.sanitized(error)
    }

    deinit {
        guard !closed else { return }
        let ownedBrowser = browser
        let ownedTransport = transport
        let ownedLock = lock
        Task {
            await ownedTransport.close()
            do { try await ownedBrowser.terminate(grace: 1); ownedLock.release() }
            catch { /* Preserve ownership if the OS cannot terminate the browser. */ }
        }
    }

    static func validateURL(_ url: URL) throws {
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
            url.user == nil, url.password == nil else {
            throw WebBrowserError.invalidWebOperation(reason: "URL must use http, https, or file without embedded credentials")
        }
    }

    static func sanitized(_ error: any Error) -> WebBrowserError {
        if case let WebBrowserError.cdpError(code, _) = error { return .cdpError(code: code, message: "browser rejected the operation") }
        if let error = error as? WebBrowserError { return error }
        if error is CancellationError { return .invalidWebOperation(reason: "operation cancelled") }
        return .invalidWebOperation(reason: "browser operation failed")
    }
}
