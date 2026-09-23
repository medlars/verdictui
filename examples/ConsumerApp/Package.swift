// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ConsumerApp",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ConsumerScenarios", targets: ["ConsumerScenarios"])],
    dependencies: [.package(name: "VerdictUI", path: "../..")],
    targets: [
        .executableTarget(
            name: "ConsumerScenarios",
            dependencies: [
                .product(name: "VerdictUICLICore", package: "VerdictUI"),
                .product(name: "VerdictUIProbe", package: "VerdictUI"),
                .product(name: "VerdictUIKernel", package: "VerdictUI"),
            ]
        )
    ]
)
