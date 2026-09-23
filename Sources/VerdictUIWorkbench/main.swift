import AppKit
import WebKit
import VerdictUIWorkbenchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var bridge: WorkbenchBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VerdictUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); app.mainMenu = menu

        let resources = Bundle.module.resourceURL!.appendingPathComponent("Resources")
        let page = resources.appendingPathComponent("index.html")
        let store = WorkbenchStore()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--project"), arguments.indices.contains(index + 1) {
            do { try store.addProject(URL(fileURLWithPath: arguments[index + 1])) }
            catch { NSLog("VerdictUI could not load the requested project") }
        }
        let bundledCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/verdictui")
        let developmentCLI = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().appendingPathComponent("verdictui")
        let executable = FileManager.default.isExecutableFile(atPath: bundledCLI.path) ? bundledCLI : developmentCLI
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        let bridge = WorkbenchBridge(store: store, executable: executable, page: page)
        bridge.attach(view); self.bridge = bridge
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "VerdictUI"; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.minSize = NSSize(width: 760, height: 600)
        window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        view.loadFileURL(page, allowingReadAccessTo: resources)
        app.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let bridge else { return .terminateNow }
        Task { await bridge.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
