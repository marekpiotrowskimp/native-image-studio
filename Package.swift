// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "NativeImageStudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NISDomain", targets: ["Domain"]),
        .library(name: "NISApplication", targets: ["Application"]),
        .library(name: "NISInfrastructure", targets: ["Infrastructure"]),
        .library(name: "NISMLXEngine", targets: ["MLXEngine"]),
        .library(name: "NISCoreMLEngine", targets: ["CoreMLEngine"]),
        .executable(name: "nis-poc", targets: ["PoCCLI"]),
        .executable(name: "NativeImageStudio", targets: ["NativeImageStudioApp"]),
    ],
    dependencies: [
        .package(path: "Vendor/Flux2Swift"),
        .package(path: "Vendor/StableDiffusion"),
        .package(path: "Vendor/ZImageSwift"),
        // Same pins the vendored packages already resolve (mlx-swift 0.31.4 graph).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    ],
    targets: [
        .target(
            name: "Domain",
            path: "NativeImageStudio/Domain",
            swiftSettings: strict
        ),
        .target(
            name: "Infrastructure",
            dependencies: ["Domain"],
            path: "NativeImageStudio/Infrastructure",
            resources: [.copy("ModelStorage/Manifests"), .copy("LivePreview/LatentRGB")],
            swiftSettings: strict
        ),
        .target(
            name: "Application",
            dependencies: ["Domain", "Infrastructure"],
            path: "NativeImageStudio/Application",
            swiftSettings: strict
        ),
        .target(
            name: "MLXEngine",
            dependencies: [
                "Domain",
                "Infrastructure",
                .product(name: "Flux2Core", package: "Flux2Swift"),
                .product(name: "Flux2Chains", package: "Flux2Swift"),
                .product(name: "FluxTextEncoders", package: "Flux2Swift"),
                .product(name: "ZImage", package: "ZImageSwift"),
            ],
            path: "NativeImageStudio/Engines/MLXEngine",
            swiftSettings: strict
        ),
        .target(
            name: "CoreMLEngine",
            dependencies: [
                "Domain",
                "Infrastructure",
                .product(name: "StableDiffusion", package: "StableDiffusion"),
            ],
            path: "NativeImageStudio/Engines/CoreMLEngine",
            swiftSettings: strict
        ),
        .target(
            name: "PromptAssistant",
            dependencies: [
                "Domain",
                "Infrastructure",
                "Application",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "NativeImageStudio/Engines/PromptAssistant",
            swiftSettings: strict
        ),
        .target(
            name: "Features",
            dependencies: ["Domain", "Application", "Infrastructure"],
            path: "NativeImageStudio/Features",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "NativeImageStudioApp",
            dependencies: ["Domain", "Application", "Infrastructure", "Features", "MLXEngine", "CoreMLEngine", "PromptAssistant"],
            path: "NativeImageStudio/App",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "PoCCLI",
            dependencies: ["Domain", "Infrastructure", "Application", "MLXEngine", "CoreMLEngine", "PromptAssistant"],
            path: "NativeImageStudio/Tools/PoCCLI",
            swiftSettings: strict
        ),
        .target(
            name: "TestSupport",
            dependencies: ["Domain", "Infrastructure"],
            path: "NativeImageStudio/Tests/TestSupport",
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: ["Domain", "TestSupport"],
            path: "NativeImageStudio/Tests/DomainTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "ImageInputTests",
            dependencies: ["Domain", "Infrastructure", "TestSupport"],
            path: "NativeImageStudio/Tests/ImageInputTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "CoordinatorTests",
            dependencies: ["Domain", "Application", "Infrastructure", "TestSupport"],
            path: "NativeImageStudio/Tests/CoordinatorTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "FeatureTests",
            dependencies: ["Domain", "Application", "Infrastructure", "Features", "TestSupport"],
            path: "NativeImageStudio/Tests/FeatureTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "EngineUnitTests",
            dependencies: [
                "Domain", "Infrastructure", "CoreMLEngine", "MLXEngine", "TestSupport",
                .product(name: "StableDiffusion", package: "StableDiffusion"),
            ],
            path: "NativeImageStudio/Tests/EngineUnitTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "EngineIntegrationTests",
            dependencies: ["Domain", "Infrastructure", "Application", "MLXEngine", "CoreMLEngine", "PromptAssistant", "TestSupport"],
            path: "NativeImageStudio/Tests/EngineIntegrationTests",
            swiftSettings: strict
        ),
    ]
)
