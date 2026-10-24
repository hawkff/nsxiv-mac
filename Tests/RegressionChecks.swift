#if os(macOS)
import AppKit
#else
import Foundation
#endif

// stands in for a window: loads every file as a 320x160 still
final class FakeUI: ViewerUI {
    var beeps = 0
    func loadImage(_ url: URL) -> ImageInfo? { ImageInfo(size: CGSize(width: 320, height: 160), delays: [0.1]) }
    func imageChanged() {}
    func viewChanged() {}
    func gridChanged() {}
    func barChanged() {}
    func layoutChanged() {}
    func invalidateThumbnails(_ entries: [FileEntry]) {}
    func fitWindow() {}
    func resetWindowSize() {}
    func toggleFullscreen() {}
    func beep() { beeps += 1 }
    func enterEditMode() -> Bool { false }
}

@main
struct RegressionChecks {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        #if os(macOS)
        let context = CGContext.rgba(width: 320, height: 160)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        let image = context.makeImage()!
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        #else
        let png = Data("only scanned, never decoded".utf8)
        #endif
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
        assert((0...3).map { Viewer.remap($0, kept: [0, 2, 3]) } == [0, 1, 1, 2],
               "removal must keep indices on their files")
        assert(Viewer.remap(2, kept: [0, 1]) == 1, "removing the last file must land on the new last")

        checkBindings(files: (0..<5).map { _ in FileEntry(path: imageURL.path) })
        #if os(macOS)
        try checkWindows(imageURL: imageURL)
        checkVision(image)
        #else
        checkX11Helpers()
        #endif
        print("Regression checks passed")
    }

    static func checkBindings(files: [FileEntry]) {
        let ui = FakeUI()
        let viewer = Viewer(options: Options(), files: files)
        viewer.ui = ui
        viewer.resizeCanvas(CGSize(width: 640, height: 480))
        viewer.start()
        func press(_ key: String, ctrl: Bool = false) { _ = viewer.handle(Keystroke(key: key, ctrl: ctrl)) }

        assert(viewer.viewport.zoom == 1, "w (the default) keeps a small image at 100%")
        press("W")
        assert(viewer.viewport.zoom == 2, "W fits the image to the view")
        press(">")
        assert(viewer.displaySize == CGSize(width: 160, height: 320) && viewer.viewport.zoom == 1.5,
               "a turn fits the turned image again")
        press("|")
        press(">")
        assert(viewer.rotation == 0, "under a flip, a clockwise turn on screen undoes the previous one")

        viewer.toggleMark(at: 1) // a right-click mark
        press("Return")
        assert(viewer.thumbnailMode, "Return opens the grid")
        viewer.select(3)
        press("M")
        assert(viewer.files.map(\.marked) == [false, true, true, true, false] && viewer.markCount == 3,
               "M marks from the image marked last")
        press("D")
        assert(viewer.files.count == 4 && viewer.current == 3 && viewer.markCount == 2,
               "D removes the selection and the selection moves to the new last file")
        press("g")
        press("k")
        assert(viewer.current == 0 && ui.beeps == 0, "k stays on the first thumbnail without a beep")
        press("Return")
        press("k")
        assert(!viewer.thumbnailMode && ui.beeps == 1, "k before the first image beeps")
    }

    #if os(macOS)
    static func checkWindows(imageURL: URL) throws {
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

            _ = controller.viewer.handle(Keystroke(key: "Return"))
            let grid = CGSize(width: Config.winWidth, height: Config.winHeight)
            assert(window.frame.size == (geometry == nil ? grid : restored),
                   "the grid takes the starting size back unless -g fixed it")
        }
    }

    static func checkVision(_ image: CGImage) {
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
    }
    #else
    static func checkX11Helpers() {
        assert(X11UI.keyName(0x47) == "G" && X11UI.keyName(0x20) == " ", "printable keys arrive as typed")
        assert(X11UI.keyName(0xff0d) == "Return" && X11UI.keyName(0xff51) == "Left", "other keys go by keysym name")
        assert(X11UI.keyName(0xffe1) == nil, "Shift alone is no key")
        let cut = X11UI.truncatedHead("abcdefgh", width: 5) { $0.count }
        assert(cut == "…efgh" && X11UI.truncatedHead("abc", width: 5) { $0.count } == "abc",
               "long names lose their start: \(cut)")
    }
    #endif
}
