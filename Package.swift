// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Offload",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "Offload",
            targets: ["Offload"]
        ),
    ],
    dependencies: [
        .package(path: "Core"),
    ],
    targets: [
        .target(
            name: "Offload",
            dependencies: [
                .product(name: "OffloadCore", package: "Core"),
            ]
        ),
    ]
)
