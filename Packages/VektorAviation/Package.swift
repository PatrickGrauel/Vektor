// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VektorAviation",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VektorAviation", targets: ["VektorAviation"]),
    ],
    targets: [
        .target(
            name: "VektorAviation",
            path: "Sources/VektorAviation",
            resources: [
                // ~4 MB of OurAirports runway data, bundled so the
                // RunwayDatabase lookups never need a network call.
                .copy("Resources/runways.csv"),
                // ~3.5 MB of OurAirports airport metadata (ident, type,
                // lat/lon, name, IATA) — drives the map pane's pin
                // rendering and the tier-by-zoom filtering.
                .copy("Resources/airports.csv"),
            ]
        ),
        .testTarget(
            name: "VektorAviationTests",
            dependencies: ["VektorAviation"],
            path: "Tests/VektorAviationTests"
        ),
    ]
)
