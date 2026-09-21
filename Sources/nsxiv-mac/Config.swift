import AppKit

// Build-time settings, in the spirit of nsxiv's config.h.
// Edit and rebuild to customize.
enum Config {
    static let appName = "nsxiv-mac"
    static let appVersion = "0.1.0"

    // window size before the first image fits it, and the fixed size with -g
    static let winWidth: CGFloat = 800
    static let winHeight: CGFloat = 600

    // zoom levels used by '-' and '+' (first/last = min/max zoom)
    static let zoomLevels: [CGFloat] = [0.125, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 4.0, 8.0]

    // default slideshow delay in seconds (overridden via -S)
    static let slideshowDelay: TimeInterval = 5

    // color correction steps and limits
    static let ccSteps = 32
    static let gammaMax: Double = 10
    static let contrastMax: Double = 4

    // keyboard pan moves 1/PAN_FRACTION of the view
    static let panFraction: CGFloat = 5

    // thumbnail sizes for '-'/'+' in thumbnail mode; index of startup size
    static let thumbSizes: [CGFloat] = [32, 64, 96, 128, 160]
    static let thumbSizeIndex = 3
    static let thumbPadding: CGFloat = 10
    static let thumbMaxPixel = 320

    static let barHeight: CGFloat = 24
    static var barFont: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }
    static var markColor: NSColor { .systemYellow }

    // fraction of window width used as prev/next click zones
    static let navWidthFraction: CGFloat = 0.33

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "heic", "heif",
        "bmp", "tif", "tiff", "ico", "icns", "jp2", "avif", "psd",
        "tga", "exr", "pbm", "pgm", "ppm", "sgi", "dds", "cr2", "nef",
    ]
}
