// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MountagentDeskKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MountagentDeskKit", targets: ["MountagentDeskKit"]),
    ],
    targets: [
        .target(name: "MountagentDeskKit"),
        .testTarget(
            name: "MountagentDeskKitTests",
            dependencies: ["MountagentDeskKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
