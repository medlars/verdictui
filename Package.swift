// swift-tools-version: 5.10
// VerdictUI — SwiftUI verification engine.
// Targets:
//   VerdictUIKernel — platform-pure verdict engine (semantic tree, diff, lint, verdict schema).
//                     MUST NOT import SwiftUI/AppKit (enforced by PM stage_architecture).
//   VerdictUIProbe  — SwiftUI instrumentation runtime (Layout probes, preference keys, oracle host).
import PackageDescription

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
        .target(name: "VerdictUIKernel"),
        .target(name: "VerdictUIProbe", dependencies: ["VerdictUIKernel"]),
        .testTarget(name: "VerdictUIKernelTests", dependencies: ["VerdictUIKernel"]),
        .testTarget(name: "VerdictUIProbeTests", dependencies: ["VerdictUIProbe"]),
    ]
)
