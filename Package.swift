// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SnapBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnapBar",
            path: "Sources/SnapBar"
        )
    ]
)
