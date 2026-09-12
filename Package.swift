// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PrivMask",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PrivMask", targets: ["PrivMask"]),
        .executable(name: "privmask", targets: ["PrivMaskCLI"]),
    ],
    targets: [
        .target(name: "PrivMask"),
        // Directory is PrivMaskCLI rather than privmask: a case-only difference
        // from the PrivMask target collides on case-insensitive filesystems.
        .executableTarget(name: "PrivMaskCLI", dependencies: ["PrivMask"]),
        // Measurement harness for Apple's built-in detectors. Deliberately not a
        // product: it is a development tool, not something consumers depend on.
        .executableTarget(name: "AppleAPIProbe", dependencies: ["PrivMask"]),
        .executableTarget(name: "FoundationModelProbe", dependencies: ["PrivMask"]),
        .testTarget(name: "PrivMaskTests", dependencies: ["PrivMask", "PrivMaskCLI"]),
    ]
)
