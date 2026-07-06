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
        self.url = URL(fileURLWithPath: path)
    }
}

enum FileList {
    static func build(paths: [String], recursive: Bool, quiet: Bool) -> [FileEntry] {
        let fm = FileManager.default
        var out: [FileEntry] = []
        for p in paths {
            let url = URL(fileURLWithPath: p).standardizedFileURL
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
        var found: [String] = []
        func isRegularFile(_ u: URL) -> Bool {
            (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        if recursive {
            if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
                for case let u as URL in en where isImagePath(u.path) && isRegularFile(u) {
                    found.append(u.path)
                }
            }
        } else if let items = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) {
            for u in items where isImagePath(u.path) && isRegularFile(u) {
                found.append(u.path)
            }
        }
        found.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return found.map { FileEntry(path: $0) }
    }

    static func isImagePath(_ p: String) -> Bool {
        Config.imageExtensions.contains(URL(fileURLWithPath: p).pathExtension.lowercased())
    }
}
