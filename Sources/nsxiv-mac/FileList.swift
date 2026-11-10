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
        // Sorted by a rough key first, which is cheap and for most names already the order wanted,
        // so the collator, which decides the order, has little left to do.
        return paths.map { (key: roughKey($0), path: $0) }.sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.path).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FileEntry(path: $0) }
    }

    // Bytes whose plain order is close to the collator's for path: letters in one case, and each
    // number without its leading zeros, after a byte that counts its digits, so that 9 comes
    // before 10.
    static func roughKey(_ path: String) -> [UInt8] {
        var key: [UInt8] = []
        var count = -1 // where in key the number being read has its count; none between numbers
        for byte in path.utf8 {
            guard (0x30...0x39).contains(byte) else {
                count = -1
                key.append((0x41...0x5a).contains(byte) ? byte | 0x20 : byte)
                continue
            }
            if count < 0 {
                count = key.count
                key.append(0x30)
            }
            // past the digits one byte counts, the rest is left to the collator
            if byte != 0x30 || key[count] > 0x30, key[count] < 0xff {
                key[count] += 1
                key.append(byte)
            }
        }
        return key
    }

    // --start-file: the number in files of the file at path, where the viewer starts. Without it
    // there, as a file that is no image by its name, files becomes that file alone. The file is
    // the entry of its name in its directory, and a directory is told by its inode, as its path
    // may be spelled two ways: /tmp for macOS's /private/tmp, or through a link.
    static func start(at path: String, in files: inout [FileEntry], quiet: Bool) -> Int {
        let file = URL(fileURLWithPath: path, isDirectory: false)
        let name = "/" + file.lastPathComponent
        var wanted = stat(), found = stat()
        if stat(file.deletingLastPathComponent().path, &wanted) == 0, let index = files.firstIndex(where: {
            $0.path.hasSuffix(name) && stat($0.url.deletingLastPathComponent().path, &found) == 0
                && found.st_dev == wanted.st_dev && found.st_ino == wanted.st_ino
        }) { return index + 1 }
        files = build(paths: [path], recursive: false, quiet: quiet)
        return 1
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
