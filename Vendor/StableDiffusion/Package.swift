// swift-tools-version: 5.8
// Vendored subset of apple/ml-stable-diffusion (MIT), commit
// ea2805dc1945be20561c77e5f6d1d9a5a637cda2 (2026-09-11). SD3 sources (the only users of
// swift-transformers 0.1.8) removed — see VENDORING.md.
import PackageDescription

let package = Package(
    name: "StableDiffusion",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StableDiffusion", targets: ["StableDiffusion"]),
    ],
    targets: [
        .target(
            name: "StableDiffusion",
            path: "Sources/StableDiffusion",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
    ]
)
