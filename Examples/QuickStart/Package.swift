// swift-tools-version:6.0
import PackageDescription

// QuickStart is intentionally a separate Swift Package so it doesn't pollute consumers of
// the SwiftGraphDB SwiftPM product. Open Examples/QuickStart in Xcode (or run `swift build`
// from this directory) to try the SwiftUI sample.
let package = Package(
    name: "QuickStart",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .executable(name: "QuickStart", targets: ["QuickStart"]),
    ],
    dependencies: [
        .package(name: "SwiftGraphDB", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "QuickStart",
            dependencies: [
                .product(name: "SwiftGraphDB", package: "SwiftGraphDB"),
            ]
        ),
    ]
)
