// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nsxiv-mac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "nsxiv-mac",
            path: "Sources/nsxiv-mac"
        )
    ]
)
