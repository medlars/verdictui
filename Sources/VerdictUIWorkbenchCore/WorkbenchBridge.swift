import AppKit
import WebKit
import VerdictUICLICore
import VerdictUIWeb

/// Local-only web UI bridge; the web page cannot invoke arbitrary commands.
@MainActor
public final class WorkbenchBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let store: WorkbenchStore
    private let executable: URL
    private let page: URL
    private weak var webView: WKWebView?
    private var task: Task<Void, Never>?
    private var sessions: WebSessionManager?

    public init(store: WorkbenchStore, executable: URL, page: URL) {
        self.store = store; self.executable = executable; self.page = page.standardizedFileURL
    }

    public func attach(_ view: WKWebView) {
        webView = view
        view.navigationDelegate = self
        view.configuration.userContentController.add(self, name: "verdictui")
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                       didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL.path == page.path,
              let body = message.body as? [String: Any], let action = body["action"] as? String else {
            return
        }
        do {
            switch action {
            case "ready": sendState()
            case "chooseProject": chooseProject()
            case "selectProject":
                guard task == nil, let path = body["project"] as? String else { throw WorkbenchStore.Failure.busy }
                try store.select(path); sendState()
            case "saveChecks":
                guard task == nil, let checks = body["checks"] as? [[String: Any]] else { throw WorkbenchStore.Failure.invalidMessage }
                try store.saveChecks(JSONSerialization.data(withJSONObject: ["checks": checks])); sendState()
            case "run": runChecks()
            case "cancel": cancel()
            default: throw WorkbenchStore.Failure.invalidMessage
            }
        } catch { sendError("The request could not be completed. Check the target fields and try again.") }
    }

    public func chooseProject() {
        guard task == nil else { sendError("Wait for the current run or cancel it first."); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Add project"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.store.addProject(url); self?.sendState() }
            catch { self?.sendError("This folder could not be added.") }
        }
    }

    public func runChecks() {
        guard task == nil else { sendError("A verification run is already active."); return }
        guard let path = store.selectedProject else { sendError("Add a project before running checks."); return }
        let root = URL(fileURLWithPath: path)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-workbench-\(UUID().uuidString)")
        let manager = WebSessionManager(root: temporary)
        sessions = manager
        task = Task { [weak self] in
            guard let self else { return }
            var report = await ProjectCheckRuntime.run(root: root, executable: executable, sessions: manager) { [weak self] progress in
                self?.sendEncodable(progress, type: "progress")
            }
            let failures = await manager.closeAll()
            if failures.isEmpty { try? FileManager.default.removeItem(at: temporary) }
            else { report = report.unavailable(reason: "A browser could not finish closing. Its profile remains reserved.") }
            do { try store.record(report, project: path) }
            catch { sendError("The result could not be saved to history.") }
            sendEncodable(report, type: "result", key: "report")
            task = nil; sessions = nil
            sendState()
        }
    }

    public func cancel() {
        task?.cancel()
        if let sessions { Task { _ = await sessions.closeAll() } }
    }

    public func shutdown() async {
        task?.cancel()
        if let sessions { _ = await sessions.closeAll() }
        await task?.value
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "verdictui")
    }

    private func sendState() {
        struct State: Encodable {
            let projects: [WorkbenchStore.Project]
            let selectedProject: String?
            let checks: [ProjectChecks.Check]
            let history: [WorkbenchStore.History]
            let version: String
        }
        do {
            let checks = try store.checks()?.checks ?? []
            sendEncodable(State(projects: store.projects, selectedProject: store.selectedProject,
                                checks: checks, history: store.history, version: ReleaseVersion.current), type: "state")
            if let error = store.loadError { sendError(error) }
        } catch { sendError("The project's checks file is invalid. Correct .verdictui/checks.json to continue.") }
    }

    private func sendError(_ message: String) { send(["type": "error", "message": message]) }

    private func sendEncodable<Value: Encodable>(_ value: Value, type: String, key: String? = nil) {
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
            if let key { send(["type": type, key: object]) }
            else if var fields = object as? [String: Any] { fields["type"] = type; send(fields) }
        } catch { sendError("The verification result could not be displayed.") }
    }

    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        // Base64 data cannot terminate the JavaScript string or inject markup.
        let script = "window.verdictui?.receive(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(data.base64EncodedString())'),c=>c.charCodeAt(0)))))"
        webView?.evaluateJavaScript(script) { _, error in
            if error != nil { NSLog("VerdictUI workbench could not deliver a UI update") }
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                         decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.standardizedFileURL.path == page.path ? .allow : .cancel)
    }
}
