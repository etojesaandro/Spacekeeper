// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Spacekeeper",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "Spacekeeper",
            targets: ["Spacekeeper"]
        ),
    ],
    dependencies: [
        .package(path: "Core"),
    ],
    targets: [
        .target(
            name: "Spacekeeper",
            dependencies: [
                .product(name: "SpacekeeperCore", package: "Core"),
            ]
        ),
    ]
)
