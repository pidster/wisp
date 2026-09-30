// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "wisp",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "wisp", targets: ["wisp"]),
        .library(name: "WispCore", targets: ["WispCore"]),
        .library(name: "WispMCP", targets: ["WispMCP"]),
        // Scripted model and audit helpers; also used by the evaluations package in Evals/.
        .library(name: "WispTestSupport", targets: ["WispTestSupport"]),
    ],
    traits: [
        // MLX Swift compiles Metal kernels at build time and needs the Metal toolchain; off by default
        // so the ordinary build and the sandboxed pre-commit hook never need it (docs/backends.md).
        .trait(name: "MLX", description: "Run models through MLX Swift (needs the Metal toolchain to build)")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // The MLX bridge's tokenizer loader macro expands to code that needs swift-transformers in the
        // consumer; the same package coreai-models uses.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.0"),
        // 3.31.4 does not export MLXFoundationModels as a product; main does. Pinned to a commit.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "c6446cf7bfb7cea76408013b614d4b2c530eaa03"),
        // No tagged release yet; pinned to a commit so builds are reproducible (docs/backends.md).
        .package(
            url: "https://github.com/apple/coreai-models.git", revision: "3f109efd54273391f9fd9f5f5b3d8c6e99836d55"),
    ],
    targets: [
        .target(
            name: "WispCore",
            exclude: [
                "Resources/system-prompt.md", "Resources/measurements.json", "Resources/multiplexers.txt",
                "Resources/risk-examples.tsv", "Resources/risk-default.json", "Resources/personal-default.json",
                "Resources/subject-kinds.json",
            ],
            linkerSettings: [.linkedFramework("FoundationModels")],
            plugins: ["EmbedSystemPrompt"]
        ),
        .target(
            name: "WispCoreAI",
            dependencies: [
                "WispCore",
                .product(name: "CoreAILM", package: "coreai-models"),
            ]
        ),
        .target(
            name: "WispMLX",
            dependencies: [
                "WispCore",
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "Tokenizers", package: "swift-transformers", condition: .when(traits: ["MLX"])),
            ]
        ),
        .target(
            name: "WispMCP",
            dependencies: [
                "WispCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "wisp",
            dependencies: [
                "WispCore",
                "WispCoreAI",
                "WispMLX",
                "WispMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "WispTestSupport",
            dependencies: ["WispCore"],
            path: "Tests/WispTestSupport",
            // The context evaluation's files, read by path (ContextEval.fixturesDirectory).
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "WispCoreTests",
            dependencies: ["WispCore", "WispTestSupport"],
            // Snapshots read by path in ContextEquivalenceTests.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "WispMCPTests",
            dependencies: ["WispMCP", "WispTestSupport"]
        ),
        .testTarget(
            name: "WispMLXTests",
            dependencies: ["WispMLX", "WispTestSupport"]
        ),
        .testTarget(
            name: "WispCoreAITests",
            dependencies: ["WispCoreAI", "WispTestSupport"]
        ),
        .plugin(
            name: "EmbedSystemPrompt",
            capability: .buildTool()
        ),
    ]
)
