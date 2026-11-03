// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DabbleKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "DabbleKit", targets: ["DabbleKit"]),
    ],
    targets: [
        .target(name: "DabbleKit"),
        .testTarget(name: "DabbleKitTests", dependencies: ["DabbleKit"]),
    ],
    swiftLanguageModes: [.v5]
)
