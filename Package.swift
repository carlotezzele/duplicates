// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Doppio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoppioCore", targets: ["DoppioCore"]),
        .executable(name: "doppio", targets: ["doppio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DoppioCore"),
        .executableTarget(
            name: "doppio",
            dependencies: [
                "DoppioCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DoppioCoreTests", dependencies: ["DoppioCore"]),
    ]
)
