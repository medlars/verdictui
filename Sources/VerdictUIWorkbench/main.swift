import AppKit
import WebKit
import VerdictUIWorkbenchCore

/// Both normal startup and acceptance use the same real resources and bridge.
@MainActor
struct WorkbenchHost {
    let store: WorkbenchStore
    let view: WKWebView
    let bridge: WorkbenchBridge
    let executable: URL

    init(store: WorkbenchStore, size: CGSize) throws {
        let resourceBundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            // Older SwiftPM accessors can fall back to an absolute build path.
            // A packaged app must use its own resources even on a build machine.
            let packaged = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources/VerdictUI_VerdictUIWorkbench.bundle", isDirectory: true)
            guard let bundled = Bundle(url: packaged) else {
                throw NSError(domain: "WorkbenchResourcesUnavailable", code: 1)
            }
            resourceBundle = bundled
        } else {
            resourceBundle = .module
        }
        guard let bundle = resourceBundle.resourceURL else {
            throw NSError(domain: "WorkbenchResourcesUnavailable", code: 1)
        }
        let resources = bundle.appendingPathComponent("Resources")
        let page = resources.appendingPathComponent("index.html")
        let bundledCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/verdictui")
        let developmentCLI = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("verdictui")
        executable = FileManager.default.isExecutableFile(atPath: bundledCLI.path) ? bundledCLI : developmentCLI
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        bridge = WorkbenchBridge(store: store, executable: executable, page: page)
        bridge.attach(view)
        view.loadFileURL(page, allowingReadAccessTo: resources)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var bridge: WorkbenchBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--acceptance-config") {
            app.setActivationPolicy(.prohibited)
            Task { await WorkbenchAcceptance.launch(arguments: CommandLine.arguments) }
            return
        }
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VerdictUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem); app.mainMenu = menu

        let store = WorkbenchStore()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--project"), arguments.indices.contains(index + 1) {
            do { try store.addProject(URL(fileURLWithPath: arguments[index + 1])) }
            catch { NSLog("VerdictUI could not load the requested project") }
        }
        let host: WorkbenchHost
        do { host = try WorkbenchHost(store: store, size: CGSize(width: 1160, height: 800)) }
        catch { NSLog("VerdictUI resources could not be loaded"); app.terminate(nil); return }
        let view = host.view
        self.bridge = host.bridge
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "VerdictUI"; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.minSize = NSSize(width: 760, height: 600)
        window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        app.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.contains("--acceptance-config")
    }

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
