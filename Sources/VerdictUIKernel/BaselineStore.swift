// Wave 6: the storage half of baselines.
//
// `Baselines.swift` decides whether a live tree agrees with a recorded one.
// This file decides where the recording lives, how it is written, and what has
// to be true before an existing one may be overwritten. The split is not
// cosmetic: comparison is pure and testable against in-memory values, while
// storage touches a filesystem and is the only part that can destroy anything.
import Foundation

/// Reads and writes `verdict-baselines/<scenario>.tree.json`.
///
/// ### Why updating is guarded rather than convenient
///
/// A baseline is the record of what a screen is SUPPOSED to look like, so
/// overwriting one converts "this changed" into "this is correct" — the single
/// destructive operation in the whole product. An `--accept` that silently
/// rewrites the file makes every subsequent verdict a statement about whatever
/// the code last happened to do, and the failure is invisible: the suite goes
/// green, permanently, for the wrong reason.
///
/// So ``update(scenario:tree:accepted:auditLog:)`` refuses without an explicit
/// `accepted` flag, and records the SUPERSEDED tree's hash in an append-only
/// audit log before writing. The hash is of the old content, not the new one:
/// after the fact, the question worth answering is "what did I destroy", and
/// the new file is still on disk to be hashed by anyone who wants it.
public struct BaselineStore: Sendable {
    /// Directory holding one file per scenario.
    public let directory: URL

    /// Path of the append-only audit log.
    ///
    /// A sibling of the baseline directory rather than a child, so a careless
    /// `rm -rf verdict-baselines` destroys the baselines without also
    /// destroying the record that they were destroyed.
    public let auditLog: URL

    /// - Parameters:
    ///   - directory: baseline directory. Created on first write, never on read.
    ///   - auditLog: append-only log of superseded baselines.
    public init(directory: URL, auditLog: URL) {
        self.directory = directory
        self.auditLog = auditLog
    }

    /// The conventional layout under `root`.
    public static func standard(root: URL) -> BaselineStore {
        BaselineStore(
            directory: root.appendingPathComponent("verdict-baselines"),
            auditLog: root.appendingPathComponent("logs/baseline-audit.log")
        )
    }

    /// What went wrong, in terms a CLI can print without inventing prose.
    public enum StoreError: Error, Equatable, CustomStringConvertible {
        /// No baseline recorded for this scenario yet.
        case notRecorded(scenario: String)
        /// An update was attempted without `--accept`.
        case updateNotAccepted(scenario: String)
        /// The scenario name cannot be used as a filename.
        case unusableScenarioName(String)

        /// The message a CLI prints verbatim.
        ///
        /// Every case names the remedy, not just the fault: an error that says
        /// what went wrong and stops leaves the reader to guess the flag.
        public var description: String {
            switch self {
            case .notRecorded(let scenario):
                return "no baseline recorded for '\(scenario)' — create one with "
                    + "`verdictui baseline update \(scenario) --accept`"
            case .updateNotAccepted(let scenario):
                return "refusing to overwrite the baseline for '\(scenario)' without --accept "
                    + "(this replaces the record of what the screen SHOULD look like)"
            case .unusableScenarioName(let name):
                return "scenario name '\(name)' cannot be stored: it must not be empty or "
                    + "contain a path separator"
            }
        }
    }

    /// File holding `scenario`'s baseline.
    ///
    /// A scenario name reaches here from a registry that a consumer populates,
    /// so it is untrusted input for this purpose: `../../etc/passwd` is a legal
    /// Swift string and would otherwise be a legal write target. Rejected
    /// rather than sanitized, because silently rewriting a name means the file
    /// a user reads and the file the tool writes have different paths.
    public func url(for scenario: String) throws -> URL {
        guard !scenario.isEmpty, !scenario.contains("/"), scenario != ".", scenario != ".." else {
            throw StoreError.unusableScenarioName(scenario)
        }
        return directory.appendingPathComponent("\(scenario).tree.json")
    }

    /// Whether a baseline exists for `scenario`.
    public func exists(scenario: String) -> Bool {
        guard let url = try? url(for: scenario) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Load `scenario`'s baseline.
    public func load(scenario: String) throws -> Baseline {
        let url = try url(for: scenario)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notRecorded(scenario: scenario)
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(Baseline.self, from: data)
    }

    /// Record `tree` as `scenario`'s baseline.
    ///
    /// Creating a FIRST baseline destroys nothing, so it does not require
    /// `accepted`. Replacing one does, and logs the superseded content's hash
    /// before the write. The distinction is the point: a gate that fires on
    /// both teaches users to pass `--accept` reflexively, and one that fires on
    /// neither is not a gate.
    ///
    /// - Returns: what happened, so the caller reports a fact rather than
    ///   assuming which branch ran.
    @discardableResult
    public func update(
        scenario: String,
        tree: SemanticNode,
        accepted: Bool
    ) throws -> UpdateOutcome {
        let url = try url(for: scenario)
        let previous = try? load(scenario: scenario)

        if previous != nil && !accepted {
            throw StoreError.updateNotAccepted(scenario: scenario)
        }

        let baseline = Baseline(scenario: scenario, tree: tree)
        let data = try Self.encoder.encode(baseline)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        if let previous {
            // Logged BEFORE the write. A log entry for a write that then failed
            // is a recoverable confusion; a destroyed baseline with no entry is
            // not, and the whole point of the log is answering "what did I
            // overwrite" after the fact.
            try appendAudit(
                scenario: scenario,
                supersededHash: Self.hash(of: try Self.encoder.encode(previous))
            )
        }

        try data.write(to: url, options: .atomic)
        return previous == nil ? .created : .replaced
    }

    /// Which branch ``update(scenario:tree:accepted:)`` took.
    public enum UpdateOutcome: Equatable, Sendable {
        /// No baseline existed; one was written.
        case created
        /// An existing baseline was superseded and logged.
        case replaced
    }

    /// Append one audit line for a superseded baseline.
    ///
    /// Opened for appending rather than read-modify-write: the log is the
    /// record of destructive acts, and rewriting it whole would make a crash
    /// mid-update capable of truncating the history it exists to preserve.
    private func appendAudit(scenario: String, supersededHash: String) throws {
        let directory = auditLog.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)\tscenario=\(scenario)\tsuperseded-sha256=\(supersededHash)\n"
        guard let bytes = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: auditLog.path) {
            let handle = try FileHandle(forWritingTo: auditLog)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } else {
            try bytes.write(to: auditLog, options: .atomic)
        }
    }

    /// Every audit line, oldest first. Empty when nothing has been superseded.
    public func auditEntries() throws -> [String] {
        guard FileManager.default.fileExists(atPath: auditLog.path) else { return [] }
        let text = try String(contentsOf: auditLog, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - Coding

    /// Sorted keys and stable formatting: a baseline is read in diffs by
    /// humans, and a re-encode that reorders fields would show as drift.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    /// SHA-256 of `data`, hex-encoded.
    ///
    /// Hand-rolled rather than via CryptoKit because ``VerdictUIKernel`` is
    /// platform-pure by rule 1 — CryptoKit is an Apple framework, and importing
    /// it here would break the kernel's ability to build on Linux CI, which is
    /// the property the purity rule exists to protect.
    static func hash(of data: Data) -> String {
        SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal SHA-256, for the baseline audit log's superseded-content hash.
///
/// Present because the kernel may not import CryptoKit (see
/// ``BaselineStore/hash(of:)``). Deliberately not `public`: this is an
/// implementation detail of the audit log, not a cryptographic service the
/// package offers, and publishing it would invite use in a context where a
/// vetted implementation belongs.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
        0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
        0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
        0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
        0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hash(_ message: Data) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]

        var bytes = [UInt8](message)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] =
                    UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16
                    | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
            }
            for i in 16..<64 {
                let s0 =
                    rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var (a, b, c, d) = (h[0], h[1], h[2], h[3])
            var (e, f, g, hh) = (h[4], h[5], h[6], h[7])

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        return h.flatMap { word in
            [
                UInt8(truncatingIfNeeded: word >> 24),
                UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 8),
                UInt8(truncatingIfNeeded: word),
            ]
        }
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
