// swift-tools-version: 6.0

import PackageDescription

// Everything in this package is free of Apple-only frameworks,
// so it builds and runs its tests on Linux as well as on iOS.
let package = Package(
  name: "SpacekeeperCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "SpacekeeperCore",
      targets: ["SpacekeeperCore"]
    ),
    .executable(
      name: "spacekeeper-backup",
      targets: ["SpacekeeperBackup"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
  ],
  targets: [
    .target(
      name: "SpacekeeperCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    // Talks to a phone over its cable on Linux, macOS and Windows alike.
    .target(
      name: "SpacekeeperCable",
      dependencies: ["SpacekeeperCore"]
    ),
    .executableTarget(
      name: "SpacekeeperBackup",
      dependencies: ["SpacekeeperCore", "SpacekeeperCable"]
    ),
    .testTarget(
      name: "SpacekeeperCoreTests",
      dependencies: ["SpacekeeperCore"]
    ),
    .testTarget(
      name: "SpacekeeperCableTests",
      dependencies: ["SpacekeeperCable", "SpacekeeperCore"]
    ),
  ]
)
