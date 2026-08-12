// Wave 7: the MCP stdio surface.
//
// This is a TRANSPORT, deliberately. Every tool it exposes routes into
// `VerdictDaemon.handle`, which is the same method surface the CLI and the
// socket daemon use — so the three cannot disagree about what `verify` means. A
// second implementation here is how three surfaces drift into three answers.
import Foundation
import VerdictUIKernel
import VerdictUIProbe

/// A tool as MCP describes it.
public struct MCPTool: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON Schema for the tool's arguments, as MCP requires.
    public let inputSchema: MCPSchema

    public init(name: String, description: String, inputSchema: MCPSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// The subset of JSON Schema the tools need.
public struct MCPSchema: Codable, Sendable, Equatable {
    public let type: String
    public let properties: [String: MCPProperty]
    public let required: [String]

    public init(properties: [String: MCPProperty], required: [String] = []) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

/// One argument's schema.
public struct MCPProperty: Codable, Sendable, Equatable {
    public let type: String
    public let description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

/// The MCP tool catalog and its dispatch into the engine.
public enum MCPServer {
    /// Every tool this server exposes.
    ///
    /// ### What is deliberately absent
    ///
    /// `baseline_accept`. The plan's Wave 7 task list names it with a
    /// `confirm: true` argument, and that was reconsidered against SD4: a
    /// boolean an agent sets as easily as it omits is a speed bump, not a gate,
    /// and the thing it guards is unrecoverable — accepting a baseline replaces
    /// the record of what a screen SHOULD look like. The exit-gate item
    /// "destructive baseline-accept requires explicit confirm" is met more
    /// strongly by not offering the verb: `verdictui baseline --update --accept`
    /// stays a foreground command a human runs and watches.
    public static var tools: [MCPTool] {
        let scenario = MCPProperty(
            type: "string",
            description: "Scenario name, as returned by list_scenarios."
        )
        return [
            MCPTool(
                name: "list_scenarios",
                description: "Every scenario that can be rendered and verified.",
                inputSchema: MCPSchema(properties: [:])
            ),
            MCPTool(
                name: "render",
                description:
                    "Render a scenario and return its semantic tree in the compact wire form "
                    + "(parallel arrays + parent index, interned strings). Sets truncated:true "
                    + "when the tree was cut to fit.",
                inputSchema: MCPSchema(properties: ["scenario": scenario], required: ["scenario"])
            ),
            MCPTool(
                name: "verify",
                description:
                    "Render a scenario and judge it. Returns a verdict whose every finding "
                    + "cites a rule and a node id. A FAILING verdict is a SUCCESSFUL call — "
                    + "isError is set only when no verdict could be produced at all.",
                inputSchema: MCPSchema(
                    properties: [
                        "scenario": scenario,
                        "baseline": MCPProperty(
                            type: "boolean",
                            description: "Also compare against the recorded baseline."
                        ),
                        "cross_validate": MCPProperty(
                            type: "boolean",
                            description:
                                "Also reconcile the in-process tree against the platform's "
                                + "accessibility tree — an independent channel that catches a "
                                + "probe misreporting what it renders. Needs a windowed session "
                                + "and an Accessibility grant; when it cannot run, the verdict "
                                + "carries a cross-validation-skipped warning rather than "
                                + "passing more quietly."
                        ),
                    ],
                    required: ["scenario"]
                )
            ),
            MCPTool(
                name: "focus",
                description:
                    "Return the subtree rooted at one node. The follow-up to a tree that came "
                    + "back with truncated:true — name the node you want and get its full "
                    + "contents, instead of re-rendering the whole screen at a bigger budget. "
                    + "node_path is a structuralPath or a probe id, exactly as render publishes "
                    + "and every finding cites.",
                inputSchema: MCPSchema(
                    properties: [
                        "scenario": scenario,
                        "node_path": MCPProperty(
                            type: "string",
                            description:
                                "structuralPath (e.g. root/container[0]/text[2]) or probe id of "
                                + "the node to expand."
                        ),
                    ],
                    required: ["scenario", "node_path"]
                )
            ),
            MCPTool(
                name: "act",
                description:
                    "Act on a probed control and observe what changed: capture, act, settle, "
                    + "capture, diff, lint — one call. Returns the DELTA (what appeared, "
                    + "vanished, moved or changed) plus a verdict, not the whole tree; pass "
                    + "include_tree:true when you need the full after-tree. 'settled' reports "
                    + "whether the UI went quiet before the deadline, which is a separate "
                    + "claim from whether it passed.",
                inputSchema: MCPSchema(
                    properties: [
                        "scenario": scenario,
                        "action": MCPProperty(
                            type: "string",
                            description:
                                "One of: " + DaemonAction.kinds.joined(separator: ", ") + "."
                        ),
                        "probe": MCPProperty(
                            type: "string",
                            description: "Probe id to act on, as it appears in a rendered tree."
                        ),
                        "text": MCPProperty(
                            type: "string",
                            description: "Text to type. Required by setText."
                        ),
                        "value": MCPProperty(
                            type: "number",
                            description: "Value to set. Required by setSlider."
                        ),
                        "include_tree": MCPProperty(
                            type: "boolean",
                            description: "Also return the whole after-tree, not just the delta."
                        ),
                    ],
                    required: ["scenario", "action", "probe"]
                )
            ),
            MCPTool(
                name: "sweep",
                description:
                    "Render a scenario across a variant matrix; one verdict per cell plus a "
                    + "rule × variant grid. A cell that could not render is reported as "
                    + "unmeasured and makes the whole sweep not-clean.",
                inputSchema: MCPSchema(properties: ["scenario": scenario], required: ["scenario"])
            ),
            MCPTool(
                name: "baseline_diff",
                description:
                    "Findings describing how a scenario has drifted from its recorded "
                    + "baseline. Writes nothing.",
                inputSchema: MCPSchema(properties: ["scenario": scenario], required: ["scenario"])
            ),
        ]
    }

    /// Map an MCP tool name onto the daemon method that serves it.
    ///
    /// A table rather than a switch inside the transport, so
    /// `MCPServerTests.testEveryAdvertisedToolResolvesToADaemonMethod` can walk
    /// the catalog and prove no tool is advertised that nothing serves — the
    /// failure where a client sees a verb, calls it, and gets "unknown method".
    public static func daemonMethod(for tool: String) -> String? {
        switch tool {
        case "list_scenarios": return "list"
        case "render": return "render"
        case "focus": return "focus"
        case "verify": return "verify"
        case "act": return "act"
        case "sweep": return "sweep"
        case "baseline_diff": return "baseline_diff"
        default: return nil
        }
    }
}
