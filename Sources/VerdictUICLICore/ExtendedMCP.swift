import Foundation

/// Schemas and boundary validation for operations on external products.
enum ExtendedMCP {
    static var tools: [MCPTool] {
        let live: [String: MCPProperty] = [
            "pid": .init(type: "integer", description: "Positive process ID of a running app; use pid or app."),
            "app": .init(type: "string", description: "App bundle to launch as a fixture, then terminate; use app or pid."),
            "surface": .init(type: "string", description: "AX surface: window:0, menubar or extras."),
            "path": .init(type: "string", description: "Structural path returned by live_inspect."),
            "action": .init(type: "string", description: "Native verb: press, click, type, set-value, key, drag, hover or AX action."),
            "value": .init(type: "string", description: "Text, key chord, or drag destination x,y as appropriate."),
            "expect_text": .init(type: "string", description: "Text that must be observed after acting; mismatch is a FAIL verdict."),
            "timeout": .init(type: "number", description: "Observation deadline in seconds, positive and at most 60."),
        ]
        return [
            MCPTool(name: "live_inspect", description: "Read a real running macOS application's accessibility tree.", inputSchema: MCPSchema(properties: live)),
            MCPTool(name: "live_verify", description: "Judge a real application's current tree and optional expected text.", inputSchema: MCPSchema(properties: live)),
            MCPTool(name: "live_act", description: "Target one app, act, settle and return observed changes with a cited verdict. Input delivery alone does not prove the expected outcome.", inputSchema: MCPSchema(properties: live, required: ["path", "action"])),
        ] + webTools
    }

    static var webTools: [MCPTool] {
        let fields: [String: MCPProperty] = [
            "profile": .init(type: "string", description: "Isolated named browser identity, default 'default'. One owner at a time; cookies persist."),
            "url": .init(type: "string", description: "http, https or local file URL; credentials in URLs are refused."),
            "node": .init(type: "string", description: "Node ID returned by web_render."),
            "action": .init(type: "string", description: "click, type, credential, key or submit."),
            "text": .init(type: "string", description: "Nonsecret text. Password inputs require credential references."),
            "credential": .init(type: "string", description: "Credential name or op:// reference; never the resolved secret."),
            "key": .init(type: "string", description: "Key for key action, e.g. Enter or Tab."),
            "modifiers": .init(type: "string", description: "Comma-separated key modifiers."),
            "expect_text": .init(type: "string", description: "Expected visible text; absence yields a FAIL finding."),
        ]
        return [
            MCPTool(name: "web_list", description: "List this connection's owned headless browser sessions.", inputSchema: MCPSchema(properties: [:])),
            MCPTool(name: "web_open", description: "Open a real website in an invisible isolated browser; reuse this connection's named identity when already open.", inputSchema: MCPSchema(properties: fields, required: ["url"])),
            MCPTool(name: "web_render", description: "Read the rendered DOM and layout as a compact semantic tree.", inputSchema: MCPSchema(properties: fields)),
            MCPTool(name: "web_verify", description: "Judge the real page and optional expected visible text; failing UI is a successful answered call.", inputSchema: MCPSchema(properties: fields)),
            MCPTool(name: "web_act", description: "Send trusted browser input, settle, and return the observed verdict and change delta. Credential values stay inside the driver.", inputSchema: MCPSchema(properties: fields, required: ["action"])),
            MCPTool(name: "web_close", description: "Close this connection's named session and release its profile lock.", inputSchema: MCPSchema(properties: fields)),
        ]
    }

    static func webRequest(_ arguments: [String: MCPValue]) throws -> WebRequest {
        for name in ["profile", "url", "node", "action", "text", "credential", "key", "modifiers", "expect_text"] {
            if let value = arguments[name], value.stringValue == nil {
                throw LiveRuntime.Failure.invalidRequest("\(name) must be a string")
            }
        }
        return WebRequest(
            profile: arguments["profile"]?.stringValue ?? "default",
            url: arguments["url"]?.stringValue, action: arguments["action"]?.stringValue,
            node: arguments["node"]?.stringValue, text: arguments["text"]?.stringValue,
            credential: arguments["credential"]?.stringValue, key: arguments["key"]?.stringValue,
            modifiers: arguments["modifiers"]?.stringValue, expectText: arguments["expect_text"]?.stringValue
        )
    }

    static func liveRequest(_ arguments: [String: MCPValue]) throws -> LiveRequest {
        var pid: Int32?
        if let supplied = arguments["pid"] {
            guard let number = supplied.numberValue, let exact = Int32(exactly: number) else {
                throw LiveRuntime.Failure.invalidRequest("pid must be an integer")
            }
            pid = exact
        }
        var timeout = 5.0
        if let supplied = arguments["timeout"] {
            guard let number = supplied.numberValue else {
                throw LiveRuntime.Failure.invalidRequest("timeout must be numeric")
            }
            timeout = number
        }
        for name in ["app", "surface", "path", "action", "value", "expect_text"] {
            if let value = arguments[name], value.stringValue == nil {
                throw LiveRuntime.Failure.invalidRequest("\(name) must be a string")
            }
        }
        return LiveRequest(
            pid: pid, app: arguments["app"]?.stringValue,
            surface: arguments["surface"]?.stringValue ?? "window:0",
            path: arguments["path"]?.stringValue, action: arguments["action"]?.stringValue,
            value: arguments["value"]?.stringValue,
            expectText: arguments["expect_text"]?.stringValue, timeout: timeout
        )
    }
}
