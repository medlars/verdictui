import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIWitness

/// Tests for the AX normalization layer.
///
/// The role mapping and text extraction are pure functions over values the
/// accessibility server supplies, so they are tested directly. The end-to-end
/// read against a live window is a separate, slower test — see
/// `WitnessIntegrationTests` — because a unit test that needs a window server
/// is not a unit test and cannot run where `OracleHost` does.
final class AXReaderTests: XCTestCase {

    // MARK: - Role mapping

    /// The correspondence was MEASURED against a live window on 2026-08-12, not
    /// taken from documentation — see `docs/wave8-ax-findings.md`. These are the
    /// exact roles that tree contained.
    func testMeasuredRolesMapOntoTheSharedVocabulary() {
        let measured: [(String, Role)] = [
            ("AXStaticText", .text),
            ("AXButton", .button),
            ("AXCheckBox", .toggle),
            ("AXTextField", .textField),
            ("AXImage", .image),
            ("AXGroup", .container),
        ]
        for (axRole, expected) in measured {
            XCTAssertEqual(
                AXReader.role(axRole: axRole, subrole: nil), expected,
                "\(axRole) must map to \(expected.identifier)"
            )
        }
    }

    func testUnmappedRoleBecomesCustomCarryingTheRawString() {
        // Not `.container`. An unmapped element that defaults to a layout box
        // silently claims to be something it is not, and the reconciler then
        // reports a role disagreement against the probe channel — a finding
        // about this mapping table, filed against the user's UI.
        XCTAssertEqual(
            AXReader.role(axRole: "AXDisclosureTriangle", subrole: nil),
            .custom("AXDisclosureTriangle")
        )
    }

    func testEmptyRoleIsNamedRatherThanBlank() {
        // `Role.custom("")` fails the kernel's own schema (`minLength: 1`), so
        // an element publishing no role must not produce one.
        XCTAssertEqual(AXReader.role(axRole: "", subrole: nil), .custom("unknown"))
    }

    // MARK: - Failure vocabulary

    func testNoWindowAndNotTrustedAreDistinctFailures() {
        // The distinction is the whole point: AXIsProcessTrusted() returned
        // TRUE in every measured no-window case, so collapsing these two makes
        // the witness report a permission problem for a registration problem —
        // and sends the reader to System Settings to fix something that is
        // already granted.
        XCTAssertNotEqual(AXReader.Failure.notTrusted, .noWindow(axError: -25204))
        XCTAssertTrue(
            AXReader.Failure.noWindow(axError: -25204).description.contains("-25204"),
            "the AX error code must survive into the message; it is the only thing "
                + "that distinguishes the failure modes"
        )
        XCTAssertTrue(
            AXReader.Failure.notTrusted.description.contains("Accessibility"),
            "the permission failure must name the permission"
        )
    }

    func testAnUnreadableAnchorIsItsOwnFailureNotASilentZeroOrigin() {
        // The `?? .zero` this replaced was the dangerous kind of fallback: with no
        // readable hosting-group origin, every node keeps its SCREEN coordinates
        // (x in the hundreds) while the probe channel reports root coordinates, so
        // the reconciler reports a frame disagreement on EVERY node at once —
        // blaming the probe channel for the witness's own failure to read an anchor.
        //
        // It must also be DISTINCT from .noWindow: the window WAS read, and a zero
        // AXError would misreport the failure as a success code.
        XCTAssertNotEqual(AXReader.Failure.anchorUnreadable, .noWindow(axError: 0))
        XCTAssertTrue(
            AXReader.Failure.anchorUnreadable.description.contains("geometry"),
            "the failure must say what was unreadable, got: "
                + AXReader.Failure.anchorUnreadable.description)
    }

    // MARK: - Recursion bound

    func testTheWalkIsDepthBounded() {
        // An AXUIElement tree is a GRAPH the platform hands us, not a structure
        // we own: an element can reference an ancestor, and kAXChildrenAttribute
        // then yields a cycle. An unbounded walk crashed the runner with SIGSEGV
        // ("thread stack size exceeded due to excessive recursion") — and it read
        // as a FLAKY RUNNER rather than a defect, because the process died after
        // printing its per-test results, so --filter runs reported green.
        //
        // Asserting the constant is deliberately weak: this cannot construct a
        // cyclic AXUIElement (they come from the window server, not from a
        // caller), so what is pinned is that a bound EXISTS and is sane. The
        // crash itself is what proved it necessary; this stops the bound being
        // deleted as unused.
        XCTAssertGreaterThan(
            AXReader.maximumDepth, 8,
            "the bound must clear any real view hierarchy")
        XCTAssertLessThan(
            AXReader.maximumDepth, 400,
            "the bound must stay well inside the stack, or it cannot prevent the crash")
    }

    // MARK: - Coordinate conversion

    func testCoordinatesConvertRelativeToTheHostingGroupNotTheScreen() {
        // Measured tree: hosting group at screen y=777.0, Text at y=824.25.
        // Root-relative y must be 47.25 — no display metrics involved, so the
        // conversion survives a monitor change and a multi-screen setup.
        //
        // Anchoring on the WINDOW instead would add its 32 pt titlebar to every
        // node at once: a uniform offset that reads as a real disagreement on
        // every single node, which is how a correct probe channel gets accused.
        let hostingOrigin = CGPoint(x: 100.0, y: 777.0)
        let textOnScreen = CGRect(x: 211.0, y: 824.25, width: 78.0, height: 16.0)

        let converted = Rect(
            x: Double(textOnScreen.origin.x - hostingOrigin.x),
            y: Double(textOnScreen.origin.y - hostingOrigin.y),
            width: Double(textOnScreen.size.width),
            height: Double(textOnScreen.size.height)
        )

        XCTAssertEqual(converted.x, 111.0, accuracy: 0.001)
        XCTAssertEqual(converted.y, 47.25, accuracy: 0.001)
        XCTAssertEqual(converted.width, 78.0, accuracy: 0.001)
        XCTAssertEqual(converted.height, 16.0, accuracy: 0.001)
    }
}

// MARK: - A windows list that holds the application element (CTS-9E32C9AB)

extension AXReaderTests {

    /// THE DEFECT. `kAXWindowsAttribute` can answer `.success` with a list whose
    /// only element is the APPLICATION element itself — not a window. Every read
    /// site took `windows.first` on the strength of the status code alone, so the
    /// application element flowed on as if it were a window, its geometry read
    /// failed (AXPosition, AXSize and AXFrame are all `kAXErrorAttributeUnsupported`
    /// on an application element), and the caller was told
    /// "the host window published no geometry for its hosting group".
    ///
    /// That message names the HOSTING GROUP, so it sends every reader at layout
    /// and at the window server. The fact is simpler and different: this process
    /// publishes no readable window at all. FOUR sessions inherited the geometry
    /// framing from that string and recorded the work blocked on machine load,
    /// then on a fresh login session.
    ///
    /// MEASURED 2026-08-31 on a live witness host launched exactly as the suite
    /// launches it (LSUIElement `.app` via `/usr/bin/open`):
    ///     APP        role=AXApplication  posErr=-25205 sizeErr=-25205 AXFrame err=-25205
    ///     windows count=1
    ///     WINDOW[0]  role=AXApplication  posErr=-25205 sizeErr=-25205 AXFrame err=-25205
    /// POSITIVE CONTROL, same probe, same minute — Finder:
    ///     APP        role=AXApplication  AXFrame err=0
    ///     WINDOW[0]  role=AXScrollArea   AXFrame err=0 = (0,0,1728,1117)
    /// so the probe reads geometry where geometry exists; the zero is absence.
    ///
    /// The classification also decides RETRY. `WitnessHostProcess.waitForReady`
    /// retries on `.noWindow` ("still registering") and gives up on anything
    /// else, so a host mid-registration was being abandoned on the first read
    /// rather than waited for.
    func testTheApplicationElementIsNotAcceptedAsAWindow() {
        XCTAssertFalse(
            AXReader.isWindowElement(role: kAXApplicationRole as String),
            "the application element was accepted as a window; its geometry read then "
                + "fails and the caller is told the HOSTING GROUP has no geometry, which "
                + "sends them at layout instead of at an absent window"
        )
    }

    /// NEGATIVE CONTROL, and it is the half that matters. A predicate that
    /// rejected everything would satisfy the test above perfectly while making
    /// every window unreadable — including Finder's desktop, which publishes as
    /// `AXScrollArea` rather than `AXWindow`, so a strict `role == AXWindow`
    /// rule is also wrong (measured above).
    func testOrdinaryWindowRolesAreStillAccepted() {
        for role in [kAXWindowRole as String, "AXScrollArea", "AXGroup", "AXSheet"] {
            XCTAssertTrue(
                AXReader.isWindowElement(role: role),
                "\(role) was rejected as a window; the predicate is over-broad and would "
                    + "make real windows unreadable"
            )
        }
    }

    /// An element that publishes no role at all has not been shown to be a
    /// window, and "could not observe" must not read as "observed a window".
    func testAnElementWithNoRoleIsNotAWindow() {
        XCTAssertFalse(AXReader.isWindowElement(role: nil))
    }

    /// EVERY read site must apply it. The guard is duplicated verbatim at three
    /// places (`anchoredWindow`, `press(pid:named:)`, `readTree`), and a defect
    /// with N call sites cannot be closed at one of them (lesson 400).
    func testEveryWindowsAttributeReadGoesThroughOneGuard() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/VerdictUIWitness/AXReader.swift"),
            encoding: .utf8
        )
        let reads = source.components(separatedBy: "kAXWindowsAttribute as CFString").count - 1
        let callers = source.components(separatedBy: "try firstWindow(of: pid)").count - 1
        XCTAssertEqual(
            reads, 1,
            "the windows attribute must be read in exactly ONE place — firstWindow(of:) — "
                + "so the degenerate-list guard cannot be skipped at one site; found "
                + "\(reads) raw read(s)"
        )
        XCTAssertEqual(
            callers, 3,
            "all three read sites (anchoredWindow, press(pid:named:), readTree) must go "
                + "through the helper; found \(callers)"
        )
    }
}

extension AXReaderTests {

    /// `.noWindow(axError: 0)` means the call SUCCEEDED and returned nothing
    /// window-shaped. Rendering that as "AXError 0" sends the reader to look up
    /// an error code that does not exist, which is the same defect as naming the
    /// hosting group for an absent window: a true statement about the wrong
    /// subject.
    func testASuccessfulReadHoldingNoWindowDoesNotRenderAsAnErrorCode() {
        let text = AXReader.Failure.noWindow(axError: 0).description
        XCTAssertFalse(
            text.contains("AXError 0"),
            "a successful read that held no window is being reported as error code 0: \(text)"
        )
        XCTAssertTrue(text.contains("application element"), "the real cause is not named: \(text)")
    }

    /// NEGATIVE CONTROL. A real AXError must still carry its code, or the fix
    /// above would have traded a misleading message for a useless one.
    func testARealAXErrorStillCarriesItsCode() {
        let text = AXReader.Failure.noWindow(axError: -25202).description
        XCTAssertTrue(text.contains("-25202"), "the AXError code was dropped: \(text)")
    }
}
