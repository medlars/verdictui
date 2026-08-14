// swift-tools-version: 5.10
// Fleet dogfood: adopting VerdictUI into a SagaMail-shaped SwiftUI screen.
//
// This is a SEPARATE package that depends on VerdictUI exactly as any third
// party would — by URL-equivalent path, through the published products. It is
// deliberately NOT part of the VerdictUI package: a dogfood that compiles only
// inside the engine's own build tests nothing about consuming the engine.
import PackageDescription

let package = Package(
    name: "SagaMailDogfood",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../..")],
    targets: [
        .target(
            name: "SagaMailDogfood",
            dependencies: [
                .product(name: "VerdictUIMacroSupport", package: "VerdictUI"),
                .product(name: "VerdictUIProbe", package: "VerdictUI"),
            ]
        ),
        .testTarget(
            name: "SagaMailDogfoodTests",
            dependencies: [
                "SagaMailDogfood",
                .product(name: "VerdictUIKernel", package: "VerdictUI"),
                .product(name: "VerdictUIProbe", package: "VerdictUI"),
                // Needed by the TEST target too, which is not obvious: a
                // scenario wrapping a @Verifiable view calls verdictProbing(_:),
                // and that function lives in MacroSupport beside the macro
                // rather than in Probe. Depending only on Kernel + Probe — the
                // intuitive choice for a target that only renders and asserts —
                // fails with "cannot find 'verdictProbing' in scope".
                // Recorded as friction #2 in FINDINGS.md (CTS-74D240DC).
                .product(name: "VerdictUIMacroSupport", package: "VerdictUI"),
            ]
        ),
    ]
)
