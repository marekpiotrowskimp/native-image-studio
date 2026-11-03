// swift-tools-version: 6.0
// Vendored subset of VincentGourbin/flux-2-swift-mlx (MIT), upstream commit
// 315c27e83187909bc5e1f880b4850918342d891b (v3.1.0). See VENDORING.md for
// the local patches and the reason for vendoring.
import PackageDescription

let package = Package(
    name: "Flux2Swift",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FluxTextEncoders", targets: ["FluxTextEncoders"]),
        .library(name: "Flux2Core", targets: ["Flux2Core"]),
        .library(name: "Flux2Chains", targets: ["Flux2Chains"]),
    ],
    dependencies: [
        // Upstream pins 0.31.6, which needs a Swift 6.3 toolchain. 0.31.4 is the
        // newest release that builds with Swift 6.2 (Xcode 26.2).
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/VincentGourbin/swift-mlx-profiler", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "FluxTextEncoders",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "MLXProfiler", package: "swift-mlx-profiler"),
            ],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
        .target(
            name: "Flux2Core",
            dependencies: [
                "FluxTextEncoders",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "MLXProfiler", package: "swift-mlx-profiler"),
            ],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
        .target(
            name: "Flux2Chains",
            dependencies: [
                "Flux2Core",
                "FluxTextEncoders",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
    ]
)
