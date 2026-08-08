# ADR 2026-006 — The deployment floor tracks the lowest fleet target, not the newest API

**Date:** 2026-08-08
**Status:** Active
**Author:** first external-consumer trial (LaunchGate)

## Context

VerdictUI declared `platforms: [.macOS(.v14)]`. SwiftPM refuses to resolve a dependency
whose minimum platform is higher than the consuming package's, and the error names the
**product**, never the API responsible:

```
error: the executable 'Probe' requires macos 13.0, but depends on the product
'VerdictUIProbe' which requires macos 14.0
```

LaunchGate targets `.macOS(.v13)`, so it could not consume VerdictUI **at all**. The
failure is invisible from inside this repo: every test passed, CI was green, and nothing
here can observe a consumer failing to resolve. The package looked broadly unusable for
a reason no signal in the project reported.

The entire floor came from **one line**. Lowering the manifest and reading the compiler
produced 4 errors, all at `VerdictProbe.swift:421`, which called the macOS 14
`.coordinateSpace(.named(_:))` overload. The reader side
(`GeometryProxy.frame(in: .named(_:))`) is macOS 12+ and never needed splitting.

## Decision

The floor is **`.macOS(.v13)`** — the lowest target among fleet apps that consume this
package. The single macOS 14 call site is split by availability in
`View.verdictNamedCoordinateSpace()`.

Raising the floor again requires a `no.md` entry naming the API that forced it. Two
guards enforce this: `TestDeploymentFloor::test_the_package_floor_stays_at_the_lowest_fleet_target`
(with a mutation row) and `test_no_source_file_hard_codes_a_macos_14_only_api`.

## Alternatives considered

1. **Keep `.v14` and tell consumers to raise their floor.** Rejected: it inverts the
   dependency. A verification library is adopted *into* existing apps; requiring the app
   under test to move its deployment target to be verifiable is an adoption cost no
   consumer will pay, and adoption is what the product's own research names as the
   thing instrumentation tools die from.
2. **Call the deprecated `coordinateSpace(name:)` unconditionally.** Rejected on
   measurement: it is deprecated on macOS 14+, and this package builds with
   `-warnings-as-errors`, so the bare call is a **build failure here**. The
   `@ViewBuilder` + `if #available` split satisfies both compilers.
3. **`@available(macOS 14, *)` on the probe API itself.** Rejected: it pushes the same
   problem onto every call site in every consumer and fragments the public surface —
   the one thing a consumer must not have to think about is which SwiftUI vintage the
   probe wants.

## Consequences

- Verified in **both** directions with a scratch `.macOS(.v13)` package: SwiftPM refusal
  before the change, `Build complete!` after.
- The full suite passes unchanged at the lower floor: 365 tests, 0 failures, 0 warnings.
- Any future macOS 14+ API in `VerdictUIProbe` must be availability-split rather than
  raise the manifest, or the guards fail.
- `VerdictUIKernel` was never affected — it is platform-pure by ADR and imports no UI
  framework at all.

## Rollback

Restore `.macOS(.v14)` in `Package.swift`, inline the `#available` split back to the
bare macOS 14 call, and delete `TestDeploymentFloor` plus its mutation row. This
re-locks out every consumer pinned below 14, so roll back only if the fleet's minimum
target moves to 14 across the board.
