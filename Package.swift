// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clyde",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Clyde",
            path: "Clyde",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/clyde-hook.sh")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Clyde/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "ClydeTests",
            dependencies: ["Clyde"],
            path: "ClydeTests"
        )
    ]
)
