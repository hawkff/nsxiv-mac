import AppKit
import ImageIO

extension CGContext {
    // 8-bit sRGB with premultiplied alpha, the layout every renderer here draws into
    static func rgba(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

extension CIContext {
    // building a context is expensive; Core Image contexts are safe to share across threads
    static let shared = CIContext()
}

final class LoadedImage {
    private let source: CGImageSource
    let frameCount: Int
    let delays: [TimeInterval]
    let size: CGSize // oriented pixel size of first frame
    private let frames = NSCache<NSNumber, CGImage>()

    var isAnimated: Bool { frameCount > 1 }

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        source = src

        let animatedTypes: Set<String> = [
            "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics",
        ]
        let type = (CGImageSourceGetType(src) as String?) ?? ""
        let count = CGImageSourceGetCount(src)
        frameCount = animatedTypes.contains(type) ? count : 1

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        guard let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let swapped = (props[kCGImagePropertyOrientation] as? UInt32 ?? 1) >= 5
        size = swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        var d: [TimeInterval] = []
        for i in 0..<frameCount {
            d.append(LoadedImage.delay(source: src, index: i))
        }
        delays = d
        frames.totalCostLimit = 256 << 20 // bytes of decoded frames kept for animation
    }

    func frame(_ index: Int) -> CGImage? {
        let i = max(0, min(index, frameCount - 1))
        if let img = frames.object(forKey: i as NSNumber) { return img }
        // the thumbnail path applies EXIF orientation; capped at full size it is a plain decode
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(source, i, opts as CFDictionary)
        else { return nil }
        frames.setObject(img, forKey: i as NSNumber, cost: img.bytesPerRow * img.height)
        return img
    }

    private static func delay(source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary,
             kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary,
             kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary,
             kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary,
             kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictKey, unclamped, clamped) in dicts {
            guard let d = props[dictKey] as? [CFString: Any] else { continue }
            let t = (d[unclamped] as? TimeInterval) ?? (d[clamped] as? TimeInterval) ?? 0.1
            return t < 0.011 ? 0.1 : t
        }
        return 0.1
    }
}
