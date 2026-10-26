#if os(macOS)
import AppKit
#else
import CX11
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

        let status = "200x200 | 100% | 2/4"
        func fitted(_ room: CGFloat) -> String { Viewer.fittedStatus(status, room: room) { CGFloat($0.count) } }
        assert(fitted(20) == status && fitted(19) == "100% | 2/4" && fitted(9) == "2/4" && fitted(2) == "2/4",
               "a narrow bar drops status fields from the front and keeps the index")

        // a 200-wide window 1000 from the room's left edge, 80 from its right
        assert(Viewer.grownLimit(200, room: -1000, 280, keepsTopLeft: true) == 280,
               "a window that keeps its top-left corner grows into the room after it")
        assert(Viewer.grownLimit(200, room: -1000, 280, keepsTopLeft: false) == 280
               && Viewer.grownLimit(200, room: -10, 1000, keepsTopLeft: false) == 220,
               "where the anchoring is unknown, growth fits a centered window too")
        assert(Viewer.grownLimit(200, room: 50, 1000, keepsTopLeft: false) == .max
               && Viewer.grownLimit(200, room: -10, 150, keepsTopLeft: true) == .max,
               "a window parked across an edge grows freely")

        checkBindings(files: (0..<5).map { _ in FileEntry(path: imageURL.path) })
        #if os(macOS)
        try checkWindows(imageURL: imageURL)
        checkVision(image)
        #else
        try checkLinuxHelpers(directory: directory)
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
    static func checkLinuxHelpers(directory: URL) throws {
        let fm = FileManager.default
        assert(keyName(forKeysym: 0x47) == "G" && keyName(forKeysym: 0x20) == " ", "printable keys arrive as typed")
        assert(keyName(forKeysym: 0xff0d) == "Return" && keyName(forKeysym: 0xff51) == "Left",
               "other keys go by keysym name")
        assert(keyName(forKeysym: 0xffe1) == nil, "Shift alone is no key")
        let cut = ImlibRenderer.truncatedHead("abcdefgh", width: 5) { $0.count }
        assert(cut == "…efgh" && ImlibRenderer.truncatedHead("abc", width: 5) { $0.count } == "abc",
               "long names lose their start: \(cut)")

        let typed = TerminalUI.keys(in: Array("j\u{1b}[A\u{1b}[1;5D\u{18}\r\u{7f}\u{1b}[3~\u{1b}OP\u{0}\u{e9}\u{1b}j".utf8))
        let named: [Keystroke?] = [
            Keystroke(key: "j"), Keystroke(key: "Up"), Keystroke(key: "Left", ctrl: true), Keystroke(key: "x", ctrl: true),
            Keystroke(key: "Return"), Keystroke(key: "BackSpace"), Keystroke(key: "Delete"), Keystroke(key: "F1"),
            Keystroke(key: " ", ctrl: true), nil, Keystroke(key: "j"), // Alt-j is j, as on X11
        ]
        assert(typed.keys == named && typed.rest.isEmpty, "terminal bytes arrive as the keys X11 names: \(typed)")
        // a sequence another escape cuts short is one key without a name, so its end is no D;
        // a modifier as low as Int.min cannot overflow
        let odd = TerminalUI.keys(in: Array("\u{1b}[\u{1b}[D\u{1b}[1;-9223372036854775808A".utf8))
        assert(odd.keys == [nil, Keystroke(key: "Left"), Keystroke(key: "Up")] && odd.rest.isEmpty,
               "broken sequences end as one key without a name: \(odd)")
        // Left cut in two between reads, where its last byte alone would be D, which drops the image
        let firstRead = TerminalUI.keys(in: Array("k\u{1b}[".utf8))
        let secondRead = TerminalUI.keys(in: firstRead.rest + Array("D".utf8))
        assert(firstRead.keys == [Keystroke(key: "k")] && secondRead.keys == [Keystroke(key: "Left")]
               && secondRead.rest.isEmpty, "a sequence a read cuts off joins the next read: \(firstRead) \(secondRead)")
        assert(TerminalUI.keys(in: [0x1b]).rest == [0x1b], "a lone escape waits to tell Escape from a sequence")
        assert(TerminalUI.printable("a\u{1b}]52;c;eA==\u{7}b\u{9b}.png") == "a?]52;c;eA==?b?.png",
               "control characters in a name never reach the terminal")
        // an answer to the probe that came late is no keys, as its G and = would be
        let late = TerminalUI.keys(in: Array("j\u{1b}_Gi=31;OK\u{1b}\\k\u{1b}_Gi=3".utf8))
        assert(late.keys == [Keystroke(key: "j"), Keystroke(key: "k")] && late.rest == Array("\u{1b}_Gi=3".utf8),
               "kitty graphics replies never arrive as keys: \(late)")
        // a read that ends after ESC _ may have cut a reply in two, whose G and the rest are no keys
        let halfReply = TerminalUI.keys(in: Array("\u{1b}_".utf8))
        assert(halfReply.keys.isEmpty && halfReply.rest == [0x1b, 0x5f]
               && TerminalUI.keys(in: halfReply.rest + Array("Gi=77,p=1;ENOENT:No such image\u{1b}\\".utf8)).keys.isEmpty
               && TerminalUI.keys(in: Array("\u{1b}_j".utf8)).keys == [Keystroke(key: "_"), Keystroke(key: "j")],
               "Alt and _ is still _, as on X11, and a reply cut after ESC _ is no keys: \(halfReply)")
        // what the probe read: herdr's answers, a j typed meanwhile, and the start of a Left whose D
        // comes in the next read, which must not count alone, as D would drop the image
        let probed = TerminalUI.keys(in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}[?62;22cj\u{1b}[".utf8))
        assert(probed.keys == [nil, Keystroke(key: "j")] && TerminalUI.keys(in: probed.rest + [0x44]).keys == [Keystroke(key: "Left")],
               "keys typed during the probe count, and the answers end only a C-x prefix: \(probed)")
        // herdr's answer, that of a terminal that cannot read the viewer's files, that of one
        // without kitty graphics, and an answer still on its way
        let herdr = TerminalUI.graphics(in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}_Gi=32;OK\u{1b}\\\u{1b}[?62;22c".utf8))
        let remote = TerminalUI.graphics(
            in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}_Gi=32;EBADF:Failed to read image file\u{1b}\\\u{1b}[?62;22c".utf8))
        let none = TerminalUI.graphics(in: Array("\u{1b}[?1;2c".utf8))
        // foot's attributes, and a VT132's, whose 4 is its class rather than sixels
        let foot = TerminalUI.graphics(in: Array("\u{1b}[?62;4;22c".utf8))
        let vt132 = TerminalUI.graphics(in: Array("\u{1b}[?4;2c".utf8))
        assert(herdr! == (true, true, false) && remote! == (true, false, false) && none! == (false, false, false)
               && foot! == (false, false, true) && vt132! == (false, false, false)
               && TerminalUI.graphics(in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}[?62".utf8)) == nil,
               "the probe tells kitty graphics, frames in files and sixels from their absence, once the device attributes came")
        assert(TerminalUI.tmuxSupport("on|1|1|bpaste,clipboard,sixel,sync|xterm-kitty\n") == (true, true)
               && TerminalUI.tmuxSupport("all|1|1|RGB|xterm-ghostty\n") == (true, false)
               && TerminalUI.tmuxSupport("on|0|1|sixel|foot\n") == (false, true)
               && TerminalUI.tmuxSupport("off|1||sixel|xterm-256color\n") == (false, false)
               && TerminalUI.tmuxSupport("on|1|1|sixel|tmux-256color\n") == (false, false)
               && TerminalUI.tmuxSupport("") == (false, false),
               "tmux passes kitty graphics with allow-passthrough to a client with UTF-8, sixels where it and its client have them, and neither to another tmux")
        // a 700x232 image shown whole at 100% in a view of 800x464 units, 100 columns by 29 rows of
        // 10x20 pixels: 875x290 pixels, in a box of 88 columns by 15 rows from column 6 and row 7,
        // its right and bottom edges on cell boundaries; an image that fills the view, or runs past
        // it, goes with the view
        var whole = Viewport()
        whole.viewSize = CGSize(width: 800, height: 464)
        whole.setImageSize(CGSize(width: 700, height: 232), resetView: true)
        let cropped = TerminalUI.crop(whole, canvas: whole.viewSize, cell: (10, 20), scale: 1, columns: 100, rows: 29)
        var filling = whole
        filling.setImageSize(CGSize(width: 2000, height: 1160), resetView: true)
        var past = whole
        past.zoomStep(+1)
        assert(cropped == TerminalUI.Crop(column: 6, row: 7, columns: 88, rows: 15, x: 5, y: 10, width: 700, height: 232)
               && TerminalUI.crop(filling, canvas: whole.viewSize, cell: (10, 20), scale: 1, columns: 100, rows: 29) == nil
               && TerminalUI.crop(past, canvas: whole.viewSize, cell: (10, 20), scale: 1, columns: 100, rows: 29) == nil,
               "an image shown whole goes alone, in a box of whole cells: \(String(describing: cropped))")
        assert(TerminalUI.passthrough("\u{1b}_Ga=q\u{1b}\\") == "\u{1b}Ptmux;\u{1b}\u{1b}_Ga=q\u{1b}\u{1b}\\\u{1b}\\",
               "a command for the terminal around tmux goes in tmux's passthrough, its escapes doubled")
        // two rows of three cells of an image whose id has the high byte 3: the first cell of each
        // row names the row, column 0 and that byte, the diacritics for 0, 1 and 3 being U+0305,
        // U+030D and U+0310, and the cells after it count on
        assert(TerminalUI.placeholderCells(columns: 3, rows: 2, high: 3)
               == "\u{1b}[1;1H\u{10EEEE}\u{305}\u{305}\u{310}\u{10EEEE}\u{10EEEE}"
               + "\u{1b}[2;1H\u{10EEEE}\u{30D}\u{305}\u{310}\u{10EEEE}\u{10EEEE}"
               && TerminalUI.placeholderCells(columns: 0, rows: 2, high: 3).isEmpty,
               "placeholders name their rows and the id's high byte in diacritics on the first cell of each row")
        // chafa's sixel image of two bands of 6 rows, padded with a third, cut back to its canvas
        let padded = Array("\u{1b}P0;1;0q\"1;1;4;18#0;2;100;0;0#0!4~-#0!4~-#0!4~\u{1b}\\".utf8)
        assert(TerminalUI.sixelImage(padded, height: 12) == Array("\u{1b}P0;1;0q\"1;1;4;12#0;2;100;0;0#0!4~-#0!4~\u{1b}\\".utf8)
               && TerminalUI.sixelImage(padded, height: 18) == padded,
               "a sixel image chafa padded is cut to its canvas, and its raster attributes with it")
        let answers = Array("\u{1b}_Gi=77,p=1;ENOENT:No such image\u{1b}\\\u{1b}_Gi=78;OK\u{1b}\\".utf8)
        assert(TerminalUI.missingImages(in: answers) == [77], "a placement the terminal could not make names its image")
        let png = Data((0..<5000).map { UInt8($0 & 0xff) })
        let chunks = String(decoding: TerminalUI.kittyImage(png, keys: "a=T,i=2,p=1,C=1,c=10,r=4"), as: UTF8.self)
            .components(separatedBy: "\u{1b}\\").filter { !$0.isEmpty }
            .map { $0.dropFirst(3).split(separator: ";", maxSplits: 1).map(String.init) }
        assert(chunks.count == 2 && chunks[0][0] == "a=T,i=2,p=1,C=1,c=10,r=4,f=100,t=d,q=2,m=1" && chunks[1][0] == "m=0,q=2"
               && chunks[0][1].count == 4096 && chunks[0][1] + chunks[1][1] == png.base64EncodedString(),
               "a kitty image goes in chunks of 4096 bytes of base64, the keys on the first: \(chunks.map { $0[0] })")
        let held = TerminalUI.collapsingRepeats([Keystroke?](repeating: Keystroke(key: "j"), count: 5)
            + [Keystroke(key: "k"), Keystroke(key: "k")])
        assert(held == [Keystroke(key: "j"), Keystroke(key: "k"), Keystroke(key: "k")],
               "a held key's piled-up repeats count once, a double tap twice: \(held)")

        // a two-frame GIF on a 20x10 canvas whose first frame is a red 4x4 patch at 12,3; a clear
        // code before each pixel keeps every LZW code 3 bits wide
        func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        func frame(_ x: Int, _ y: Int, _ w: Int, _ h: Int, color: Int) -> [UInt8] {
            var codes: [Int] = []
            for _ in 0..<(w * h) { codes += [4, color] }
            var data: [UInt8] = [], bits = 0, count = 0
            for code in codes + [5] {
                bits |= code << count
                count += 3
                while count >= 8 {
                    data.append(UInt8(bits & 0xff))
                    bits >>= 8
                    count -= 8
                }
            }
            if count > 0 { data.append(UInt8(bits)) }
            var bytes: [UInt8] = [0x21, 0xf9, 4, 0, 10, 0, 0, 0, 0x2c] // 0.1 s, then where the frame lies
            bytes += le(x) + le(y) + le(w) + le(h)
            bytes += [0, 2, UInt8(data.count)] + data + [0]
            return bytes
        }
        var gif = Array("GIF89a".utf8) + le(20) + le(10)
        gif += [0x80, 0, 0, 0, 0, 0, 255, 0, 0] // two colors, black and red
        gif += frame(12, 3, 4, 4, color: 1) + frame(0, 0, 1, 1, color: 0) + [0x3b]
        // the terminal's PNG writer gives back, through libpng, the pixels it took
        guard let pixelsIn = imlib_create_image(3, 2) else { fatalError("no image") }
        imlib_context_set_image(pixelsIn)
        imlib_image_set_has_alpha(0)
        let colors: [UInt32] = [0xffff_0000, 0xff00_ff00, 0xff00_00ff, 0xff12_3456, 0xff00_0000, 0xffff_ffff]
        let writable = imlib_image_get_data()!
        for (i, color) in colors.enumerated() { writable[i] = color }
        imlib_image_put_back_data(writable)
        let frameURL = directory.appendingPathComponent("frame.png")
        try TerminalUI.png(of: pixelsIn)!.write(to: frameURL)
        imlib_context_set_image(pixelsIn)
        imlib_free_image()
        guard let pixelsOut = imlib_load_image_immediately_without_cache(frameURL.path) else { fatalError("libpng rejects the PNG") }
        imlib_context_set_image(pixelsOut)
        let decodedPixels = imlib_image_get_data_for_reading_only()!
        assert(imlib_image_get_width() == 3 && imlib_image_get_height() == 2
               && (0..<6).map { decodedPixels[$0] & 0xff_ffff } == colors.map { $0 & 0xff_ffff },
               "a PNG frame keeps its pixels")
        imlib_free_image()
        // and with alpha, as a frame the image does not cover, its transparent pixels among them
        guard let clearIn = imlib_create_image(3, 2) else { fatalError("no image") }
        imlib_context_set_image(clearIn)
        imlib_image_set_has_alpha(1)
        let clearColors: [UInt32] = [0x0000_0000, 0xffff_0000, 0x8000_ff00, 0xff00_00ff, 0x0000_0000, 0xff12_3456]
        let clearWritable = imlib_image_get_data()!
        for (i, color) in clearColors.enumerated() { clearWritable[i] = color }
        imlib_image_put_back_data(clearWritable)
        try TerminalUI.png(of: clearIn, alpha: true)!.write(to: frameURL)
        imlib_free_image()
        guard let clearOut = imlib_load_image_immediately_without_cache(frameURL.path) else { fatalError("libpng rejects the RGBA PNG") }
        imlib_context_set_image(clearOut)
        let clearDecoded = imlib_image_get_data_for_reading_only()!
        assert(imlib_image_has_alpha() != 0 && (0..<6).map { clearDecoded[$0] } == clearColors,
               "a PNG frame with alpha keeps its pixels and their alpha: \((0..<6).map { String(clearDecoded[$0], radix: 16) })")
        imlib_free_image()

        // An image drawn whole, alone in its frame, keeps its edges though its size there rounds apart
        // from where the view has it: 1600x236 at 50% in a view of 800x464 units is 1000x147.5
        // terminal pixels, a frame of 1000x148, whose first row is the red top and last the blue bottom
        let wholeRenderer = ImlibRenderer(viewer: Viewer(options: Options(), files: []))
        wholeRenderer.clearBackground = true
        guard let edged = imlib_create_image(1600, 236), let wholeFrame = imlib_create_image(1000, 148) else {
            fatalError("no image")
        }
        imlib_context_set_image(edged)
        imlib_image_set_has_alpha(0)
        let edgedPixels = imlib_image_get_data()!
        for row in 0..<236 {
            for column in 0..<1600 { edgedPixels[row * 1600 + column] = row == 0 ? 0xffff_0000 : row == 235 ? 0xff00_00ff : 0xff00_ff00 }
        }
        imlib_image_put_back_data(edgedPixels)
        var half = Viewport()
        half.viewSize = CGSize(width: 800, height: 464)
        half.setImageSize(CGSize(width: 1600, height: 236), resetView: true)
        let wholeOpaque = wholeRenderer.drawStill(edged, view: half, gamma: 0, contrast: 0, into: wholeFrame, width: 1000,
                                             height: 148, scale: 1.25, whole: true)
        imlib_context_set_image(wholeFrame)
        let wholePixels = imlib_image_get_data_for_reading_only()!
        let top = wholePixels[500], bottom = wholePixels[147 * 1000 + 500]
        assert(wholeOpaque && top >> 24 == 0xff && bottom >> 24 == 0xff && (top >> 16) & 0xff > 0 && bottom & 0xff > 0,
               "an image drawn whole keeps its first and last rows: \(String(top, radix: 16)) \(String(bottom, radix: 16))")
        imlib_free_image()
        imlib_context_set_image(edged)
        imlib_free_image()

        // A revisit takes the decoded image from Imlib2's cache while the file's time stays, which an
        // hour ahead a rewrite's ctime cannot pass; a reload, an invalidation and a new time read the file.
        let renderer = ImlibRenderer(viewer: Viewer(options: Options(), files: []))
        let later = Date().addingTimeInterval(3600)
        func picture(_ name: String, width: Int32, time: Date) throws -> URL {
            let url = directory.appendingPathComponent(name)
            imlib_context_set_image(imlib_create_image(width, 10)!)
            imlib_image_set_format("png")
            imlib_save_image(url.path)
            imlib_free_image()
            try fm.setAttributes([.modificationDate: time], ofItemAtPath: url.path)
            return url
        }
        let cached = try picture("cached.png", width: 30, time: later)
        let other = try picture("other.png", width: 40, time: later)
        func loadedWidth(_ url: URL) -> CGFloat? { renderer.loadImage(url)?.size.width }
        assert(loadedWidth(cached) == 30 && loadedWidth(other) == 40)
        _ = try picture("cached.png", width: 50, time: later)
        assert(loadedWidth(cached) == 30, "a revisit takes an unchanged file's decoded image from the cache")
        assert(loadedWidth(cached) == 50, "a reload reads the file again")
        _ = loadedWidth(other)
        _ = try picture("cached.png", width: 60, time: later)
        renderer.invalidateThumbnails([FileEntry(path: cached.path)])
        assert(loadedWidth(cached) == 60, "an invalidated file is read again")
        _ = loadedWidth(other)
        _ = try picture("cached.png", width: 70, time: later.addingTimeInterval(60))
        assert(loadedWidth(cached) == 70, "a revisit reads a file whose time changed")

        let patch = directory.appendingPathComponent("patch.gif")
        try Data(gif).write(to: patch)
        guard let thumb = ImlibRenderer.makeThumbnail(patch.path) else { fatalError("no thumbnail for patch.gif") }
        imlib_context_set_image(thumb)
        let width = Int(imlib_image_get_width()), height = Int(imlib_image_get_height())
        let pixels = imlib_image_get_data_for_reading_only()!
        assert(width == 20 && height == 10 && pixels[4 * width + 13] == 0xffff0000 && pixels[width + 1] >> 24 == 0,
               "an animation's thumbnail keeps its first frame where it lies on the canvas")
        imlib_free_image()
    }
    #endif
}
