// Wave 11: the AppKit producer's own tests.
//
// Written before the renderer existed, and the first assertion is deliberately
// the one that would be satisfied by an empty tree — because a producer that
// emits nothing and a product with no defects are indistinguishable from the
// kernel's side, which is the failure `docs/adoption.md` records at length.
import AppKit
import VerdictUIKernel
import XCTest

@testable import VerdictUIAppKit

@MainActor
final class AppKitRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// A small, deliberately CLEAN view: a labelled button and a text field
    /// inside a container, all comfortably sized.
    private func cleanFixture() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        root.identifier = NSUserInterfaceItemIdentifier("settings-root")

        let title = NSTextField(labelWithString: "Startup Items")
        title.identifier = NSUserInterfaceItemIdentifier("title")
        title.frame = NSRect(x: 20, y: 150, width: 360, height: 24)
        root.addSubview(title)

        let button = NSButton(title: "Remove", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("remove-button")
        button.frame = NSRect(x: 20, y: 40, width: 120, height: 32)
        root.addSubview(button)

        let field = NSTextField(string: "search")
        field.isEditable = true
        field.identifier = NSUserInterfaceItemIdentifier("search-field")
        field.frame = NSRect(x: 200, y: 40, width: 180, height: 32)
        root.addSubview(field)

        return root
    }

    // MARK: - The producer produces something

    func testRendererEmitsANonEmptyTreeWithRealFrames() {
        let tree = AppKitRenderer.tree(for: cleanFixture())

        XCTAssertFalse(tree.children.isEmpty, "renderer emitted no children")
        let all = tree.flattened()
        XCTAssertGreaterThanOrEqual(all.count, 4, "expected root + 3 subviews, got \(all.count)")
        XCTAssertFalse(
            all.allSatisfy { $0.frame.isEmpty },
            "every frame was empty — no layout pass happened"
        )
    }

    func testRolesAreMappedFromAppKitClasses() {
        let tree = AppKitRenderer.tree(for: cleanFixture())
        let byID = Dictionary(
            uniqueKeysWithValues: tree.flattened().filter { !$0.id.isEmpty }.map { ($0.id, $0) })

        XCTAssertEqual(byID["remove-button"]?.role, .button)
        XCTAssertEqual(byID["title"]?.role, .text)
        XCTAssertEqual(byID["search-field"]?.role, .textField)
        XCTAssertEqual(byID["settings-root"]?.role, .container)
    }

    func testTextIsCarriedFromTheControl() {
        let tree = AppKitRenderer.tree(for: cleanFixture())
        let byID = Dictionary(
            uniqueKeysWithValues: tree.flattened().filter { !$0.id.isEmpty }.map { ($0.id, $0) })

        XCTAssertEqual(byID["title"]?.text, "Startup Items")
        XCTAssertEqual(byID["remove-button"]?.text, "Remove")
        XCTAssertEqual(byID["search-field"]?.text, "search")
    }

    /// Frames must be in ROOT coordinates, not the parent's — the tree contract
    /// says so, and getting it wrong shifts every nested node by its ancestors'
    /// origins, which reads as a layout defect the product does not have.
    func testFramesAreInRootCoordinates() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let middle = NSView(frame: NSRect(x: 50, y: 50, width: 200, height: 200))
        middle.identifier = NSUserInterfaceItemIdentifier("middle")
        let leaf = NSView(frame: NSRect(x: 10, y: 10, width: 40, height: 40))
        leaf.identifier = NSUserInterfaceItemIdentifier("leaf")
        middle.addSubview(leaf)
        root.addSubview(middle)

        let tree = AppKitRenderer.tree(for: root)
        let leafNode = try XCTUnwrap(tree.flattened().first { $0.id == "leaf" })
        // 50 + 10 in root space, NOT the 10 the leaf's own frame carries.
        XCTAssertEqual(leafNode.frame.x, 60, accuracy: 0.001)
    }

    /// AppKit's y axis points UP; the kernel's rules (and every SwiftUI-produced
    /// tree) use y-DOWN. A producer that emits the raw AppKit y would put the
    /// top of the screen at the bottom, and `OffscreenRule` would judge against
    /// a flipped surface.
    func testYAxisIsFlippedToTheKernelConvention() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let top = NSView(frame: NSRect(x: 0, y: 80, width: 200, height: 20))
        top.identifier = NSUserInterfaceItemIdentifier("top")
        root.addSubview(top)

        let tree = AppKitRenderer.tree(for: root)
        let node = try XCTUnwrap(tree.flattened().first { $0.id == "top" })
        // AppKit y=80 with height 20 in a 100-tall root is the TOP strip, which
        // in y-down coordinates starts at 0.
        XCTAssertEqual(node.frame.y, 0, accuracy: 0.001)
    }

    func testHiddenAndZeroAlphaViewsAreMarkedInvisible() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let hidden = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        hidden.identifier = NSUserInterfaceItemIdentifier("hidden")
        hidden.isHidden = true
        let transparent = NSView(frame: NSRect(x: 60, y: 0, width: 50, height: 50))
        transparent.identifier = NSUserInterfaceItemIdentifier("transparent")
        transparent.alphaValue = 0
        root.addSubview(hidden)
        root.addSubview(transparent)

        let tree = AppKitRenderer.tree(for: root)
        let byID = Dictionary(
            uniqueKeysWithValues: tree.flattened().filter { !$0.id.isEmpty }.map { ($0.id, $0) })
        XCTAssertEqual(byID["hidden"]?.isVisible, false)
        XCTAssertEqual(byID["transparent"]?.isVisible, false)
    }

    /// Every node carries a structural path, assigned by the KERNEL's own helper
    /// so the SwiftUI and AppKit producers cannot drift on identity.
    func testEveryNodeCarriesAStructuralPath() {
        let tree = AppKitRenderer.tree(for: cleanFixture())
        XCTAssertEqual(tree.structuralPath, "root")
        for node in tree.flattened() {
            XCTAssertFalse(node.structuralPath.isEmpty, "node \(node.id) has no structural path")
        }
    }

    /// A view with no `identifier` still needs an id, or `RuleEngine` refuses the
    /// whole tree as vacuous — and an AppKit developer sets `identifier` on
    /// approximately none of their views.
    func testUnidentifiedViewsGetSynthesizedIDsSoTheVerdictIsNotVacuous() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let child = NSButton(title: "Go", target: nil, action: nil)
        child.frame = NSRect(x: 10, y: 10, width: 80, height: 30)
        root.addSubview(child)

        let tree = AppKitRenderer.tree(for: root)
        XCTAssertFalse(
            tree.flattened().allSatisfy { $0.id.isEmpty },
            "no node carried an id — RuleEngine will call this verdict vacuous"
        )

        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "synthesized-ids")
        )
        XCTAssertFalse(
            verdict.findings.contains { $0.rule == RuleEngine.vacuousVerdictRule },
            "verdict was vacuous despite a populated tree"
        )
    }

    /// The viewport argument overrides the view's own frame, so a caller can ask
    /// "how does this look at 320 pt wide" without mutating their view.
    func testExplicitViewportResizesTheRootBeforeLayout() {
        let tree = AppKitRenderer.tree(
            for: cleanFixture(), viewport: CGSize(width: 320, height: 240))
        XCTAssertEqual(tree.frame.width, 320, accuracy: 0.001)
        XCTAssertEqual(tree.frame.height, 240, accuracy: 0.001)
    }

    // MARK: - Text metrics

    /// `TruncationRule` is silent without metrics, so a producer that omits them
    /// is quieter than it should be — which reads as a clean product.
    func testTextBearingNodesCarryTextMetrics() throws {
        let tree = AppKitRenderer.tree(for: cleanFixture())
        let title = try XCTUnwrap(tree.flattened().first { $0.id == "title" })
        let metrics = try XCTUnwrap(
            title.textMetrics, "no metrics: TruncationRule would be silent on this node")
        XCTAssertGreaterThan(metrics.intrinsicWidth, 0)
        XCTAssertGreaterThanOrEqual(metrics.renderedLineCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.idealLineCount, 1)
    }

    // MARK: - Positive control: the renderer can FAIL

    /// The control this whole target is worthless without. A view with text that
    /// genuinely overflows its frame must produce a FAILING verdict — otherwise
    /// "passes" means "the producer emitted nothing useful" and nothing here can
    /// tell the difference.
    func testOverflowingTextProducesAFailingVerdict() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        root.identifier = NSUserInterfaceItemIdentifier("overflow-root")

        let label = NSTextField(
            labelWithString:
                "Wireless Noise Cancelling Over-Ear Headphones With Extended Battery Life")
        label.identifier = NSUserInterfaceItemIdentifier("overflowing-label")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // Far narrower than the string needs: this is the defect.
        label.frame = NSRect(x: 10, y: 60, width: 90, height: 20)
        root.addSubview(label)

        let tree = AppKitRenderer.tree(for: root)
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "overflow-control")
        )

        XCTAssertEqual(
            verdict.status, .fail,
            "renderer could not detect text overflowing its frame — findings: "
                + "\(verdict.findings.map(\.rule))"
        )
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == "truncation" },
            "expected a truncation finding, got \(verdict.findings.map(\.rule))"
        )
    }

    /// A second, geometry-only control so the failure path does not depend
    /// solely on text measurement: two siblings placed on top of each other.
    func testOverlappingSiblingsProduceAFailingVerdict() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        root.identifier = NSUserInterfaceItemIdentifier("overlap-root")

        let first = NSButton(title: "First", target: nil, action: nil)
        first.identifier = NSUserInterfaceItemIdentifier("first")
        first.frame = NSRect(x: 20, y: 100, width: 140, height: 40)
        let second = NSButton(title: "Second", target: nil, action: nil)
        second.identifier = NSUserInterfaceItemIdentifier("second")
        // Deliberately overlapping `first` by 100 pt.
        second.frame = NSRect(x: 60, y: 100, width: 140, height: 40)
        root.addSubview(first)
        root.addSubview(second)

        let tree = AppKitRenderer.tree(for: root)
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "overlap-control")
        )
        XCTAssertEqual(
            verdict.status, .fail,
            "renderer could not detect overlapping siblings — findings: "
                + "\(verdict.findings.map(\.rule))")
    }

    /// The other half of the control, and the half that is usually missing. The
    /// two tests above prove the renderer can say FAIL; this proves it does not
    /// say FAIL indiscriminately. A producer that failed everything would pass
    /// both of them and be exactly as useless as one that passed everything.
    func testTheSameFixturesPassOnceTheDefectIsRemoved() {
        // Overflow control, widened to fit its text.
        let overflowRoot = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        overflowRoot.identifier = NSUserInterfaceItemIdentifier("widened-root")
        let label = NSTextField(
            labelWithString:
                "Wireless Noise Cancelling Over-Ear Headphones With Extended Battery Life")
        label.identifier = NSUserInterfaceItemIdentifier("widened-label")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.frame = NSRect(x: 10, y: 60, width: 560, height: 20)
        overflowRoot.addSubview(label)

        let widened = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: AppKitRenderer.tree(for: overflowRoot),
            context: .macOS(
                viewport: AppKitRenderer.tree(for: overflowRoot).frame, scenario: "widened")
        )
        XCTAssertFalse(
            widened.findings.contains { $0.rule == "truncation" },
            "text that fits still reported truncation: \(widened.findings.map(\.message))"
        )

        // Overlap control, separated.
        let overlapRoot = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        overlapRoot.identifier = NSUserInterfaceItemIdentifier("separated-root")
        let first = NSButton(title: "First", target: nil, action: nil)
        first.identifier = NSUserInterfaceItemIdentifier("sep-first")
        first.frame = NSRect(x: 20, y: 100, width: 140, height: 40)
        let second = NSButton(title: "Second", target: nil, action: nil)
        second.identifier = NSUserInterfaceItemIdentifier("sep-second")
        second.frame = NSRect(x: 200, y: 100, width: 140, height: 40)
        overlapRoot.addSubview(first)
        overlapRoot.addSubview(second)

        let separatedTree = AppKitRenderer.tree(for: overlapRoot)
        let separated = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: separatedTree,
            context: .macOS(viewport: separatedTree.frame, scenario: "separated")
        )
        XCTAssertFalse(
            separated.findings.contains { $0.rule.contains("overlap") },
            "separated siblings still reported overlap: \(separated.findings.map(\.message))"
        )
    }

    // MARK: - Opaque platform controls

    /// AppKit builds a control out of PRIVATE subviews the developer never wrote
    /// and cannot change — `NSScrollView` alone contributes a backdrop, a
    /// pocket, a banner, a blur and several dimming layers, all deliberately
    /// stacked on top of each other.
    ///
    /// Walking into them is not a cosmetic problem. Measured against PanoMac's
    /// real `StartupManagerViewController` layout before this boundary existed:
    /// 36 nodes, 19 of them AppKit internals, and a verdict of THIRTY findings —
    /// every one of them about `_NSScrollViewContentBackgroundView`,
    /// `NSScrollPocket` or `_NSBannerDecorationView` overlapping each other. Not
    /// one was actionable, and a real defect would have been invisible in the
    /// list.
    ///
    /// So a platform control is a LEAF: its own frame is reported, its innards
    /// are not. This is exactly the tier-2b argument in `docs/adoption.md` — a
    /// view you cannot edit gets probed from the outside, as `.custom(_:)`, and
    /// the verdict is a claim about the box rather than its contents.
    func testPlatformControlsAreLeavesRatherThanWalkedInto() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        root.identifier = NSUserInterfaceItemIdentifier("root")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.identifier = NSUserInterfaceItemIdentifier("scroll")
        scroll.hasVerticalScroller = true
        let table = NSTableView()
        table.identifier = NSUserInterfaceItemIdentifier("table")
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        scroll.documentView = table
        root.addSubview(scroll)
        // Force the scroll view to build its internal decoration layers.
        root.layoutSubtreeIfNeeded()

        let tree = AppKitRenderer.tree(for: root)
        let all = tree.flattened()

        // The developer's own views survive.
        XCTAssertTrue(all.contains { $0.id == "scroll" }, "the scroll view itself must be reported")

        // AppKit's privates do not. Matching on the leading underscore and the
        // known decoration class names, which is what AppKit actually calls them.
        let leaked = all.filter { node in
            guard case .custom(let name) = node.role else { return false }
            return name.hasPrefix("_") || name.contains("Pocket") || name.contains("Backdrop")
                || name.contains("Banner") || name.contains("Dimming")
        }
        XCTAssertTrue(
            leaked.isEmpty,
            "AppKit internals leaked into the tree: \(leaked.map { $0.role.identifier })"
        )
    }

    /// A control whose contents we DECLINE to walk must not be reported as
    /// EMPTY. Those are different claims, and conflating them is a false
    /// positive on the most ordinary screen there is.
    ///
    /// `EmptyContainerRule` polices `container`, `list` and `listRow`, and its
    /// own documentation says why `custom(_:)` is excluded: an unclassified node
    /// reported as an empty container "states more than the tree supports".
    /// That is exactly the situation here. `NSTableView` is an opaque leaf — its
    /// row views belong to AppKit — so mapping it to `.list` told the rule "this
    /// holds content" while the walk guaranteed it would never have children.
    ///
    /// Measured before the fix, against a table with THREE seeded rows: a
    /// warning that the enclosing view "reserves 720 x 480 pt but renders
    /// nothing". Seeding data did not help and could not, because the rows were
    /// never walked. Every table, outline and collection screen would trip this
    /// on first use — and a checker that is wrong on the first screen a new
    /// adopter tries is a checker they turn off.
    func testAnOpaqueCollectionIsNotReportedAsAnEmptyContainer() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        root.identifier = NSUserInterfaceItemIdentifier("root")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.identifier = NSUserInterfaceItemIdentifier("scroll")
        let table = NSTableView()
        table.identifier = NSUserInterfaceItemIdentifier("table")
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        scroll.documentView = table
        root.addSubview(scroll)
        root.layoutSubtreeIfNeeded()

        let tree = AppKitRenderer.tree(for: root)
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "opaque-collection")
        )

        XCTAssertFalse(
            verdict.findings.contains { $0.rule == "empty-container" },
            "a control we decline to walk was reported as empty: "
                + "\(verdict.findings.map { "\($0.rule) on \($0.nodeID)" })"
        )
    }

    /// The other half: a container the developer built and genuinely left empty
    /// must STILL be reported. Otherwise the fix above is indistinguishable from
    /// switching the rule off, and `EmptyContainerRule` stops earning its place.
    func testAGenuinelyEmptyDeveloperContainerIsStillReported() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        root.identifier = NSUserInterfaceItemIdentifier("root")
        let blank = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        blank.identifier = NSUserInterfaceItemIdentifier("blank-region")
        root.addSubview(blank)

        let tree = AppKitRenderer.tree(for: root)
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "genuinely-empty")
        )

        XCTAssertTrue(
            verdict.findings.contains { $0.rule == "empty-container" },
            "an empty container the developer wrote was not reported: "
                + "\(verdict.findings.map(\.rule))"
        )
    }

    /// The boundary must not swallow the developer's OWN content. A custom view
    /// the developer added inside a scroll view is theirs, is editable, and is
    /// exactly what they want judged — so the document view is walked even
    /// though the scroll view around it is a leaf.
    func testTheDocumentViewIsStillWalkedInsideAScrollView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.identifier = NSUserInterfaceItemIdentifier("scroll")
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        document.identifier = NSUserInterfaceItemIdentifier("document")
        let label = NSTextField(labelWithString: "Mine")
        label.identifier = NSUserInterfaceItemIdentifier("my-label")
        label.frame = NSRect(x: 10, y: 500, width: 100, height: 20)
        document.addSubview(label)
        scroll.documentView = document
        root.addSubview(scroll)
        root.layoutSubtreeIfNeeded()

        let ids = Set(AppKitRenderer.tree(for: root).flattened().map(\.id))
        XCTAssertTrue(ids.contains("document"), "the document view is the developer's own content")
        XCTAssertTrue(ids.contains("my-label"), "content inside the document view must be judged")
    }

    // MARK: - Round trip

    /// The AppKit tree must be the same WIRE SHAPE the SwiftUI producer emits,
    /// so `judge` cannot tell the two apart. Encoding and decoding it through
    /// the kernel's own Codable is the cheapest check of that
    /// (`docs/tree-contract.md`).
    func testTreeRoundTripsThroughTheWireFormatUnchanged() throws {
        let tree = AppKitRenderer.tree(for: cleanFixture())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tree)
        let decoded = try JSONDecoder().decode(SemanticNode.self, from: data)
        XCTAssertEqual(decoded, tree, "tree did not survive a JSON round trip")

        // And re-encoding the decoded tree must be byte-identical, which is what
        // baselines and diffs depend on.
        XCTAssertEqual(try encoder.encode(decoded), data)
    }

    // MARK: - Controller entry point

    func testControllerEntryPointRendersItsView() {
        let controller = NSViewController()
        let view = cleanFixture()
        controller.view = view

        let tree = AppKitRenderer.tree(for: controller)
        XCTAssertFalse(tree.children.isEmpty)
        XCTAssertTrue(tree.flattened().contains { $0.id == "remove-button" })
    }

    // MARK: - No window is required

    /// The whole point: layout happens off-screen. If the renderer ever needed a
    /// window, this test would be the one that noticed.
    func testNoWindowIsCreated() {
        let before = NSApplication.shared.windows.count
        _ = AppKitRenderer.tree(for: cleanFixture())
        XCTAssertEqual(
            NSApplication.shared.windows.count, before,
            "renderer created a window; it must lay out off-screen"
        )
    }
}
