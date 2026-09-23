import ArgumentParser
import Foundation
import VerdictUIKernel
import VerdictUIWeb

/// Explicit coverage declarations shared by developers and background edit hooks.
public struct ProjectChecks: Codable, Sendable {
    public struct Check: Codable, Sendable {
        public let name: String
        public let kind: String
        public let scenario: String?
        public let url: String?
        public let runner: String?
        public let subject: String?
        public let pid: Int32?
        public let surface: String?
        public let expectText: String?
    }
    public let checks: [Check]

    static func load(root: URL) throws -> Self {
        let file = root.appendingPathComponent(".verdictui/checks.json")
        let data = try Data(contentsOf: file)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_024 * 1_024 else { throw LiveRuntime.Failure.invalidRequest("check manifest too large") }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard !manifest.checks.isEmpty, manifest.checks.count <= 100,
              Set(manifest.checks.map(\.name)).count == manifest.checks.count else {
            throw LiveRuntime.Failure.invalidRequest("checks must contain 1...100 uniquely named targets")
        }
        for check in manifest.checks {
            guard !check.name.isEmpty, ["scenario", "web", "appkit", "live"].contains(check.kind),
                  check.expectText?.isEmpty != true else {
                throw LiveRuntime.Failure.invalidRequest("invalid check declaration")
            }
        }
        return manifest
    }
}

public struct ProjectCheckReport: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let name: String
        public let status: String
        public let verdict: Verdict?
        public let error: String?
    }
    public let status: String
    public let checks: [Entry]
    public let error: String?

    var exitCode: ExitCode {
        status == "pass" ? .pass : status == "fail" ? .verdictFailed : .couldNotVerify
    }

    public func unavailable(reason: String) -> Self {
        Self(status: "unavailable", checks: checks, error: reason)
    }

    static func aggregate(_ entries: [Entry]) -> Self {
        let status = entries.isEmpty || entries.contains { $0.status == "unavailable" }
            ? "unavailable" : entries.contains { $0.status == "fail" } ? "fail" : "pass"
        return Self(status: status, checks: entries, error: nil)
    }
}

public enum ProjectCheckRuntime {
    public struct Progress: Codable, Sendable {
        public let name: String
        public let index: Int
        public let total: Int
        public let status: String
    }
    @MainActor
    public static func run(root: URL, executable: URL, sessions: WebSessionManager,
                           progress: (@MainActor (Progress) -> Void)? = nil) async -> ProjectCheckReport {
        let manifest: ProjectChecks
        do { manifest = try ProjectChecks.load(root: root) }
        catch {
            return .init(status: "unavailable", checks: [], error: "Project checks are unconfigured or invalid; declare .verdictui/checks.json. Demo scenarios are not project coverage.")
        }
        var entries: [ProjectCheckReport.Entry] = []
        for (index, check) in manifest.checks.enumerated() {
            if Task.isCancelled {
                entries.append(.init(name: check.name, status: "unavailable", verdict: nil, error: "Check cancelled"))
                progress?(.init(name: check.name, index: index, total: manifest.checks.count, status: "unavailable"))
                continue
            }
            progress?(.init(name: check.name, index: index, total: manifest.checks.count, status: "running"))
            do {
                let verdict = try await verify(check, index: index, root: root, executable: executable, sessions: sessions)
                try Task.checkCancellation()
                entries.append(.init(name: check.name, status: verdict.status == .pass ? "pass" : "fail", verdict: verdict, error: nil))
            } catch {
                entries.append(.init(name: check.name, status: "unavailable", verdict: nil,
                                     error: "Declared target could not be verified; validate its configuration and availability."))
            }
            progress?(.init(name: check.name, index: index, total: manifest.checks.count,
                            status: entries.last?.status ?? "unavailable"))
        }
        return .aggregate(entries)
    }

    @MainActor
    private static func verify(_ check: ProjectChecks.Check, index: Int, root: URL,
                               executable: URL, sessions: WebSessionManager) async throws -> Verdict {
        switch check.kind {
        case "web":
            guard let raw = check.url, let url = URL(string: raw) else { throw LiveRuntime.Failure.unavailable }
            let profile = "check-\(UUID().uuidString.lowercased())-\(index)"
            _ = try await sessions.open(profile: profile, url: url)
            do {
                let verdict = try await sessions.verify(profile: profile, expectText: check.expectText)
                try await sessions.close(profile: profile)
                return verdict
            } catch {
                try? await sessions.close(profile: profile)
                throw error
            }
        case "live":
            guard let pid = check.pid else { throw LiveRuntime.Failure.unavailable }
            let result = try await LiveRuntime.handle(
                LiveRequest(pid: pid, surface: check.surface ?? "window:0", expectText: check.expectText), method: "live_verify")
            guard case .verdict(let verdict) = result else { throw LiveRuntime.Failure.unavailable }
            return verdict
        case "scenario":
            guard let scenario = check.scenario, !scenario.isEmpty,
                  try ProjectScenarios.declaredRunnerStrict(projectRoot: root) != nil else {
                throw LiveRuntime.Failure.unavailable
            }
            // A stock catalog declaration cannot certify another application's coverage.
            let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
            guard root.resolvingSymlinksInPath() != sourceRoot else { throw LiveRuntime.Failure.unavailable }
            let result = try await BoundedCommand.run(executable: executable,
                                                      arguments: ["verify", scenario], root: root)
            guard result.code == 0 || result.code == 1 else { throw LiveRuntime.Failure.unavailable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let verdict = try decoder.decode(Verdict.self, from: result.output)
            guard verdict.scenario == scenario, (verdict.status == .pass) == (result.code == 0) else {
                throw LiveRuntime.Failure.unavailable
            }
            return verdict
        case "appkit":
            guard let runner = check.runner, !runner.isEmpty,
                  let subject = check.subject, !subject.isEmpty else { throw LiveRuntime.Failure.unavailable }
            let target = URL(fileURLWithPath: runner, relativeTo: root).standardizedFileURL
            let result = try await BoundedCommand.run(executable: target, arguments: ["render", subject], root: root)
            guard result.code == 0 else { throw LiveRuntime.Failure.unavailable }
            let tree = try JSONDecoder().decode(SemanticNode.self, from: result.output)
            return JudgeCommand.judge(tree: tree, viewportWidth: 0, viewportHeight: 0, scenarioName: subject)
        default: throw LiveRuntime.Failure.unavailable
        }
    }
}

extension VerdictUITool {
    public struct Check: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "check",
            abstract: "Verify this project's declared real targets; never substitutes demos.")
        public init() {}
        @Option public var project: String?
        @Flag public var pretty = false

        @MainActor
        public func run() async throws {
            let root = URL(fileURLWithPath: project ?? FileManager.default.currentDirectoryPath).standardizedFileURL
            // Checks use disposable browser profiles and do not change a user's warm session.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-check-\(UUID().uuidString)")
            let sessions = WebSessionManager(root: temporary)
            let shutdown = RuntimeShutdown(sessions: sessions)
            var report = await ProjectCheckRuntime.run(root: root,
                executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, sessions: sessions)
            let failures = await sessions.closeAll()
            shutdown.cancel()
            if failures.isEmpty { try? FileManager.default.removeItem(at: temporary) }
            else { report = .init(status: "unavailable", checks: report.checks, error: "Browser cleanup incomplete") }
            StandardOutput().writeOut(try VerdictOutput.json(report, pretty: pretty))
            try VerdictUITool.finish(report.exitCode)
        }
    }
}
