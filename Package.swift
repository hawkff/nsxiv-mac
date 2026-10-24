// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nsxiv-mac",
    platforms: [.macOS(.v13)],
    targets: [
        // Xlib, Xft and Imlib2 for the Linux build
        .systemLibrary(
            name: "CX11",
            path: "Sources/CX11",
            pkgConfig: "x11 xft imlib2",
            providers: [.apt(["libx11-dev", "libxft-dev", "libimlib2-dev"])]
        ),
        .executableTarget(
            name: "nsxiv-mac",
            dependencies: [.target(name: "CX11", condition: .when(platforms: [.linux]))],
            path: "Sources/nsxiv-mac"
        ),
    ]
)
