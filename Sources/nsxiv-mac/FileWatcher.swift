import Foundation

// Calls onChange on the main queue when the file at path is written or replaced.
final class FileWatcher {
    private let source: DispatchSourceProtocol

    init?(path: String, onChange: @escaping () -> Void) {
        #if os(macOS)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler(handler: onChange)
        #else
        // watch the directory: an atomic save renames a new file over the old name;
        // a symlink's target is the file that changes, as open() follows links on macOS. Only a
        // link needs resolving, which on a network share takes a round trip a path component.
        var info = stat()
        let link = lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
        let url = link ? URL(fileURLWithPath: path).resolvingSymlinksInPath() : URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return nil }
        let mask = UInt32(IN_CLOSE_WRITE | IN_MOVED_TO)
        guard inotify_add_watch(fd, url.deletingLastPathComponent().path, mask) >= 0 else {
            close(fd)
            return nil
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler {
            if FileWatcher.changedNames(fd).contains(name) { onChange() }
        }
        #endif
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source.cancel() }

    #if os(Linux)
    // names in the queued inotify events
    private static func changedNames(_ fd: Int32) -> Set<String> {
        var names = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return names }
            // struct inotify_event: int wd; uint32_t mask, cookie, len; char name[len]
            var offset = 0
            while offset + 16 <= n {
                let len = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) })
                let name = buffer[(offset + 16)..<min(n, offset + 16 + len)].prefix { $0 != 0 }
                names.insert(String(decoding: name, as: UTF8.self))
                offset += 16 + len
            }
        }
    }
    #endif
}
