// Wave 6: how the CLI writes, and what its exit code means.
//
// Everything the tool prints goes through this file, for one reason: stdout is
// a machine-readable contract (an agent parses it) and stderr is a human one.
// A single `print` anywhere else is how the two get mixed, and a verdict JSON
// with a progress line stapled to the front is not JSON.
import Foundation
import VerdictUIKernel

/// Where output goes, injectable so tests read what was written instead of
/// scraping a subprocess.
///
/// A protocol rather than a `FileHandle` pair because the point of the CLI
/// core being a library is that its behaviour is assertable in-process — a test
/// that has to spawn `verdictui` to see its output is measuring the build
/// system as much as the code.
public protocol OutputSink: AnyObject, Sendable {
    /// The machine-readable channel. One complete document, or nothing.
    func writeOut(_ text: String)
    /// The human channel: errors, progress, anything not part of the contract.
    func writeError(_ text: String)
}

/// Writes to the process's real streams.
///
/// `@unchecked Sendable` because `FileHandle`'s own writes are the
/// serialization point: each call is a single `write(2)` on a shared fd, which
/// the kernel already orders. Adding a lock here would serialize a second time
/// and still not make interleaved writes from two processes atomic.
public final class StandardOutput: OutputSink, @unchecked Sendable {
    public init() {}

    public func writeOut(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Collects output in memory.
public final class CapturedOutput: OutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    public init() {}

    public func writeOut(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        out += text
    }

    public func writeError(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        err += text
    }

    /// Everything written to the machine channel.
    public var standardOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return out
    }

    /// Everything written to the human channel.
    public var standardError: String {
        lock.lock()
        defer { lock.unlock() }
        return err
    }
}

/// Exit codes the tool uses, and what a caller may conclude from each.
///
/// Three states rather than two, and the third is the one that matters. A tool
/// that reports "did not pass" for both *the UI is wrong* and *I could not
/// look* forces every caller to treat an infrastructure failure as a product
/// defect — the shape `no.md` #206 records, where "could not observe" and
/// "observed nothing wrong" become indistinguishable.
public enum ExitCode: Int32, Equatable, Sendable {
    /// The verdict passed, or the query succeeded.
    case pass = 0
    /// A verdict was produced and it FAILED. The UI is wrong.
    case verdictFailed = 1
    /// No verdict could be produced: unknown scenario, unreadable baseline,
    /// a settle that never finished. Says nothing about the UI.
    case couldNotVerify = 2
}

/// Renders verdicts and reports as the CLI's output contract.
public enum VerdictOutput {
    /// Pretty-printed with sorted keys: the output is read by humans in diffs
    /// as often as by agents, and an unstable key order shows as noise in both.
    public static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting =
            pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encode `value` as the tool's stdout document.
    public static func json<T: Encodable>(_ value: T, pretty: Bool) throws -> String {
        let data = try encoder(pretty: pretty).encode(value)
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    /// A verdict rendered for a human reader.
    ///
    /// Deliberately not a second serialization of everything: `--pretty` JSON
    /// already does that. This is the summary a person wants when they ran the
    /// command themselves — the status, then one line per finding naming the
    /// rule, the node, and the suggestion, because a finding without its node
    /// id sends the reader hunting.
    public static func humanReadable(_ verdict: Verdict) -> String {
        var lines: [String] = []
        let mark = verdict.status == .pass ? "PASS" : "FAIL"
        lines.append("\(mark)  \(verdict.scenario)")

        if verdict.findings.isEmpty {
            lines.append("  no findings")
        } else {
            for finding in verdict.findings {
                lines.append(
                    "  [\(finding.severity.rawValue)] \(finding.rule) "
                        + "on '\(finding.nodeID)': \(finding.message)"
                )
                if let suggestion = finding.suggestion {
                    lines.append("      → \(suggestion)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
