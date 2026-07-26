// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macverbs",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "macverbs", targets: ["macverbs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "macverbs",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/macverbs"
        ),
        .testTarget(
            name: "macverbsTests",
            dependencies: ["macverbs"],
            path: "Tests/macverbsTests"
        ),
    ]
)
