import VerdictUIKernel
import XCTest

@testable import VerdictUIMacros

/// Keeps `BodyProbeWalk.recognisedElements` in agreement with the kernel's
/// `Role` vocabulary.
///
/// The plugin cannot import `VerdictUIKernel` — it builds for the HOST
/// toolchain, and linking the kernel into it would put a shipping module in a
/// build-time tool — so the roles it emits are string literals. That is two
/// spellings of one fact in two modules that never see each other, which is the
/// shape lesson 284 names: each copy's tests assert it against itself, so the
/// divergence is invisible from either side.
///
/// This test target CAN see both, so it is where the agreement is asserted.
final class RoleVocabularyTests: XCTestCase {
    func testEveryEmittedRoleIsARealKernelRole() {
        for (element, role) in BodyProbeWalk.recognisedElements {
            let reconstructed = Role(identifier: role)
            XCTAssertEqual(
                reconstructed.identifier,
                role,
                "The walk emits '.\(role)' for \(element), which the kernel does not know: it "
                    + "decodes to \(reconstructed). A role the kernel does not know becomes "
                    + "Role.custom, and every rule that switches on a known role goes silent "
                    + "on that element."
            )
            XCTAssertFalse(
                isCustom(reconstructed),
                "'.\(role)' decodes to Role.custom, so \(element) would be probed with a role "
                    + "no rule recognises — a silent loss of coverage, not a compile error."
            )
        }
    }

    func testTheDemoCatalogIsOutOfTheMacrosReachByDesign() {
        // Records WHY Wave 4's exit-gate line "differential test green: macro
        // tree ≡ hand-probed tree on all demo scenarios" is satisfied by
        // `testTheMacroMatchesHandProbingAcrossEveryRecognisedElement` rather
        // than by macro twins of the six demo scenarios — and pins the two facts
        // that make macro twins impossible, so the reasoning fails loudly if
        // either changes.
        //
        // (a) The demo scenarios use author-chosen SEMANTIC ids
        //     (`save-button`, `card-layer`) because rule assertions and Wave 5
        //     baselines key on them. The macro mints POSITIONAL ids from a
        //     per-role counter, so the two schemes cannot agree and a "twin"
        //     would be a different tree by construction.
        // (b) `CleanSettingsScenario` declares layering as `.custom("zstack")`
        //     and rows as `.container`. The walk emits neither, so the one probe
        //     channel that keeps `sibling-overlap` silent on that scenario is
        //     unreachable through the macro.
        //
        // This is not a limitation to fix. Hand probes exist precisely for
        // semantics a syntax-level walk cannot infer, and a macro that guessed
        // at `.custom("zstack")` would be inventing intent — the hybrid tier in
        // `docs/adoption.md`.
        XCTAssertFalse(
            BodyProbeWalk.recognisedElements.values.contains { $0.hasPrefix("custom") },
            "The walk gained a custom role; the demo-catalog reasoning above needs revisiting."
        )
        XCTAssertFalse(
            BodyProbeWalk.recognisedElements.values.contains("container"),
            "The walk gained a container role; the demo-catalog reasoning above needs revisiting."
        )
    }

    func testTheWalkRecognisesTheElementsThePlanNames() {
        // The wave plan names these six by name. Pinning them stops the table
        // from silently shrinking: a walk that recognises nothing still passes
        // the agreement test above, because an empty table has no disagreements.
        for element in ["Text", "Button", "Toggle", "TextField", "Image", "List"] {
            XCTAssertNotNil(
                BodyProbeWalk.recognisedElements[element],
                "\(element) is named by the Wave 4 plan but the walk does not recognise it."
            )
        }
    }

    func testInteractiveElementsAreProbedWithInteractiveRoles() throws {
        // `TapTargetRule` polices `Role.isInteractive`. If the walk filed a
        // Button as `.text`, the rule would not measure it and an untappable
        // button would pass — the engine reporting a broken screen as fine,
        // which is this product's worst failure.
        for element in ["Button", "Toggle", "TextField"] {
            let identifier = try XCTUnwrap(
                BodyProbeWalk.recognisedElements[element],
                "\(element) is not recognised at all, so this test cannot discriminate."
            )
            let role = Role(identifier: identifier)
            XCTAssertTrue(
                role.isInteractive,
                "\(element) is probed as '.\(role.identifier)', which TapTargetRule ignores."
            )
        }
    }

    private func isCustom(_ role: Role) -> Bool {
        if case .custom = role { return true }
        return false
    }
}
