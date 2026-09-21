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
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        let urls = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: options)?.compactMap { $0 as? URL } ?? []
        return urls
            .filter {
                isImagePath($0.path)
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .map(\.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FileEntry(path: $0) }
    }

    static func isImagePath(_ p: String) -> Bool {
        Config.imageExtensions.contains(URL(fileURLWithPath: p).pathExtension.lowercased())
    }
}
