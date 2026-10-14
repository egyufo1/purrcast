// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Purrcast",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PurrcastCore"),
        .executableTarget(name: "Purrcast", dependencies: ["PurrcastCore"]),
        .executableTarget(name: "SmokeTest", dependencies: ["PurrcastCore"]),
    ]
)
