// swift-tools-version: 5.10
// VerdictUI — SwiftUI verification engine.
// Targets:
//   VerdictUIKernel — platform-pure verdict engine (semantic tree, diff, lint, verdict schema).
//                     MUST NOT import SwiftUI/AppKit (enforced by PM stage_architecture).
//   VerdictUIProbe  — SwiftUI instrumentation runtime (Layout probes, preference keys, oracle host).
//   VerdictUIMacros — compiler plugin (SwiftSyntax). Builds for the HOST toolchain and never
//                     links into a shipping product; `.macro` rather than `.target` is what
//                     keeps that true (Tests/test_macro_isolation.py pins it).
//   VerdictUIMacroSupport — the library a consumer imports to get `@Verifiable`.
//                     Deliberately a SEPARATE product from VerdictUIProbe: depending on it
//                     drags in SwiftSyntax, the heaviest build-time cost in this package, so a
//                     consumer wanting probes without macros must be able to say so.
import CompilerPluginSupport
import PackageDescription

// Immaculate-build bar: complete strict-concurrency checking on every target so
// data-race issues surface at compile time, not in Wave 6's daemon at runtime.
// (Warnings-as-errors is enforced at the invocation layer — PM + CI pass
// `-Xswiftc -warnings-as-errors` — because putting unsafeFlags in the manifest
// would make the package unusable as a dependency for downstream consumers.)
let strictSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "VerdictUI",
    platforms: [
        // macOS 13, not 14. SwiftPM refuses a dependency whose floor is higher
        // than the consuming package's, and it names the PRODUCT rather than the
        // API responsible — so a floor raised for one call silently locks out
        // every app pinned lower, for a reason nothing in this repo reports.
        // LaunchGate targets .v13 and could not resolve VerdictUI at all until
        // `verdictNamedCoordinateSpace()` split the one macOS 14 call site.
        // Raising this again needs a no.md entry naming the API that forced it.
        .macOS(.v13)
    ],
    products: [
        .library(name: "VerdictUIKernel", targets: ["VerdictUIKernel"]),
        .library(name: "VerdictUIProbe", targets: ["VerdictUIProbe"]),
        // Opt-in. Naming it as its own product is the whole isolation mechanism:
        // `VerdictUIProbe` stays buildable without resolving SwiftSyntax at all.
        .library(name: "VerdictUIMacroSupport", targets: ["VerdictUIMacroSupport"]),
    ],
    dependencies: [
        // Pinned `exact`, not `from`. SwiftSyntax majors track the compiler
        // (6xx -> Swift 6.x), so this is a toolchain-coupled dependency and a
        // range would let it move under CI without a commit saying so — the
        // plan names version churn as this wave's top risk. 603.0.2 is the
        // newest 603 tag and was verified to build a plugin against the local
        // Swift 6.3.3 toolchain before being written here.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2")
    ],
    targets: [
        .target(name: "VerdictUIKernel", swiftSettings: strictSettings),
        .target(
            name: "VerdictUIProbe",
            dependencies: ["VerdictUIKernel"],
            swiftSettings: strictSettings
        ),
        // The compiler plugin. Runs at BUILD time in the host toolchain, so its
        // SwiftSyntax dependency is a cost of compiling, never of shipping —
        // `.macro` is what enforces that, and demoting it to `.target` would
        // link SwiftSyntax into every downstream product.
        //
        // No `strictSettings`: the plugin is a build-time tool that never
        // participates in the app's concurrency domain, and SwiftSyntax's own
        // types are not all Sendable under complete checking.
        .macro(
            name: "VerdictUIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        // What a consumer imports. Declares `@Verifiable` and points it at the
        // plugin; the expansion it generates calls into VerdictUIProbe, so the
        // dependency arrow runs macro-support -> probe and never back.
        .target(
            name: "VerdictUIMacroSupport",
            dependencies: ["VerdictUIMacros", "VerdictUIProbe", "VerdictUIKernel"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "VerdictUIDemoScenarios",
            dependencies: ["VerdictUIProbe", "VerdictUIKernel"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "VerdictUIDemo",
            dependencies: ["VerdictUIDemoScenarios", "VerdictUIProbe", "VerdictUIKernel"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "VerdictUIKernelTests",
            dependencies: ["VerdictUIKernel"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "VerdictUIProbeTests",
            // The demo catalog is a dependency of the probe's own test target so
            // Wave 2 Task 6's integration tests can render it there, alongside
            // the harness tests it belongs with.
            dependencies: ["VerdictUIProbe", "VerdictUIDemoScenarios"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "VerdictUIDemoScenariosTests",
            dependencies: ["VerdictUIDemoScenarios"],
            swiftSettings: strictSettings
        ),
        // Two dependencies, testing two different things. `VerdictUIMacros` +
        // SwiftSyntaxMacrosTestSupport asserts the expansion TEXT; the
        // `VerdictUIMacroSupport` import asserts that the expanded code
        // COMPILES and renders — a snapshot test alone cannot see a macro that
        // emits well-formed source referring to something that does not exist.
        .testTarget(
            name: "VerdictUIMacroTests",
            dependencies: [
                "VerdictUIMacros",
                "VerdictUIMacroSupport",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)
