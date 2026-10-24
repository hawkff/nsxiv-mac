import AppKit
import ImageIO
import QuickLookThumbnailing

// QuickLook renders the thumbnails and keeps the on-disk cache the system
// already maintains; -p decodes through ImageIO instead and writes nothing.
final class ThumbnailCache {
    private let privateMode: Bool
    private let memory = NSCache<NSString, CGImage>()
    // bumped by invalidate, so a thumbnail that was in flight then cannot come back stale
    private var generations: [String: Int] = [:] // main thread only

    init(privateMode: Bool) {
        self.privateMode = privateMode
    }

    func cached(_ entry: FileEntry) -> CGImage? {
        memory.object(forKey: entry.path as NSString)
    }

    func thumbnail(for entry: FileEntry, completion: @escaping (CGImage?) -> Void) {
        let generation = generations[entry.path, default: 0]
        let deliver = { (img: CGImage?) in
            DispatchQueue.main.async {
                let current = self.generations[entry.path, default: 0] == generation
                if let img, current { self.memory.setObject(img, forKey: entry.path as NSString) }
                completion(current ? img : nil)
            }
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
        generations[entry.path, default: 0] += 1
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
