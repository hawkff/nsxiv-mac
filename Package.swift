// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nsxiv-mac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "nsxiv-mac", path: "Sources/nsxiv-mac"),
    ]
)

#if os(Linux)
// Linux draws with Imlib2, on X11 through Xlib or on Wayland through libwayland
package.targets += [
    .systemLibrary(
        name: "CX11",
        path: "Sources/CX11",
        pkgConfig: "x11 imlib2 fontconfig zlib",
        providers: [.apt(["libx11-dev", "libimlib2-dev", "libfontconfig-dev", "zlib1g-dev"])]
    ),
    .target(
        name: "CWayland",
        path: "Sources/CWayland",
        linkerSettings: [.linkedLibrary("wayland-client"), .linkedLibrary("wayland-cursor"),
                         .linkedLibrary("xkbcommon")]
    ),
]
package.targets[0].dependencies += ["CX11", "CWayland"]
#endif
