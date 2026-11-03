// swift-tools-version: 6.0
// Vendored core target of xocialize/z-image-swift (MIT), commit
// eadca879078601d6787ad9e9ee7759def8bdcd56 (2026-10-11). The MLXEngine wrapper
// (mlx-engine-swift) and CLI are omitted. See VENDORING.md.
import PackageDescription

let package = Package(
    name: "ZImageSwift",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZImage", targets: ["ZImage"]),
    ],
    dependencies: [
        // Resolves to the root graph's pin (0.31.4, see Flux2Swift).
        .package(url: "https://github.com/ml-explore/mlx-swift.git", "0.31.4" ..< "0.32.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/xocialize/mlx-profiling.git", from: "0.1.0"),
        .package(url: "https://github.com/xocialize/mlx-exact-conv-swift", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "ZImage",
            dependencies: [
                .product(name: "MLXExactConv", package: "mlx-exact-conv-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "MLXProfiling", package: "mlx-profiling"),
            ],
            path: "Sources/ZImage",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
    ]
)
