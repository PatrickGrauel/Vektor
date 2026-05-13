// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TallyAviation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TallyAviation", targets: ["TallyAviation"]),
    ],
    targets: [
        .target(
            name: "TallyAviation",
            path: "Sources/TallyAviation"
        ),
        .testTarget(
            name: "TallyAviationTests",
            dependencies: ["TallyAviation"],
            path: "Tests/TallyAviationTests"
        ),
    ]
)
