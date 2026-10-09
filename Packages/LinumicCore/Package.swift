// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinumicCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "LinumicCore", targets: ["LinumicCore"]),
    ],
    targets: [
        .target(
            name: "LinumicCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LinumicCoreTests",
            dependencies: ["LinumicCore"],
            // licensing-test-vectors.json: copy of licensing/test-vectors.json (a throwaway TEST key pair).
            resources: [.copy("Fixtures")]
        ),
    ]
)
