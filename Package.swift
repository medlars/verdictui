// swift-tools-version: 5.10
// VerdictUI — SwiftUI verification engine.
// Targets:
//   VerdictUIKernel — platform-pure verdict engine (semantic tree, diff, lint, verdict schema).
//                     MUST NOT import SwiftUI/AppKit (enforced by PM stage_architecture).
//   VerdictUIProbe  — SwiftUI instrumentation runtime (Layout probes, preference keys, oracle host).
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
        .macOS(.v14)
    ],
    products: [
        .library(name: "VerdictUIKernel", targets: ["VerdictUIKernel"]),
        .library(name: "VerdictUIProbe", targets: ["VerdictUIProbe"]),
    ],
    targets: [
        .target(name: "VerdictUIKernel", swiftSettings: strictSettings),
        .target(
            name: "VerdictUIProbe",
            dependencies: ["VerdictUIKernel"],
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
    ]
)
