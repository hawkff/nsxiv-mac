import AppKit
import ImageIO
import UniformTypeIdentifiers

// Disk cache in ~/Library/Caches/nsxiv-mac, keyed by absolute source
// path with mtime staleness checks — same idea as nsxiv's cache dir.
final class ThumbnailCache {
    private let root: URL
    private let enabled: Bool
    private let queue = DispatchQueue(label: "thumbs", qos: .userInitiated, attributes: .concurrent)
    private var memory: [String: CGImage] = [:]
    private let lock = NSLock()

    init(privateMode: Bool) {
        enabled = !privateMode
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Config.appName, isDirectory: true)
        if enabled {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func thumbnail(for entry: FileEntry, completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        let cached = memory[entry.path]
        lock.unlock()
        if let cached {
            completion(cached)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let img = self.diskThumbnail(entry) ?? self.generate(entry)
            if let img {
                self.lock.lock()
                self.memory[entry.path] = img
                self.lock.unlock()
            }
            DispatchQueue.main.async { completion(img) }
        }
    }

    func invalidate(_ entry: FileEntry) {
        lock.lock()
        memory.removeValue(forKey: entry.path)
        lock.unlock()
        try? FileManager.default.removeItem(at: cacheURL(entry))
    }

    private func cacheURL(_ entry: FileEntry) -> URL {
        // path-derived key; collision-safe enough for a thumbnail cache
        var hash: UInt64 = 5381
        for b in entry.path.utf8 {
            hash = hash &* 33 &+ UInt64(b)
        }
        return root.appendingPathComponent(String(format: "%016llx.png", hash))
    }

    private func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func diskThumbnail(_ entry: FileEntry) -> CGImage? {
        guard enabled else { return nil }
        let cu = cacheURL(entry)
        guard let cacheMtime = mtime(cu.path), let srcMtime = mtime(entry.path),
              cacheMtime >= srcMtime,
              let src = CGImageSourceCreateWithURL(cu as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func generate(_ entry: FileEntry) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Config.thumbMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        if enabled,
           let dest = CGImageDestinationCreateWithURL(
               cacheURL(entry) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, thumb, nil)
            CGImageDestinationFinalize(dest)
        }
        return thumb
    }
}
