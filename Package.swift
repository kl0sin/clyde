// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clyde",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Clyde", targets: ["Clyde"])
    ],
    targets: [
        .target(
            name: "ClydeCore",
            path: "Clyde",
            sources: ["Models"]
        ),
        .executableTarget(
            name: "Clyde",
            dependencies: ["ClydeCore"],
            path: "Clyde/App"
        ),
        .testTarget(
            name: "ClydeTests",
            dependencies: ["ClydeCore"],
            path: "ClydeTests"
        )
    ]
)
