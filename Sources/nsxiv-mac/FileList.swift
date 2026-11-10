import Foundation

func warn(_ msg: String) {
    FileHandle.standardError.write(Data(("\(Config.appName): \(msg)\n").utf8))
}

struct FileEntry {
    let path: String
    let url: URL
    var marked = false

    init(path: String) {
        self.path = path
        // with isDirectory given, URL does not look the path up on disk, a round trip on a network share
        self.url = URL(fileURLWithPath: path, isDirectory: false)
    }
}

enum FileList {
    static func build(paths: [String], recursive: Bool, quiet: Bool) -> [FileEntry] {
        let fm = FileManager.default
        var out: [FileEntry] = []
        for p in paths {
            let url = URL(fileURLWithPath: p, isDirectory: false).standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                if !quiet { warn("no such file: \(p)") }
                continue
            }
            if isDir.boolValue {
                out.append(contentsOf: scan(dir: url, recursive: recursive))
            } else {
                out.append(FileEntry(path: url.path))
            }
        }
        return out
    }

    private static func scan(dir: URL, recursive: Bool) -> [FileEntry] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        let paths = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: options)?
            .compactMap { item -> String? in
                // stat() follows symlinks, so linked images count, as in nsxiv; a FIFO
                // with an image name stays out, since opening it would block
                var st = stat()
                guard let url = item as? URL, Config.imageExtensions.contains(url.pathExtension.lowercased()),
                      stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG
                else { return nil }
                return url.path
            } ?? []
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FileEntry(path: $0) }
    }

    // what tells a file that changed from one that did not: its times, size and inode; nil without the file
    static func stamp(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if os(macOS)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        return [modified.tv_sec, modified.tv_nsec, changed.tv_sec, changed.tv_nsec,
                Int(info.st_size), Int(truncatingIfNeeded: info.st_ino)]
    }
}
