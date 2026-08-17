// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "PRStatus",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PRStatusCore"),
    .executableTarget(name: "PRStatus", dependencies: ["PRStatusCore"]),
    .executableTarget(name: "SelfTest", dependencies: ["PRStatusCore"]),
  ]
)
