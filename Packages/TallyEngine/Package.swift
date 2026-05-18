// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TallyEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TallyEngine", targets: ["TallyEngine"]),
    ],
    dependencies: [
        .package(path: "../TallyAviation"),
    ],
    targets: [
        .target(
            name: "TallyEngine",
            dependencies: [
                .product(name: "TallyAviation", package: "TallyAviation"),
            ],
            path: "Sources/TallyEngine",
            resources: [
                .copy("Resources/mathjs.bundle.js"),
            ]
        ),
        .testTarget(
            name: "TallyEngineTests",
            dependencies: [
                "TallyEngine",
                .product(name: "TallyAviation", package: "TallyAviation"),
            ],
            path: "Tests/TallyEngineTests"
        ),
    ]
)
