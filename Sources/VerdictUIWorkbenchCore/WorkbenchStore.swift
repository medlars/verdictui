import Foundation
import VerdictUICLICore

/// Host-owned persistence: WebKit storage is never the source of project state.
@MainActor
public final class WorkbenchStore {
    public struct Project: Codable, Equatable, Sendable {
        public let path: String
        public let name: String
    }
    public struct History: Codable, Sendable {
        public let timestamp: Date
        public let project: String
        public let status: String
        public let report: ProjectCheckReport
    }
    private struct Saved: Codable {
        var projects: [Project] = []
        var selectedProject: String?
        var history: [History] = []
    }
    private var saved: Saved
    public let stateURL: URL
    public private(set) var loadError: String?
    public var projects: [Project] { saved.projects }
    public var selectedProject: String? { saved.selectedProject }
    public var history: [History] { saved.history }

    public init(stateURL: URL? = nil) {
        self.stateURL = stateURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VerdictUI/workbench/state.json")
        do {
            let data = try Data(contentsOf: self.stateURL)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            saved = try decoder.decode(Saved.self, from: data)
        } catch CocoaError.fileReadNoSuchFile { saved = Saved() }
        catch { saved = Saved(); loadError = "Saved projects could not be read. Add a project to begin." }
    }

    public func addProject(_ url: URL) throws {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.invalidProject
        }
        if !saved.projects.contains(where: { $0.path == root.path }) {
            saved.projects.append(Project(path: root.path, name: root.lastPathComponent))
        }
        saved.selectedProject = root.path
        try persist()
    }

    public func select(_ path: String) throws {
        guard saved.projects.contains(where: { $0.path == path }) else { throw Failure.invalidProject }
        saved.selectedProject = path
        try persist()
    }

    public func checks() throws -> ProjectChecks? {
        guard let path = selectedProject else { return nil }
        let file = URL(fileURLWithPath: path).appendingPathComponent(".verdictui/checks.json")
        if !FileManager.default.fileExists(atPath: file.path) { return nil }
        return try ProjectChecks.decode(Data(contentsOf: file))
    }

    public func saveChecks(_ data: Data) throws {
        guard let path = selectedProject else { throw Failure.invalidProject }
        let manifest = try ProjectChecks.decode(data)
        let directory = URL(fileURLWithPath: path).appendingPathComponent(".verdictui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("checks.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: file, options: .atomic)
    }

    public func record(_ report: ProjectCheckReport, project: String) throws {
        saved.history.insert(History(timestamp: Date(), project: project, status: report.status, report: report), at: 0)
        saved.history = Array(saved.history.prefix(20))
        try persist()
    }

    private func persist() throws {
        let parent = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(saved).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    public enum Failure: Error { case invalidProject, invalidMessage, busy }
}
