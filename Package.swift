// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macverbs",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacverbsCore", targets: ["MacverbsCore"]),
        .executable(name: "macverbs", targets: ["macverbs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "MacverbsCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MacverbsCore"
        ),
        .executableTarget(
            name: "macverbs",
            dependencies: ["MacverbsCore"],
            path: "Sources/macverbs"
        ),
        .testTarget(
            name: "macverbsTests",
            dependencies: ["MacverbsCore"],
            path: "Tests/macverbsTests"
        ),
    ]
)
