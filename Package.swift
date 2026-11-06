// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StampSign",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StampSign", path: "Sources/StampSign"),
        .testTarget(name: "StampSignTests", dependencies: ["StampSign"], path: "Tests/StampSignTests"),
    ]
)
