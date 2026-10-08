// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopRug",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RugSim"),
        .executableTarget(name: "DesktopRug", dependencies: ["RugSim"]),
        .testTarget(name: "RugSimTests", dependencies: ["RugSim"]),
    ]
)
