// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftGraphDB",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "SwiftGraphDB", targets: ["SwiftGraphDB"]),
        .library(name: "SwiftGraphDBCloudKit", targets: ["SwiftGraphDBCloudKit"]),
    ],
    targets: [
        .target(
            name: "SwiftGraphDB",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "SwiftGraphDBCloudKit",
            dependencies: ["SwiftGraphDB"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SwiftGraphDBTests",
            dependencies: ["SwiftGraphDB"]
        ),
        .testTarget(
            name: "SwiftGraphDBCloudKitTests",
            dependencies: ["SwiftGraphDBCloudKit"]
        ),
    ]
)
