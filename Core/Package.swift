// swift-tools-version: 6.0

import PackageDescription

// Everything in this package is free of Apple-only frameworks,
// so it builds and runs its tests on Linux as well as on iOS.
let package = Package(
  name: "OffloadCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "OffloadCore",
      targets: ["OffloadCore"]
    ),
    .executable(
      name: "offload-probe",
      targets: ["OffloadProbe"]
    ),
    .executable(
      name: "offload-backup",
      targets: ["OffloadBackup"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
  ],
  targets: [
    .target(
      name: "OffloadCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .executableTarget(
      name: "OffloadProbe",
      dependencies: ["OffloadCore"]
    ),
    // Talks to a phone over its cable on Linux, macOS and Windows alike.
    .target(
      name: "OffloadCable",
      dependencies: ["OffloadCore"]
    ),
    .executableTarget(
      name: "OffloadBackup",
      dependencies: ["OffloadCore", "OffloadCable"]
    ),
    .testTarget(
      name: "OffloadCoreTests",
      dependencies: ["OffloadCore"]
    ),
    .testTarget(
      name: "OffloadCableTests",
      dependencies: ["OffloadCable", "OffloadCore"]
    ),
  ]
)
