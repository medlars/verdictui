import Foundation
import VerdictUIWeb

/// Data-only browser request. Credential fields contain references, never resolved values.
public struct WebRequest: Codable, Sendable, Equatable {
    public var profile: String
    public var url: String?
    public var action: String?
    public var node: String?
    public var text: String?
    public var credential: String?
    public var key: String?
    public var modifiers: String?
    public var expectText: String?

    public init(
        profile: String = "default", url: String? = nil, action: String? = nil,
        node: String? = nil, text: String? = nil, credential: String? = nil,
        key: String? = nil, modifiers: String? = nil, expectText: String? = nil
    ) {
        self.profile = profile
        self.url = url
        self.action = action
        self.node = node
        self.text = text
        self.credential = credential
        self.key = key
        self.modifiers = modifiers
        self.expectText = expectText
    }
}

enum WebRuntime {
    static func handle(_ request: WebRequest, method: String, sessions: WebSessionManager) async throws -> DaemonResult {
        switch method {
        case "web_list": return .webSessions(await sessions.list())
        case "web_open":
            guard let raw = request.url, let url = URL(string: raw) else {
                throw LiveRuntime.Failure.invalidRequest("web_open requires a valid URL")
            }
            return .webSessions([try await sessions.open(profile: request.profile, url: url)])
        case "web_render": return .tree(try await sessions.render(profile: request.profile))
        case "web_verify": return .verdict(try await sessions.verify(profile: request.profile, expectText: request.expectText))
        case "web_close":
            try await sessions.close(profile: request.profile)
            return .webSessions(await sessions.list())
        case "web_act":
            return .verdict(try await sessions.act(
                profile: request.profile, action: action(request), expectText: request.expectText
            ))
        default: throw LiveRuntime.Failure.invalidRequest("unknown web operation")
        }
    }

    static func action(_ request: WebRequest) throws -> WebAction {
        switch request.action {
        case "click", "submit", "type", "credential":
            guard let node = request.node, !node.isEmpty else {
                throw LiveRuntime.Failure.invalidRequest("web action requires node from web_render")
            }
            switch request.action {
            case "click": return .click(nodeID: node)
            case "submit": return .submit(nodeID: node)
            case "credential":
                guard let reference = request.credential, !reference.isEmpty, request.text == nil else {
                    throw LiveRuntime.Failure.invalidRequest("credential action requires a reference and forbids literal text")
                }
                return .credential(nodeID: node, reference: reference)
            default:
                guard let text = request.text, request.credential == nil else {
                    throw LiveRuntime.Failure.invalidRequest("type requires text; use credential for secrets")
                }
                return .type(nodeID: node, text: text)
            }
        case "key":
            guard let key = request.key, !key.isEmpty else {
                throw LiveRuntime.Failure.invalidRequest("key action requires a key")
            }
            return .key(nodeID: request.node, key: key, modifiers: (request.modifiers ?? "").split(separator: ",").map(String.init))
        default: throw LiveRuntime.Failure.invalidRequest("web action must be click, type, credential, key or submit")
        }
    }
}
