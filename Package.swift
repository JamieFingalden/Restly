// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Restly",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Restly", targets: ["Restly"])
    ],
    targets: [
        .executableTarget(
            name: "Restly",
            path: "Sources/Restly"
        ),
        .testTarget(
            name: "RestlyTests",
            dependencies: ["Restly"]
        )
    ]
)
