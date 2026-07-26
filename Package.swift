// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sylvester",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sylvester",
            path: "Sources/Sylvester"
        )
    ]
)
