// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VektorEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VektorEngine", targets: ["VektorEngine"]),
    ],
    dependencies: [
        .package(path: "../VektorAviation"),
    ],
    targets: [
        .target(
            name: "VektorEngine",
            dependencies: [
                .product(name: "VektorAviation", package: "VektorAviation"),
            ],
            path: "Sources/VektorEngine",
            resources: [
                .copy("Resources/mathjs.bundle.js"),
            ]
        ),
        .testTarget(
            name: "VektorEngineTests",
            dependencies: [
                "VektorEngine",
                .product(name: "VektorAviation", package: "VektorAviation"),
            ],
            path: "Tests/VektorEngineTests"
        ),
    ]
)
