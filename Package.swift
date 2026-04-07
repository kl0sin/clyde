// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clyde",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sparkle — auto-update framework. Used to deliver new Clyde
        // releases to users without manual re-download. Reads an appcast
        // XML feed (hosted on our GitHub Pages site) and verifies the
        // download with EdDSA before installing.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Clyde",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Clyde",
            exclude: [
                "Info.plist",
                // The .iconset directory is the source for `iconutil` to
                // generate AppIcon.icns. SPM doesn't need to ship the
                // individual PNGs — only the compiled .icns matters at
                // runtime.
                "Assets/AppIcon.iconset",
            ],
            resources: [
                .copy("Resources/clyde-hook.sh"),
                .copy("Assets/AppIcon.icns"),
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
