// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Musubi",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Musubi", targets: ["Musubi"]),
        .executable(name: "musubi-inspect", targets: ["MusubiCLI"]),
    ],
    targets: [
        .target(name: "Musubi"),
        .executableTarget(
            name: "MusubiCLI",
            dependencies: ["Musubi"]
        ),
        .testTarget(
            name: "MusubiTests",
            dependencies: ["Musubi"]
        ),
    ]
)
