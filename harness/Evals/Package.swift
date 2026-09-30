// swift-tools-version: 6.2
import PackageDescription

// The model evaluations, in a package of their own so the gate's `swift build` and `swift test` never
// compile them. They need a model and run only through `scripts/check eval` (WISP_MODEL_TESTS=1); see
// docs/measurements.md. The harness package is a path dependency, built in debug with testing enabled,
// which is what `@testable import WispCore` needs.
let package = Package(
    name: "WispEvals",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(name: "wisp", path: "..")
    ],
    targets: [
        .testTarget(
            name: "ModelEvalTests",
            dependencies: [
                .product(name: "WispCore", package: "wisp"),
                .product(name: "WispTestSupport", package: "wisp"),
            ],
            // Real diffs from this repository's history, read by path in DraftEvalTests.
            exclude: ["Fixtures"]
        )
    ]
)
