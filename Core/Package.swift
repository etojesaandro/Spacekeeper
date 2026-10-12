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
    .testTarget(
      name: "OffloadCoreTests",
      dependencies: ["OffloadCore"]
    ),
  ]
)
