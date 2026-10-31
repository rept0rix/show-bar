// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShowBarCompanionProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(name: "CompanionProtocol", path: "Shared"),
        .testTarget(name: "CompanionProtocolTests", dependencies: ["CompanionProtocol"], path: "Tests/CompanionProtocolTests")
    ]
)
