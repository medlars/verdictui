import Foundation
import VerdictUIKernel
import VerdictUIWitness

/// Live macOS request shared by the command line, socket and MCP transports.
public struct LiveRequest: Codable, Sendable, Equatable {
    public var pid: Int32?
    public var app: String?
    public var surface: String
    public var path: String?
    public var action: String?
    public var value: String?
    public var expectText: String?
    public var timeout: Double

    public init(
        pid: Int32? = nil, app: String? = nil, surface: String = "window:0",
        path: String? = nil, action: String? = nil, value: String? = nil,
        expectText: String? = nil, timeout: Double = 5
    ) {
        self.pid = pid
        self.app = app
        self.surface = surface
        self.path = path
        self.action = action
        self.value = value
        self.expectText = expectText
        self.timeout = timeout
    }

    public func validatedTarget() throws -> LiveTarget {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw LiveRuntime.Failure.invalidRequest("timeout must be in (0, 60] seconds")
        }
        if let pid, pid <= 0 {
            throw LiveRuntime.Failure.invalidRequest("pid must be positive")
        }
        if let expectText, expectText.isEmpty {
            throw LiveRuntime.Failure.invalidRequest("expected text must not be empty")
        }
        let target = LiveTarget(pid: pid, app: app, timeout: timeout, surface: surface)
        try target.validate()
        guard try target.resolvedSurface() != nil else {
            throw LiveRuntime.Failure.invalidRequest("select one surface, not all")
        }
        return target
    }
}

/// Atomic native act/observe with a bounded observation deadline.
public enum LiveRuntime {
    public enum Failure: Error, CustomStringConvertible {
        case invalidRequest(String)
        case unavailable

        public var description: String {
            switch self {
            case .invalidRequest(let reason): return reason
            case .unavailable: return "native input or observation unavailable; no verdict produced"
            }
        }
    }

    @MainActor
    public static func handle(_ request: LiveRequest, method: String) async throws -> DaemonResult {
        let target = try request.validatedTarget()
        let action: AXReader.Action?
        if method == "live_act" {
            guard let verb = request.action, let path = request.path, !path.isEmpty,
                let parsed = AXReader.Action(verb: verb, value: request.value)
            else {
                throw Failure.invalidRequest("live_act requires a path and a valid action/value")
            }
            action = parsed
        } else {
            action = nil
        }
        return try await target.withPid { pid in
            let surface = try target.resolvedSurface() ?? .window(0)
            if method == "live_inspect" {
                return .tree(try AXReader.readTree(pid: pid, surface: surface))
            }
            if method == "live_verify" {
                let tree = try AXReader.readTree(pid: pid, surface: surface)
                return .verdict(judge(tree, expected: request.expectText))
            }
            guard let action, let path = request.path else {
                throw Failure.invalidRequest("unknown live operation")
            }
            return .step(try await observe(
                request: request,
                read: { try AXReader.readTree(pid: pid, surface: surface) },
                perform: { try AXReader.act(pid: pid, atPath: path, surface: surface, action: action) }
            ))
        }
    }

    /// Injected boundaries let tests distinguish input delivery from observed state.
    @MainActor
    static func observe(
        request: LiveRequest,
        read: () throws -> SemanticNode,
        perform: () throws -> Void
    ) async throws -> StepResultWire {
        _ = try request.validatedTarget()
        let started = ContinuousClock.now
        let before = try read()
        do { try perform() } catch { throw Failure.unavailable }
        let deadline = started + .seconds(request.timeout)
        var previous = before
        var after = before
        var quiet = 0
        var settled = false
        // Three identical observations after at least 150 ms. With an explicit
        // expectation, keep observing until it is met or the deadline expires.
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            after = try read()
            quiet = after == previous ? quiet + 1 : 0
            previous = after
            let reached = request.expectText.map { containsText(after, $0) } ?? true
            if quiet >= 3 && reached {
                settled = true
                break
            }
        }
        var verdict = judge(after, expected: request.expectText)
        let delta = TreeDiff.compute(before: before, after: after)
        if !settled {
            verdict.findings.append(Finding(
                rule: "live-settle-timeout", severity: .error,
                nodeID: request.path ?? "live-root",
                message: "The requested state did not settle before the observation deadline."
            ))
        }
        if request.expectText == nil {
            verdict.findings.append(Finding(
                rule: "live-outcome-unasserted", severity: .warning,
                nodeID: request.path ?? "live-root",
                message: "The input was posted and the resulting tree observed; no expected outcome was supplied."
            ))
        }
        return StepResultWire(
            probe: request.path ?? "live-root",
            status: Verdict.Status.derived(from: verdict.findings).rawValue,
            delta: CompactDelta(delta), findings: verdict.findings, settled: settled,
            elapsedMs: elapsedMilliseconds(started), tree: CompactTree(after)
        )
    }

    static func containsText(_ tree: SemanticNode, _ text: String) -> Bool {
        tree.flattened().contains { ($0.text ?? "").contains(text) }
    }

    static func judge(_ tree: SemanticNode, expected: String?) -> Verdict {
        var verdict = JudgeCommand.judge(
            tree: tree, viewportWidth: 0, viewportHeight: 0,
            scenarioName: "live-app", requiresProbedNodes: false
        )
        if let expected, !containsText(tree, expected) {
            verdict.findings.append(Finding(
                rule: "live-expectation", severity: .error,
                nodeID: tree.id.isEmpty ? tree.structuralPath : tree.id,
                message: "The requested text was not observed in the live application."
            ))
            verdict.status = .derived(from: verdict.findings)
        }
        return verdict
    }

    private static func elapsedMilliseconds(_ start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
