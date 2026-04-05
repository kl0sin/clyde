// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clyde",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Clyde",
            path: "Clyde"
        ),
        .testTarget(
            name: "ClydeTests",
            dependencies: ["Clyde"],
            path: "ClydeTests"
        )
    ]
)
