// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VektorStore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VektorStore", targets: ["VektorStore"]),
    ],
    targets: [
        .target(name: "VektorStore"),
        .testTarget(name: "VektorStoreTests", dependencies: ["VektorStore"]),
    ]
)
