import AppKit
import ImageIO

final class LoadedImage {
    private let source: CGImageSource
    let frameCount: Int
    let delays: [TimeInterval]
    let size: CGSize // oriented pixel size of first frame
    private let orientation: CGImagePropertyOrientation
    private var cache: [Int: CGImage] = [:]
    private var cacheOrder: [Int] = []

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
        let rawOrient = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        orientation = CGImagePropertyOrientation(rawValue: rawOrient) ?? .up
        let swapped = rawOrient >= 5
        size = swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        var d: [TimeInterval] = []
        for i in 0..<frameCount {
            d.append(LoadedImage.delay(source: src, index: i))
        }
        delays = d
    }

    func frame(_ index: Int) -> CGImage? {
        let i = max(0, min(index, frameCount - 1))
        if let img = cache[i] { return img }
        guard let raw = CGImageSourceCreateImageAtIndex(source, i, nil) else { return nil }
        let img = LoadedImage.oriented(raw, orientation)
        cache[i] = img
        cacheOrder.append(i)
        if cacheOrder.count > 48 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
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

    private static func oriented(_ img: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return img }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let swapped = orientation.rawValue >= 5
        let outSize = swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        guard let ctx = CGContext(
            data: nil, width: Int(outSize.width), height: Int(outSize.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return img }

        ctx.translateBy(x: outSize.width / 2, y: outSize.height / 2)
        switch orientation {
        case .down, .downMirrored: ctx.rotate(by: .pi)
        case .left, .leftMirrored: ctx.rotate(by: .pi / 2)
        case .right, .rightMirrored: ctx.rotate(by: -.pi / 2)
        default: break
        }
        switch orientation {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored:
            ctx.scaleBy(x: -1, y: 1)
        default: break
        }
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage() ?? img
    }
}
