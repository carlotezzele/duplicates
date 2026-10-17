// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Doppio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoppioCore", targets: ["DoppioCore"]),
        .executable(name: "doppio", targets: ["doppio"]),
        // The SwiftUI app; scripts/build-app.sh wraps it into Doppio.app.
        .executable(name: "DoppioApp", targets: ["DoppioApp"]),
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
        .executableTarget(name: "DoppioApp", dependencies: ["DoppioCore"]),
        .testTarget(name: "DoppioCoreTests", dependencies: ["DoppioCore"]),
        .testTarget(name: "DoppioAppTests", dependencies: ["DoppioApp", "DoppioCore"]),
    ]
)
