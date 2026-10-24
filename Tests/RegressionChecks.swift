import AppKit

@main
struct RegressionChecks {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let context = CGContext.rgba(width: 320, height: 160)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        let image = context.makeImage()!
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        let imageURL = directory.appendingPathComponent("frame.png")
        try png.write(to: imageURL)
        try png.write(to: nested.appendingPathComponent("frame.png"))
        try png.write(to: directory.appendingPathComponent(".hidden.png"))
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(at: directory.appendingPathComponent("link.png"), withDestinationURL: imageURL)
        try fm.createDirectory(at: directory.appendingPathComponent("album.png"), withIntermediateDirectories: false)
        guard mkfifo(directory.appendingPathComponent("pipe.png").path, 0o600) == 0 else { fatalError("mkfifo failed") }

        let flat = FileList.build(paths: [directory.path], recursive: false, quiet: true)
        let recursive = FileList.build(paths: [directory.path], recursive: true, quiet: true)
        assert(flat.map(\.url.lastPathComponent) == ["frame.png", "link.png"],
               "nonrecursive scan must keep visible images and symlinks to them: \(flat.map(\.path))")
        assert(recursive.map(\.url.lastPathComponent) == ["frame.png", "link.png", "frame.png"]
               && recursive.last?.url.deletingLastPathComponent().lastPathComponent == "nested",
               "recursive scan must retain only visible images: \(recursive.map(\.path))")

        let parsed = Options.parse(["-rtn5", "-sw", "a.png", "--", "-b.png"])
        assert(parsed.recursive && parsed.thumbnailMode && parsed.startAt == 5
               && parsed.scaleMode == ScaleMode.width && parsed.paths == ["a.png", "-b.png"],
               "clustered short options must parse like getopt")

        // files 0 1 2 3, file 1 removed: 2 and 3 move up, 1 lands on the old 2
        assert((0...3).map { AppController.remap($0, kept: [0, 2, 3]) } == [0, 1, 1, 2],
               "removal must keep indices on their files")
        assert(AppController.remap(2, kept: [0, 1]) == 1, "removing the last file must land on the new last")

        // a red pixel left of a blue one; turned clockwise, red is on top
        let strip = CGContext.rgba(width: 2, height: 1)!
        strip.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        strip.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        strip.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        strip.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        func redOnTop(_ img: CGImage) -> Bool {
            let ctx = CGContext.rgba(width: img.width, height: img.height)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return bytes[0] > 128 && bytes[ctx.bytesPerRow] < 128 // first row in memory is the top
        }
        let turned = AppController.transform(strip.makeImage()!, rotation: 90, flipH: false, flipV: false)
        let turnedFlipped = AppController.transform(strip.makeImage()!, rotation: 90, flipH: false, flipV: true)
        assert(turned.width == 1 && redOnTop(turned), "rotation must turn clockwise")
        assert(!redOnTop(turnedFlipped), "a flip must mirror the image as rotated on screen")

        let app = NSApplication.shared
        let geometries: [CGSize?] = [nil, CGSize(width: 640, height: 480)]
        for geometry in geometries {
            var options = Options()
            options.geometry = geometry
            let controller = AppController(options: options, files: [FileEntry(path: imageURL.path)])
            controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            guard let window = app.windows.first(where: { $0.delegate === controller }) else {
                fatalError("missing viewer window")
            }
            window.isReleasedWhenClosed = false
            defer { withExtendedLifetime(controller) { window.close() } }
            let fitted = CGSize(width: 320, height: 160 + Config.barHeight)
            assert(window.frame.size == (geometry ?? fitted), "initial outer frame must match geometry or image")

            let restored = CGSize(width: 900, height: 500)
            window.setFrame(NSRect(origin: window.frame.origin, size: restored), display: false)
            window.delegate?.windowDidExitFullScreen?(Notification(name: NSWindow.didExitFullScreenNotification,
                                                                  object: window))
            assert(window.frame.size == (geometry == nil ? fitted : restored),
                   "fullscreen exit must refit only automatic geometry")
        }

        var remaining = 3
        let completed = {
            assert(Thread.isMainThread, "public Vision callbacks must run on the main thread")
            remaining -= 1
        }
        VisionTools.recognizeText(in: image) { _, _ in completed() }
        VisionTools.detectBarcodes(in: image) { _ in completed() }
        VisionTools.detectFaces(in: image) { _ in completed() }
        let deadline = Date().addingTimeInterval(30)
        while remaining > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        assert(remaining == 0, "Vision callbacks did not finish")
        print("Window, file-list, and Vision regression checks passed")
    }
}
