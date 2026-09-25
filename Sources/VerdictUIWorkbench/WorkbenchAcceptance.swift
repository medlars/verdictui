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
    private let initialCursor = NSEvent.mouseLocation
    private let motionHost: String
    private lazy var motionRecorder = WorkbenchMotionRecorder(
        readNative: { [unowned self] in nativeMotionState() },
        write: { [unowned self] bytes, name in try write(bytes, name) })
    private lazy var motionResources = WorkbenchMotionResources(
        mode: motionHost == "invisible-window" ? .invisibleWindow : .detached,
        publisher: WorkbenchMotionPublisher(center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
    ) { [weak self] in
        guard let self else { return }
        if self.accessibilityChanges.count < 128 {
            self.accessibilityChanges.append(self.nativeMotionState())
        } else { self.accessibilityChangesDropped += 1 }
    }
    private var accessibilityChanges: [[String: Any]] = []
    private var accessibilityChangesDropped = 0
    private var host: WorkbenchHost
    private var phases: [[String: Any]] = []
    private var snapshots: [[String: Any]] = []
    private var assertions = 0
    private var loadedPage = ""

    static func launch(arguments: [String]) async {
        var driver: WorkbenchAcceptance?
        do {
            guard arguments.count == 3, arguments[1] == "--acceptance-config" else {
                throw Failure(description: "acceptance requires exactly one configuration path")
            }
            let value = try WorkbenchAcceptance(config: URL(fileURLWithPath: arguments[2]))
            driver = value
            let operation = Task { @MainActor in
                try await value.motionResources.withCleanup(
                    body: { try await value.run() },
                    shutdown: { await value.host.bridge.shutdown() })
            }
            // Only this explicit acceptance process changes its signal handling.
            // Cancellation reaches the bridge's awaited browser/helper shutdown.
            let signals = [SIGTERM, SIGINT].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { operation.cancel() }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() } }
            try await operation.value
            try value.require(!NSApplication.shared.windows.contains { $0.isVisible || $0.isKeyWindow }, "acceptance opened a visible window")
            try value.finish(status: "pass", error: nil)
            exit(0)
        } catch {
            if let driver {
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
              Set(object.keys).subtracting(["motion_host"]) == Set(["schema", "run_id", "output_root", "project_a", "project_b", "fixture_url", "timeout_seconds"]),
              object["motion_host"] == nil || ["detached", "invisible-window"].contains(object["motion_host"] as? String ?? ""),
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
        motionHost = object["motion_host"] as? String ?? "detached"
        deadline = .now + .seconds(timeout)
        let store = WorkbenchStore(stateURL: root.appendingPathComponent("state.json"))
        try store.addProject(projectB); try store.addProject(projectA)
        host = try WorkbenchHost(store: store, size: CGSize(width: 1160, height: 800))
        motionResources.attach(host.view)
    }

    private func nativeMotionState() -> [String: Any] {
        let cursor = NSEvent.mouseLocation
        return ["uptime_seconds": ProcessInfo.processInfo.systemUptime,
                "os_reduced_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "cursor": ["x": cursor.x, "y": cursor.y],
                "visible_windows": NSApplication.shared.windows.filter(\.isVisible).count,
                "key_windows": NSApplication.shared.windows.filter(\.isKeyWindow).count,
                "view_has_window": host.view.window != nil,
                "view_window_visible": host.view.window?.isVisible ?? false,
                "view_window_key": host.view.window?.isKeyWindow ?? false]
    }

    private func observeMotion(_ checkpoint: String) async throws {
        try await motionRecorder.observe(checkpoint) { try await evaluate(Self.motionScript) }
    }

    private static let motionScript = #"""
    (()=>{
      if(!window.__verdictMotionObservation) {
        const reduced=matchMedia('(prefers-reduced-motion: reduce)');
        const normal=matchMedia('(prefers-reduced-motion: no-preference)');
        const history=[];
        for(const query of [reduced,normal]) query.addEventListener('change',event=>{
          if(history.length<128) history.push({at:performance.now(),media:event.media,matches:event.matches});
          else history.dropped=(history.dropped??0)+1;
        });
        window.__verdictMotionObservation={reduced,normal,history,document_id:crypto.randomUUID(),animationIDs:new WeakMap(),nextAnimationID:1};
      }
      const observed=window.__verdictMotionObservation;
      return JSON.stringify({document_id:observed.document_id,at:performance.now(),reduced:observed.reduced.matches,
        no_preference:observed.normal.matches,changes:observed.history.slice(),changes_dropped:observed.history.dropped??0,
        visibility:document.visibilityState,hidden:document.hidden,user_agent:navigator.userAgent,
        stage:document.getElementById('verification-stage')?.dataset.status??null,
        animations:document.getAnimations().map(a=>{
          if(!observed.animationIDs.has(a)) observed.animationIDs.set(a,observed.nextAnimationID++);
          return {id:observed.animationIDs.get(a),name:a.animationName??'',time:a.currentTime,state:a.playState};
        }),
        transforms:['.lens-body','.lens-core','.lens-orbit','.lens-shine'].map(selector=>{
          const element=document.querySelector(selector);const style=element?getComputedStyle(element):null;
          return {selector,transform:style?.transform??null,animation:style?.animationName??null};
        })});
    })()
    """#

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        assertions += 1
    }

    private func evaluate(_ script: String) async throws -> Any? {
        try Task.checkCancellation()
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

    private func persistedCheck(_ project: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: project.appendingPathComponent(".verdictui/checks.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checks = object["checks"] as? [[String: Any]], checks.count == 1 else {
            throw Failure(description: "persisted editor declaration unavailable")
        }
        return checks[0]
    }

    private func editWebCheck() async throws -> [String: Any] {
        let original = try persistedCheck(projectB)
        guard original["kind"] as? String == "web", let runner = original["runner"] as? String,
              let subject = original["subject"] as? String else { throw Failure(description: "existing renderer declaration missing") }
        try await click("[data-view='checks']")
        try await input("check-0-name", "Saved rendered view")
        try await save()
        let renamed = try persistedCheck(projectB)
        var expected = original; expected["name"] = "Saved rendered view"
        try require(NSDictionary(dictionary: renamed).isEqual(to: expected), "name-only save changed renderer fields")
        try await click("[data-view='checks']")
        try await wait("document.getElementById('check-0-source').value === 'renderer'")
        try await capture("web-renderer")
        try await input("check-0-source", "url", event: "change")
        try await input("check-0-url", fixtureURL)
        try await input("check-0-expectText", "Controlled navigation")
        try await save()
        let urlMode = try persistedCheck(projectB)
        let expectedURL = ["name": "Saved rendered view", "kind": "web", "url": fixtureURL, "expectText": "Controlled navigation"]
        try require(NSDictionary(dictionary: urlMode).isEqual(to: expectedURL), "URL switch retained renderer fields or lost expected text")
        try await click("[data-view='checks']")
        try await input("check-0-source", "renderer", event: "change")
        try await input("check-0-runner", runner)
        try await input("check-0-subject", subject)
        try await save()
        let restored = try persistedCheck(projectB)
        try require(NSDictionary(dictionary: restored).isEqual(to: expected), "renderer switch retained URL fields or changed the renderer")
        return ["renderer_original": original, "renderer_renamed": renamed, "url_mode": urlMode, "renderer_restored": restored]
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
        try await observeMotion("page-ready")
        loadedPage = try packagedPage()
        try await wait("document.getElementById('connection-label').textContent === 'Engine connected' && !document.getElementById('run-checks').disabled")
        try require(host.store.selectedProject == projectA.path, "wrong initial project")
        phase("connected", ["helper": host.executable.path])
        try await capture("connected")
        _ = try await evaluate("Array.from(document.querySelectorAll('.project-button')).find(e=>e.title===\(try jsString(projectB.path))).click()")
        try await wait("document.getElementById('project-path').textContent === \(try jsString(projectB.path))")
        let webEditor = try await editWebCheck()
        _ = try await evaluate("Array.from(document.querySelectorAll('.project-button')).find(e=>e.title===\(try jsString(projectA.path))).click()")
        try await wait("document.getElementById('project-path').textContent === \(try jsString(projectA.path))")
        try require(host.store.selectedProject == projectA.path, "project selection was not persisted")
        phase("project-selection")
        try await click("[data-view='checks']")
        try await input("check-0-name", "Saved consumer check")
        try await save()
        try require(try host.store.checks()?.checks.first?.name == "Saved consumer check", "form did not save the actual manifest")
        phase("edit-save", ["web_editor": webEditor])
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
        try await observeMotion("running-before")
        let reduced = try WorkbenchAcceptanceValues.mediaBoolean(
            await evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches"))
        let firstMotion = try await evaluate("JSON.stringify(document.getAnimations().map(a=>({time:a.currentTime,state:a.playState})))") as? String
        try await capture("running-before")
        try await Task.sleep(for: .milliseconds(180))
        let secondMotion = try await evaluate("JSON.stringify(document.getAnimations().map(a=>({time:a.currentTime,state:a.playState})))") as? String
        try await observeMotion("running-after")
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
        motionResources.attach(host.view)
        try await wait("document.readyState === 'complete' && document.getElementById('connection-label') !== null")
        try await observeMotion("recreated-page-ready")
        try require(try packagedPage() == loadedPage, "host recreation changed the packaged page")
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
        // Negative control changes only this owned offscreen DOM, then removes
        // itself. Its observed tree must fail the real bundled browser judge.
        _ = try await evaluate("""
            (()=>{const panel=document.createElement('div');panel.id='acceptance-negative-fixture';
            panel.style.cssText='position:absolute;left:600px;top:650px;width:300px;height:100px';
            for(const [id,left] of [['acceptance-negative-a',0],['acceptance-negative-b',40]]) {
              const button=document.createElement('button');button.id=id;button.textContent=id;
              button.style.cssText=`position:absolute;left:${left}px;top:0;width:100px;height:50px`;panel.append(button);
            } document.body.append(panel);})()
            """)
        guard let negative = try await evaluate(Self.treeScript) as? String, let negativeData = negative.data(using: .utf8), negativeData.count < 8 * 1024 * 1024 else {
            throw Failure(description: "observed negative-control DOM tree absent or oversized")
        }
        try write(negativeData, "negative-tree.json")
        _ = try await evaluate("document.getElementById('acceptance-negative-fixture').remove()")
        try await wait("document.getElementById('acceptance-negative-fixture') === null")
        try require(phases.map { $0["id"] as? String } == Self.requiredPhases.map(Optional.some), "required workflow phase missing")
    }

    private func write(_ data: Data, _ name: String) throws {
        let path = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw Failure(description: "refusing to overwrite acceptance artifact") }
        try data.write(to: path, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func capture(_ name: String) async throws {
        try Task.checkCancellation()
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

    private func packagedPage() throws -> String {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let resources = bundle.appendingPathComponent("Contents/Resources/VerdictUI_VerdictUIWorkbench.bundle")
        guard let page = host.view.url, page.isFileURL,
              page.query == nil, page.fragment == nil else {
            throw Failure(description: "loaded page is not a packaged file URL")
        }
        let actual = page.standardizedFileURL
        try require(bundle.pathExtension == "app" && actual.lastPathComponent == "index.html"
            && actual.path.hasPrefix(resources.path + "/")
            && actual.resolvingSymlinksInPath() == actual, "loaded page is outside the packaged resource bundle")
        return page.absoluteString
    }

    private func finish(status: String, error: String?) throws {
        let treeURL = root.appendingPathComponent("final-tree.json")
        let tree = try? Data(contentsOf: treeURL)
        let state = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let negative = try? Data(contentsOf: root.appendingPathComponent("negative-tree.json"))
        let report: [String: Any] = ["schema": 1, "run_id": runID, "status": status, "error": error ?? "",
            "loaded_page": loadedPage,
            "required_phase_ids": Self.requiredPhases, "phases": phases, "assertions": assertions, "snapshots": snapshots,
            "history": ["path": "state.json", "sha256": Self.hash(state)],
            "final_tree": ["path": "final-tree.json", "sha256": tree.map(Self.hash) ?? "", "viewport": ["width": 1160, "height": 800]],
            "negative_tree": ["path": "negative-tree.json", "sha256": negative.map(Self.hash) ?? ""],
            "cleanup": ["bridge_shutdown_awaited": true, "visible_windows": NSApplication.shared.windows.filter { $0.isVisible || $0.isKeyWindow }.count],
            "frontmost_before": initialFocus ?? -1, "frontmost_after": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "motion_diagnostics": ["schema": 1, "host_mode": motionHost, "samples": motionRecorder.samples,
                                   "initial_frontmost_pid": initialFocus ?? -1,
                                   "initial_cursor": ["x": initialCursor.x, "y": initialCursor.y],
                                   "final_native": nativeMotionState(),
                                   "accessibility_changes": accessibilityChanges,
                                   "accessibility_changes_dropped": accessibilityChangesDropped,
                                   "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                                   "webkit_bundle_version": Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable",
                                   "environment_variable_names": ProcessInfo.processInfo.environment.keys.sorted()],
            "limits": ["DOM programmatic input, not OS hardware input", "PNG paint requires separate independent review", "No Accessibility, native chooser/menu or notification assertion"]]
        try write(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), "native-report.json")
    }

    private static let geometryScript = #"""
    JSON.stringify({width:innerWidth,height:innerHeight,horizontal_overflow:document.documentElement.scrollWidth>innerWidth+1,controls:Array.from(document.querySelectorAll('button,input,select')).filter(e=>e.getClientRects().length).map(e=>{const r=e.getBoundingClientRect();return {id:e.id,text:e.innerText,x:r.x,y:r.y,width:r.width,height:r.height,disabled:e.disabled}})})
    """#

    private static let treeScript = #"""
    (() => {
      let count = 0, fragments = 0;
      const rect = r => ({x:r.x,y:r.y,width:r.width,height:r.height});
      function store(a,key,r) { for(const [k,v] of Object.entries(rect(r))) a[key+k[0].toUpperCase()+k.slice(1)]=v; }
      function fixedBlock(s) {
        return ['transform','filter','perspective','translate','rotate','scale'].some(k=>s[k] && s[k]!=='none') ||
          /(?:^|\s)(layout|paint|strict|content)(?:\s|$)/.test(s.contain) ||
          s.willChange.split(',').some(v=>['transform','filter','perspective','contain','translate','rotate','scale'].includes(v.trim()));
      }
      function walk(n, depth, inherited) {
        if(++count>10000 || depth>100) throw Error('DOM budget exceeded');
        const text = n.nodeType===Node.TEXT_NODE;
        if(text && !n.textContent.trim()) return null;
        if(!text && n.nodeType!==Node.ELEMENT_NODE) return null;
        const e = text ? n.parentElement : n, tag=text?'#text':e.tagName.toLowerCase();
        if(['script','style','defs','symbol'].includes(tag)) return null;
        const s=getComputedStyle(e), range=text?document.createRange():null;
        if(range) range.selectNodeContents(n);
        const r=range?range.getBoundingClientRect():e.getBoundingClientRect();
        const role=text?'text':e.getAttribute('role')||({button:'button',input:'textField',textarea:'textField',select:'menu',img:'image',svg:'image',nav:'navigation',ul:'list',ol:'list',li:'listRow'})[tag]||'container';
        const focusable=!text && (e.tabIndex>=0 || e.isContentEditable===true);
        const clickable=!text && (['button','input','select','textarea'].includes(tag) || (tag==='a'&&e.hasAttribute('href')) || typeof e.onclick==='function');
        // Public WK DOM cannot enumerate event listeners. Only CSS-disabled,
        // non-focusable artwork has positively measured inert interaction.
        const measured=s.pointerEvents==='none'&&!focusable&&!clickable;
        const visible=inherited.visible && s.display!=='none' && !['hidden','collapse'].includes(s.visibility) && Number(s.opacity)>0 && (range?range.getClientRects():e.getClientRects()).length>0;
        let positioning=inherited.positioning;
        if(!text && ['absolute','fixed'].includes(s.position)) positioning={root:depth,block:s.position==='fixed'?inherited.fixed:inherited.absolute};
        const fixed=!text&&fixedBlock(s);
        const a={'web.tag':tag,'web.observer':'WKWebView DOM','web.frame':'main','web.domDepth':depth,
          'web.position':s.position,'web.overflowX':s.overflowX,'web.overflowY':s.overflowY,
          'web.fixedContainer':fixed,'web.scrollX':scrollX,'web.scrollY':scrollY,
          'web.isClickable':clickable,'web.isFocusable':focusable,'web.interactionMeasured':measured,
          'web.hasInteractiveAncestor':inherited.interactive,'web.pointerEvents':s.pointerEvents};
        if(positioning) { a['web.positioningRootDepth']=positioning.root; a['web.containingBlockDepth']=positioning.block; }
        if(!text&&e.id) a['web.id']=e.id;
        const label=!text&&(e.getAttribute('aria-label')||e.getAttribute('title'));
        if(label) a.accessibilityLabel=label;
        if(!text) a['web.enabled']=!e.disabled&&e.getAttribute('aria-disabled')!=='true';
        if(text || (!text&&s.display==='inline'&&e instanceof HTMLElement)) {
          const boxes=Array.from(range?range.getClientRects():e.getClientRects());
          fragments+=boxes.length; if(fragments>100000) throw Error('DOM fragment budget exceeded');
          const key=text?'web.textFragment':'web.inlineFragment';
          if(!text) a['web.inlineCandidate']=true;
          a[key+'Count']=boxes.length; boxes.forEach((box,i)=>store(a,key+i,box));
        }
        if(!text&&['auto','scroll'].some(v=>s.overflowX===v||s.overflowY===v)) {
          // Offset/client geometry is reliable here only without rotation/skew.
          const matrix=s.transform==='none'?null:new DOMMatrixReadOnly(s.transform);
          if(matrix && (!matrix.is2D || matrix.b!==0 || matrix.c!==0)) throw Error('Transformed scroll geometry unavailable');
          const sx=e.offsetWidth>0?r.width/e.offsetWidth:1, sy=e.offsetHeight>0?r.height/e.offsetHeight:1;
          store(a,'web.scrollViewport',{x:r.x+e.clientLeft*sx,y:r.y+e.clientTop*sy,width:e.clientWidth*sx,height:e.clientHeight*sy});
          store(a,'web.scrollBounds',{x:r.x+(e.clientLeft-e.scrollLeft)*sx,y:r.y+(e.clientTop-e.scrollTop)*sy,width:e.scrollWidth*sx,height:e.scrollHeight*sy});
        }
        const context={visible,interactive:inherited.interactive||focusable||clickable,positioning,
          absolute:!text&&(s.position!=='static'||fixed)?depth:inherited.absolute,fixed:fixed?depth:inherited.fixed};
        const children=text||['input','textarea'].includes(tag)?[]:Array.from(e.childNodes).map(c=>walk(c,depth+1,context)).filter(Boolean);
        const result={id:!text?e.id||'':'',role,frame:rect(r),text:text?n.textContent.trim():label||null,isVisible:visible,attributes:a,children};
        if(!text&&s.zIndex!=='auto'&&Number.isFinite(Number(s.zIndex))) result.zIndex=Number(s.zIndex);
        return result;
      }
      const tree=walk(document.body,1,{visible:true,interactive:false,positioning:null,absolute:-1,fixed:-1});
      tree.frame={x:0,y:0,width:innerWidth,height:innerHeight};
      store(tree.attributes,'web.documentViewport',tree.frame);
      store(tree.attributes,'web.documentBounds',{x:-scrollX,y:-scrollY,width:Math.max(innerWidth,document.documentElement.scrollWidth),height:Math.max(innerHeight,document.documentElement.scrollHeight)});
      return JSON.stringify(tree);
    })()
    """#
}
