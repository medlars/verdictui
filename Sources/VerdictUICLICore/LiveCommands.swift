import Foundation
import VerdictUIKernel
import VerdictUIWitness

// MARK: - live target

/// Where a live command reads from: a running pid, or an app bundle it
/// launches fresh (and terminates afterwards).
///
/// Launching is what makes a sweep and a named data state possible for an app
/// that has not adopted probes: appearance, locale and fixture flags are
/// LAUNCH-TIME inputs, so the only way to vary them from outside is to start a
/// new instance with them (CIS-1DDD35B2, CIS-15F8D85E).
public struct LiveTarget: Sendable, Equatable {
    public var pid: pid_t?
    public var app: String?
    public var launchArguments: [String]
    public var environment: [String: String]
    public var timeout: TimeInterval
    public var surface: String

    public init(
        pid: pid_t? = nil, app: String? = nil, launchArguments: [String] = [],
        environment: [String: String] = [:], timeout: TimeInterval = 20,
        surface: String = "window:0"
    ) {
        self.pid = pid
        self.app = app
        self.launchArguments = launchArguments
        self.environment = environment
        self.timeout = timeout
        self.surface = surface
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case noTarget
        case bothTargets
        case badSurface(String)
        case badEnvironment(String)
        case launchOptionsWithoutApp

        public var description: String {
            switch self {
            case .noTarget: "pass --pid <n> for a running app, or --app <path.app> to launch one"
            case .bothTargets: "pass --pid OR --app, not both"
            case .badSurface(let value):
                "unknown surface '\(value)' — use window:N, menubar, extras or all"
            case .badEnvironment(let pair): "--launch-env expects KEY=VALUE, got '\(pair)'"
            case .launchOptionsWithoutApp:
                "--launch-arg/--launch-env only apply to --app: a running pid cannot be relaunched"
            }
        }
    }

    /// Parse `KEY=VALUE` pairs. The value may itself contain `=`.
    public static func parseEnvironment(_ pairs: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for pair in pairs {
            guard let split = pair.firstIndex(of: "="), split != pair.startIndex else {
                throw Problem.badEnvironment(pair)
            }
            out[String(pair[..<split])] = String(pair[pair.index(after: split)...])
        }
        return out
    }

    /// The selected surface, or `nil` for `all`.
    public func resolvedSurface() throws -> AXReader.Surface? {
        if surface.lowercased() == "all" { return nil }
        guard let parsed = AXReader.Surface(argument: surface) else {
            throw Problem.badSurface(surface)
        }
        return parsed
    }

    /// Fail before doing anything when the target is ambiguous or absent.
    public func validate() throws {
        switch (pid, app) {
        case (nil, nil): throw Problem.noTarget
        case (.some, .some): throw Problem.bothTargets
        case (.some, nil):
            if !launchArguments.isEmpty || !environment.isEmpty {
                throw Problem.launchOptionsWithoutApp
            }
        case (nil, .some): break
        }
        _ = try resolvedSurface()
    }

    /// Run `body` against the target's pid, launching (and afterwards
    /// terminating) a fresh instance when the target is an app bundle.
    @MainActor
    public func withPid<T>(
        extraArguments: [String] = [], _ body: (pid_t) async throws -> T
    ) async throws -> T {
        try validate()
        if let pid { return try await body(pid) }
        guard let app else { throw Problem.noTarget }
        let launched = try await AppLauncher.launch(
            bundle: URL(fileURLWithPath: app), arguments: launchArguments + extraArguments,
            environment: environment, surface: (try resolvedSurface()) ?? .window(0),
            timeout: timeout)
        defer { AppLauncher.terminate(pid: launched) }
        return try await body(launched)
    }

    /// Read the selected surface (optionally with sampled colours).
    @MainActor
    func readTree(pid: pid_t, colors: Bool) throws -> SemanticNode {
        let surface = try resolvedSurface() ?? .window(0)
        if colors {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("verdictui-colors-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: scratch) }
            return try WindowCapture.readTreeWithColors(
                pid: pid, surface: surface, scratch: scratch)
        }
        return try AXReader.readTree(pid: pid, surface: surface)
    }
}

// MARK: - inspect

/// Read — and optionally act on — the UI of a RUNNING application by pid.
///
/// The reachable surface for ``AXReader``, which had none. `readTree(pid:)` and
/// `press(pid:named:)` were correct, tested library API that no CLI verb, MCP
/// tool or production caller could reach, so the capability existed only for
/// someone already writing Swift against the package — precisely the audience
/// that does not need a tool. That is a PORT, not an integration.
///
/// Distinct from `render` on purpose. `render` asks a SCENARIO — an in-process
/// instrumented view VerdictUI owns — what it drew. This asks a process the
/// tool did not write and cannot instrument, which is the only question
/// available for a shipped `.app`, and the one that found two real defects in
/// LaunchGate that a 331-test green suite had shipped.
///
/// No adoption step: it takes a pid (or launches an app), so it answers
/// questions about any GUI product today, before that product declares a
/// single scenario.
public struct InspectCommand: Sendable {
    public let target: LiveTarget
    /// When set, PRESS the element with this name instead of printing the tree.
    public let press: String?
    /// When set, PRESS the element at this structural path — the identity the
    /// tree itself prints, so read-then-press round-trips (CIS-3DDA018A).
    public let pressPath: String?
    /// Structural path an ``act`` verb applies to.
    public let path: String?
    /// An action verb (see ``AXReader/Action/verbs``).
    public let act: String?
    /// The verb's argument: text for set-value/type, a fraction for scroll-to.
    public let value: String?
    /// Sample per-node colours from a window capture (CIS-29DC2767).
    public let colors: Bool

    public init(pid: pid_t, press: String? = nil, pressPath: String? = nil) {
        self.init(target: LiveTarget(pid: pid), press: press, pressPath: pressPath)
    }

    public init(
        target: LiveTarget, press: String? = nil, pressPath: String? = nil, path: String? = nil,
        act: String? = nil, value: String? = nil, colors: Bool = false
    ) {
        self.target = target
        self.press = press
        self.pressPath = pressPath
        self.path = path
        self.act = act
        self.value = value
        self.colors = colors
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case actNeedsPath
        case unknownAction(String)

        public var description: String {
            switch self {
            case .actNeedsPath:
                "--act needs --path <structuralPath> (read the tree first to find it)"
            case .unknownAction(let verb):
                "unknown or incomplete action '\(verb)' — verbs: "
                    + AXReader.Action.verbs.joined(separator: ", ")
                    + " (set-value and type need --value; scroll-to needs --value in 0...1)"
            }
        }
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            // Refuse a malformed request BEFORE launching anything.
            var action: AXReader.Action?
            if let act {
                guard path != nil else { throw Problem.actNeedsPath }
                guard let parsed = AXReader.Action(verb: act, value: value) else {
                    throw Problem.unknownAction(act)
                }
                action = parsed
            }
            return try await target.withPid { pid in
                let surface = try target.resolvedSurface() ?? .window(0)
                // Trust is checked by the reader and surfaces as a typed
                // failure; the reader's answer is authoritative, since
                // `AXIsProcessTrusted()` can be true while a read still fails.
                // PATH FIRST: it is the identity the tree prints, so it is what
                // a caller who just read the tree actually holds.
                if let pressPath {
                    try AXReader.press(pid: pid, atPath: pressPath, surface: surface)
                    environment.output.writeOut(
                        try VerdictOutput.json(["pressed": pressPath], pretty: pretty))
                    return .pass
                }
                if let name = press {
                    try AXReader.press(pid: pid, named: name, surface: surface)
                    environment.output.writeOut(
                        try VerdictOutput.json(["pressed": name], pretty: pretty))
                    return .pass
                }
                if let action, let path {
                    try AXReader.act(pid: pid, atPath: path, surface: surface, action: action)
                    environment.output.writeOut(
                        try VerdictOutput.json(
                            ["acted": action.description, "path": path], pretty: pretty))
                    return .pass
                }
                if try target.resolvedSurface() == nil {
                    let all = try AXReader.readAllSurfaces(pid: pid)
                    environment.output.writeOut(try VerdictOutput.json(all, pretty: pretty))
                    return .pass
                }
                let tree = try target.readTree(pid: pid, colors: colors)
                environment.output.writeOut(try VerdictOutput.json(tree, pretty: pretty))
                return .pass
            }
        }
    }
}

// MARK: - judge a live app

/// `judge --pid` / `judge --app`: a verdict about an app that never adopted
/// probes (CIS-B5DA3C41). Reads the live accessibility tree (optionally with
/// sampled colours) and applies the same rules `judge` applies to a tree file.
public struct LiveJudgeCommand: Sendable {
    public let target: LiveTarget
    public let colors: Bool
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let scenarioName: String

    public init(
        target: LiveTarget, colors: Bool = false, viewportWidth: Double = 0,
        viewportHeight: Double = 0, scenarioName: String = "live-app"
    ) {
        self.target = target
        self.colors = colors
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.scenarioName = scenarioName
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool, summary: Bool) async
        -> ExitCode
    {
        await CommandRunner.run(output: environment.output) {
            if try target.resolvedSurface() == nil {
                throw LiveTarget.Problem.badSurface(
                    "all (judge one surface at a time; inspect --surface all lists them)")
            }
            let tree = try await target.withPid { pid in
                try target.readTree(pid: pid, colors: colors)
            }
            let verdict = JudgeCommand.judge(
                tree: tree, viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                scenarioName: scenarioName,
                // An AX tree carries no probe ids, so the vacuity guard would
                // fire on every live read — a check that cannot pass.
                requiresProbedNodes: false)
            environment.output.writeOut(
                summary
                    ? VerdictOutput.humanReadable(verdict)
                    : try VerdictOutput.json(verdict, pretty: pretty))
            return verdict.status == .pass ? .pass : .verdictFailed
        }
    }
}

// MARK: - capture

/// `capture`: window-only PNG of a running (or freshly launched) app
/// (CIS-009B4F22). See ``WindowCapture`` for the two constraints it encodes.
public struct CaptureCommand: Sendable {
    public let target: LiveTarget
    public let windowIndex: Int
    public let outputPath: String

    public init(target: LiveTarget, windowIndex: Int = 0, outputPath: String) {
        self.target = target
        self.windowIndex = windowIndex
        self.outputPath = outputPath
    }

    struct Report: Encodable {
        let path: String
        let windowID: UInt32
        let title: String?
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Double
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let url = URL(fileURLWithPath: outputPath)
            let shot = try await target.withPid { pid in
                try WindowCapture.capture(pid: pid, index: windowIndex, to: url)
            }
            let w = shot.window
            environment.output.writeOut(
                try VerdictOutput.json(
                    Report(
                        path: shot.path, windowID: w.windowID, title: w.title, x: w.x, y: w.y,
                        width: w.width, height: w.height, pixelWidth: shot.raster.width,
                        pixelHeight: shot.raster.height, scale: shot.scale),
                    pretty: pretty))
            return .pass
        }
    }
}

// MARK: - sweep a live app

/// `sweep --app`: relaunch an app once per locale x appearance cell, read and
/// judge each, and report every cell (CIS-1DDD35B2).
///
/// A RUNNING app cannot be swept — its locale and appearance are fixed at
/// launch — so `--pid` is refused with that reason rather than silently
/// reading the one configuration it happens to be in.
public struct LiveSweepCommand: Sendable {
    public let target: LiveTarget
    public let locales: [String]
    public let colorSchemes: [String]
    public let dynamicTypeSizes: [String]
    public let colors: Bool

    public init(
        target: LiveTarget, locales: [String], colorSchemes: [String],
        dynamicTypeSizes: [String] = [], colors: Bool = false
    ) {
        self.target = target
        self.locales = locales
        self.colorSchemes = colorSchemes
        self.dynamicTypeSizes = dynamicTypeSizes
        self.colors = colors
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case runningAppCannotBeSwept
        case dynamicTypeIsInertOnMacOS
        case noAxis
        case badColorScheme(String)

        public var description: String {
            switch self {
            case .runningAppCannotBeSwept:
                "a running app's locale and appearance are fixed at launch — pass --app "
                    + "<path.app> so each cell launches a fresh instance"
            case .dynamicTypeIsInertOnMacOS:
                "--dynamic-type-sizes cannot vary a macOS app: macOS sizes text from NSFont, "
                    + "so every cell would render identically (no.md #29)"
            case .noAxis: "pass --locales and/or --color-schemes"
            case .badColorScheme(let value): "color scheme must be light or dark, got '\(value)'"
            }
        }
    }

    /// One locale x appearance combination.
    public struct Cell: Equatable, Sendable {
        public let locale: String?
        public let colorScheme: String?
    }

    /// The cells to run, validated. Pure, so the matrix is testable without
    /// launching anything.
    public func cells() throws -> [Cell] {
        if target.pid != nil { throw Problem.runningAppCannotBeSwept }
        if !dynamicTypeSizes.isEmpty { throw Problem.dynamicTypeIsInertOnMacOS }
        guard !locales.isEmpty || !colorSchemes.isEmpty else { throw Problem.noAxis }
        for scheme in colorSchemes where !["light", "dark"].contains(scheme.lowercased()) {
            throw Problem.badColorScheme(scheme)
        }
        let localeAxis: [String?] = locales.isEmpty ? [nil] : locales
        let schemeAxis: [String?] = colorSchemes.isEmpty ? [nil] : colorSchemes
        return localeAxis.flatMap { locale in
            schemeAxis.map { Cell(locale: locale, colorScheme: $0) }
        }
    }

    struct CellReport: Encodable {
        let locale: String?
        let colorScheme: String?
        let verdict: Verdict
    }

    struct Report: Encodable {
        let app: String
        let cells: [CellReport]
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let matrix = try cells()
            try target.validate()
            var reports: [CellReport] = []
            for cell in matrix {
                let extra = AppLauncher.variantArguments(
                    locale: cell.locale, colorScheme: cell.colorScheme)
                let tree = try await target.withPid(extraArguments: extra) { pid in
                    try target.readTree(pid: pid, colors: colors)
                }
                let name = [cell.locale, cell.colorScheme].compactMap { $0 }.joined(separator: "/")
                reports.append(
                    CellReport(
                        locale: cell.locale, colorScheme: cell.colorScheme,
                        verdict: JudgeCommand.judge(
                            tree: tree, viewportWidth: 0, viewportHeight: 0,
                            scenarioName: "sweep \(name)", requiresProbedNodes: false)))
            }
            environment.output.writeOut(
                try VerdictOutput.json(Report(app: target.app ?? "", cells: reports), pretty: pretty))
            return reports.allSatisfy { $0.verdict.status == .pass } ? .pass : .verdictFailed
        }
    }
}
