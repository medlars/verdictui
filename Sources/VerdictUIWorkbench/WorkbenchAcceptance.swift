import AppKit
import CryptoKit
import Foundation
import WebKit
import VerdictUIWorkbenchCore

/// Explicit product acceptance, never entered during ordinary application startup.
@MainActor
final class WorkbenchAcceptance {
    static let requiredPhases = ["connected", "project-selection", "edit-save", "consumer-pass", "consumer-fail",
                                 "running-motion", "cancellation", "history", "reload", "geometry"]
    struct Failure: Error, CustomStringConvertible { let description: String }
    private let root: URL
    private let projectA: URL
    private let projectB: URL
    private let fixtureURL: String
    private let deadline: ContinuousClock.Instant
    private let runID: String
    private let initialFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var host: WorkbenchHost
    private var phases: [[String: Any]] = []
    private var snapshots: [[String: Any]] = []
    private var assertions = 0

    static func launch(arguments: [String]) async {
        var driver: WorkbenchAcceptance?
        do {
            guard arguments.count == 3, arguments[1] == "--acceptance-config" else {
                throw Failure(description: "acceptance requires exactly one configuration path")
            }
            let value = try WorkbenchAcceptance(config: URL(fileURLWithPath: arguments[2]))
            driver = value
            try await value.run()
            await value.host.bridge.shutdown()
            try value.require(!NSApplication.shared.windows.contains { $0.isVisible || $0.isKeyWindow }, "acceptance opened a visible window")
            try value.finish(status: "pass", error: nil)
            exit(0)
        } catch {
            if let driver {
                await driver.host.bridge.shutdown()
                try? driver.finish(status: "unavailable", error: String(describing: error))
            }
            FileHandle.standardError.write(Data("Workbench acceptance unavailable: \(error)\n".utf8))
            exit(2)
        }
    }

    private init(config: URL) throws {
        let bytes = try Data(contentsOf: config)
        guard bytes.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["schema", "run_id", "output_root", "project_a", "project_b", "fixture_url", "timeout_seconds"]),
              object["schema"] as? Int == 1,
              let id = object["run_id"] as? String, UUID(uuidString: id) != nil,
              let output = object["output_root"] as? String,
              let a = object["project_a"] as? String, let b = object["project_b"] as? String,
              let fixture = object["fixture_url"] as? String, let url = URL(string: fixture),
              url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let timeout = object["timeout_seconds"] as? Double, timeout >= 1, timeout <= 300 else {
            throw Failure(description: "invalid acceptance configuration")
        }
        let owned = URL(fileURLWithPath: output).standardizedFileURL
        let first = URL(fileURLWithPath: a).standardizedFileURL
        let second = URL(fileURLWithPath: b).standardizedFileURL
        let permissions = try FileManager.default.attributesOfItem(atPath: owned.path)[.posixPermissions] as? Int
        guard owned.resolvingSymlinksInPath() == owned, permissions == 0o700,
              config.standardizedFileURL.deletingLastPathComponent() == owned,
              config.resolvingSymlinksInPath() == config.standardizedFileURL,
              !FileManager.default.fileExists(atPath: owned.appendingPathComponent("state.json").path),
              [first, second].allSatisfy({ $0.path.hasPrefix(owned.path + "/") && $0.resolvingSymlinksInPath() == $0
                  && $0.appendingPathComponent(".verdictui/checks.json").resolvingSymlinksInPath() == $0.appendingPathComponent(".verdictui/checks.json") }) else {
            throw Failure(description: "acceptance paths must stay inside their owned root")
        }
        root = owned; projectA = first; projectB = second
        runID = id; fixtureURL = fixture
        deadline = .now + .seconds(timeout)
        let store = WorkbenchStore(stateURL: root.appendingPathComponent("state.json"))
        try store.addProject(projectB); try store.addProject(projectA)
        host = try WorkbenchHost(store: store, size: CGSize(width: 1160, height: 800))
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        assertions += 1
    }

    private func evaluate(_ script: String) async throws -> Any? {
        guard ContinuousClock.now < deadline else { throw Failure(description: "acceptance deadline exceeded") }
        return try await host.view.evaluateJavaScript(script)
    }

    private func wait(_ expression: String) async throws {
        while ContinuousClock.now < deadline {
            if try await evaluate(expression) as? Bool == true { assertions += 1; return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "observed state did not arrive: \(expression.prefix(120))")
    }

    private func jsString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func click(_ selector: String) async throws {
        _ = try await evaluate("document.querySelector(\(try jsString(selector))).click()")
    }

    private func input(_ id: String, _ value: String, event: String = "input") async throws {
        _ = try await evaluate("{const e=document.getElementById(\(try jsString(id)));e.value=\(try jsString(value));e.dispatchEvent(new Event('\(event)',{bubbles:true}));}")
    }

    private func phase(_ id: String, _ observations: [String: Any] = [:]) {
        phases.append(["id": id, "status": "pass", "observations": observations])
    }

    private func save() async throws {
        _ = try await evaluate("document.getElementById('checks-form').requestSubmit()")
        try await wait("document.getElementById('save-status').textContent === 'No unsaved changes' && !document.getElementById('run-checks').disabled")
        try await click("[data-view='overview']")
    }

    private func runScenario(_ scenario: String, status: String, count: Int) async throws {
        try await click("[data-view='checks']")
        try await input("check-0-scenario", scenario)
        try await save()
        try require(try host.store.checks()?.checks.first?.scenario == scenario, "saved scenario differs")
        try await click("#run-checks")
        try await wait("document.getElementById('verification-stage').dataset.status === '\(status)' && !document.getElementById('run-checks').disabled")
        try require(host.store.history.count == count, "missing completed history entry")
        guard let report = host.store.history.first?.report,
              let verdict = report.checks.first?.verdict else { throw Failure(description: "consumer verdict absent") }
        try require(report.status == status && verdict.scenario == scenario, "consumer result did not match the requested scenario")
        if status == "fail" {
            try require(!verdict.findings.isEmpty, "failed consumer has no cited findings")
            try await wait("document.querySelectorAll('.finding-node').length > 0")
        }
        phase("consumer-\(status)", ["scenario": scenario, "status": report.status, "finding_count": verdict.findings.count])
        try await capture(status)
    }

    private func run() async throws {
        try await wait("document.readyState === 'complete' && document.getElementById('connection-label') !== null")
        try await wait("document.getElementById('connection-label').textContent === 'Engine connected' && !document.getElementById('run-checks').disabled")
        try require(host.store.selectedProject == projectA.path, "wrong initial project")
        phase("connected", ["helper": host.executable.path])
        try await capture("connected")
        _ = try await evaluate("Array.from(document.querySelectorAll('.project-button')).find(e=>e.title===\(try jsString(projectB.path))).click()")
        try await wait("document.getElementById('project-path').textContent === \(try jsString(projectB.path))")
        _ = try await evaluate("Array.from(document.querySelectorAll('.project-button')).find(e=>e.title===\(try jsString(projectA.path))).click()")
        try await wait("document.getElementById('project-path').textContent === \(try jsString(projectA.path))")
        try require(host.store.selectedProject == projectA.path, "project selection was not persisted")
        phase("project-selection")
        try await click("[data-view='checks']")
        try await input("check-0-name", "Saved consumer check")
        try await save()
        try require(try host.store.checks()?.checks.first?.name == "Saved consumer check", "form did not save the actual manifest")
        phase("edit-save")
        try await runScenario("consumer-settings", status: "pass", count: 1)
        try await runScenario("consumer-fault", status: "fail", count: 2)

        try await click("[data-view='checks']")
        try await input("check-0-kind", "web", event: "change")
        try await input("check-0-url", fixtureURL)
        try await save()
        try await click("#run-checks")
        try await wait("document.getElementById('verification-stage').dataset.status === 'running'")
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-request.json").path) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "actual browser never requested the controlled fixture") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reduced = try await evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches") as? Bool == true
        let firstMotion = try await evaluate("JSON.stringify(document.getAnimations().map(a=>({time:a.currentTime,state:a.playState})))") as? String
        try await capture("running-before")
        try await Task.sleep(for: .milliseconds(180))
        let secondMotion = try await evaluate("JSON.stringify(document.getAnimations().map(a=>({time:a.currentTime,state:a.playState})))") as? String
        try await capture("running-after")
        if reduced {
            try require(firstMotion == "[]" && secondMotion == "[]", "native running animation ignored reduced motion")
        } else {
            try require(firstMotion != nil && firstMotion != "[]" && firstMotion != secondMotion, "native running animation did not advance")
        }
        phase("running-motion", ["reduced_motion": reduced, "normal_motion_verified": !reduced,
                                  "os_reduced_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                  "before": firstMotion ?? "", "after": secondMotion ?? ""])
        try await click("#cancel-run")
        try await wait("document.getElementById('verification-stage').dataset.status === 'unavailable' && !document.getElementById('run-checks').disabled")
        try require(host.store.history.count == 3 && host.store.history.first?.report.status == "unavailable", "cancellation did not settle into its real report")
        phase("cancellation", ["status": host.store.history.first?.status ?? "missing"])
        try await click("[data-view='history']")
        try await wait("document.querySelectorAll('.history-row').length === 3")
        phase("history", ["count": 3])
        try await capture("history")
        await host.bridge.shutdown()
        host = try WorkbenchHost(store: WorkbenchStore(stateURL: root.appendingPathComponent("state.json")), size: CGSize(width: 1160, height: 800))
        try await wait("document.readyState === 'complete' && document.getElementById('connection-label') !== null")
        try await wait("document.getElementById('connection-label').textContent === 'Engine connected'")
        try require(host.store.history.count == 3 && host.store.selectedProject == projectA.path, "host recreation lost persisted history or project")
        try await click("[data-view='history']")
        try await wait("document.querySelectorAll('.history-row').length === 3")
        phase("reload", ["count": 3])
        _ = try await evaluate("document.querySelectorAll('.history-row button')[2].click()")
        try await wait("document.getElementById('verification-stage').dataset.status === 'pass'")
        var sizes: [[String: Any]] = []
        for size in [CGSize(width: 760, height: 600), CGSize(width: 1160, height: 800)] {
            host.view.setFrameSize(size)
            try await wait("innerWidth === \(Int(size.width)) && innerHeight === \(Int(size.height))")
            let measurements = try await evaluate(Self.geometryScript) as? String ?? ""
            guard let data = measurements.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(description: "DOM measurements absent") }
            try require(object["horizontal_overflow"] as? Bool == false, "workbench has horizontal overflow")
            sizes.append(object)
            if size.width == 760 { try await capture("compact") }
        }
        phase("geometry", ["viewports": sizes])
        try await capture("final")
        guard let tree = try await evaluate(Self.treeScript) as? String, let data = tree.data(using: .utf8), data.count < 8 * 1024 * 1024 else { throw Failure(description: "observed DOM tree absent or oversized") }
        try write(data, "final-tree.json")
        try require(phases.map { $0["id"] as? String } == Self.requiredPhases.map(Optional.some), "required workflow phase missing")
    }

    private func write(_ data: Data, _ name: String) throws {
        let path = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw Failure(description: "refusing to overwrite acceptance artifact") }
        try data.write(to: path, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func capture(_ name: String) async throws {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = host.view.bounds; configuration.afterScreenUpdates = true
        let image = try await host.view.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw Failure(description: "native PNG capture unavailable") }
        try write(data, "\(name).png")
        snapshots.append(["phase": name, "path": "\(name).png", "sha256": Self.hash(data), "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
                          "viewport": ["width": host.view.bounds.width, "height": host.view.bounds.height]])
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func finish(status: String, error: String?) throws {
        let treeURL = root.appendingPathComponent("final-tree.json")
        let tree = try? Data(contentsOf: treeURL)
        let state = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let report: [String: Any] = ["schema": 1, "run_id": runID, "status": status, "error": error ?? "",
            "required_phase_ids": Self.requiredPhases, "phases": phases, "assertions": assertions, "snapshots": snapshots,
            "history": ["path": "state.json", "sha256": Self.hash(state)],
            "final_tree": ["path": "final-tree.json", "sha256": tree.map(Self.hash) ?? "", "viewport": ["width": 1160, "height": 800]],
            "cleanup": ["bridge_shutdown_awaited": true, "visible_windows": NSApplication.shared.windows.filter { $0.isVisible || $0.isKeyWindow }.count],
            "frontmost_before": initialFocus ?? -1, "frontmost_after": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "limits": ["DOM programmatic input, not OS hardware input", "PNG paint requires separate independent review", "No Accessibility, native chooser/menu or notification assertion"]]
        try write(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), "native-report.json")
    }

    private static let geometryScript = #"""
    JSON.stringify({width:innerWidth,height:innerHeight,horizontal_overflow:document.documentElement.scrollWidth>innerWidth+1,controls:Array.from(document.querySelectorAll('button,input,select')).filter(e=>e.getClientRects().length).map(e=>{const r=e.getBoundingClientRect();return {id:e.id,text:e.innerText,x:r.x,y:r.y,width:r.width,height:r.height,disabled:e.disabled}})})
    """#

    private static let treeScript = #"""
    (()=>{let count=0;function walk(e,depth){if(++count>10000||depth>100)throw Error('DOM budget exceeded');const r=e.getBoundingClientRect(),s=getComputedStyle(e),tag=e.tagName.toLowerCase();let role=e.getAttribute('role')||({button:'button',input:'textField',textarea:'textField',select:'menu',img:'image',svg:'image',nav:'navigation',ul:'list',ol:'list',li:'listRow'})[tag]||(['p','h1','h2','h3','label','span'].includes(tag)?'text':'container');const visible=e.getClientRects().length>0&&s.visibility!=='hidden'&&s.display!=='none'&&Number(s.opacity)>0&&r.bottom>0&&r.right>0&&r.top<innerHeight&&r.left<innerWidth;return {id:e.id||'',role,frame:{x:r.x,y:r.y,width:r.width,height:r.height},text:(e.children.length?Array.from(e.childNodes).filter(n=>n.nodeType===3).map(n=>n.textContent).join(''):e.textContent).trim(),isVisible:visible,attributes:{'web.tag':tag,'web.observer':'WKWebView DOM'},children:Array.from(e.children).filter(c=>!['script','style','defs','symbol'].includes(c.tagName.toLowerCase())).map(c=>walk(c,depth+1))}}const tree=walk(document.body,0);tree.frame={x:0,y:0,width:innerWidth,height:innerHeight};return JSON.stringify(tree)})()
    """#
}
