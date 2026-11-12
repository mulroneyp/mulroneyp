// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NightSkyStack",
    products: [
        .library(name: "NightSkyStack", targets: ["NightSkyStack"]),
    ],
    targets: [
        .target(name: "NightSkyStack"),
        .testTarget(
            name: "NightSkyStackTests",
            dependencies: ["NightSkyStack"]
        ),
    ]
)
