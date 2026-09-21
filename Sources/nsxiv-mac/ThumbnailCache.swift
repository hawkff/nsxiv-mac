import AppKit
import ImageIO
import QuickLookThumbnailing

// QuickLook renders the thumbnails and keeps the on-disk cache the system
// already maintains; -p decodes through ImageIO instead and writes nothing.
final class ThumbnailCache {
    private let privateMode: Bool
    private let memory = NSCache<NSString, CGImage>()

    init(privateMode: Bool) {
        self.privateMode = privateMode
    }

    func thumbnail(for entry: FileEntry, completion: @escaping (CGImage?) -> Void) {
        let key = entry.path as NSString
        if let hit = memory.object(forKey: key) {
            completion(hit)
            return
        }
        let deliver = { (img: CGImage?) in
            if let img { self.memory.setObject(img, forKey: key) }
            DispatchQueue.main.async { completion(img) }
        }
        if privateMode {
            DispatchQueue.global(qos: .userInitiated).async { deliver(Self.decode(entry.url)) }
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url, size: CGSize(width: Config.thumbMaxPixel, height: Config.thumbMaxPixel),
            scale: 1, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            deliver(rep?.cgImage ?? Self.decode(entry.url))
        }
    }

    func invalidate(_ entry: FileEntry) {
        memory.removeObject(forKey: entry.path as NSString)
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Config.thumbMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
