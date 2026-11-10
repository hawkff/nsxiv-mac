#if os(macOS)
import AppKit
#else
import CX11
import Foundation
#endif

// stands in for a window: loads every file as a 320x160 image, a still unless delays has more frames
final class FakeUI: ViewerUI {
    var beeps = 0
    var loads = 0
    var fails = false // as with a file that is no image
    var delays = [0.1]
    func loadImage(_ url: URL) -> ImageInfo? {
        loads += 1
        return fails ? nil : ImageInfo(size: CGSize(width: 320, height: 160), delays: delays)
    }
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

        // --start-file: the image a file manager opened, among those of its directory
        var listed = flat
        assert(FileList.start(at: directory.appendingPathComponent("link.png").path, in: &listed, quiet: true) == 2
               && listed.count == 2, "the viewer starts at the named file among the others: \(listed.map(\.path))")
        assert(FileList.start(at: directory.appendingPathComponent("notes.txt").path, in: &listed, quiet: true) == 1
               && listed.map(\.url.lastPathComponent) == ["notes.txt"], "a file the list lacks shows alone")
        // a hard link to the first image under its name in another directory is an entry of its own
        let twin = directory.appendingPathComponent("twin")
        try fm.createDirectory(at: twin, withIntermediateDirectories: false)
        try fm.linkItem(at: imageURL, to: twin.appendingPathComponent("frame.png"))
        var deep = FileList.build(paths: [directory.path], recursive: true, quiet: true)
        assert(FileList.start(at: twin.appendingPathComponent("frame.png").path, in: &deep, quiet: true) == 4,
               "the viewer starts at the named entry, not at another link to its file: \(deep.map(\.path))")

        // numbers order by value and letters without their case, whatever order the rough key gives first
        let ordered = directory.appendingPathComponent("ordered")
        try fm.createDirectory(at: ordered, withIntermediateDirectories: false)
        for name in ["p10.png", "p9.png", "P1.png", "b2.png", "B10.png"] { try png.write(to: ordered.appendingPathComponent(name)) }
        let numbered = FileList.build(paths: [ordered.path], recursive: false, quiet: true).map(\.url.lastPathComponent)
        assert(numbered == ["b2.png", "B10.png", "P1.png", "p9.png", "p10.png"], "a directory lists in natural order: \(numbered)")
        func rough(_ a: String, before b: String) -> Bool { FileList.roughKey(a).lexicographicallyPrecedes(FileList.roughKey(b)) }
        assert(rough("a/IMG_0012.jpg", before: "a/img_100.JPG") && rough("x9", before: "x10") && !rough("x10", before: "x9")
               && rough("x" + String(repeating: "9", count: 300), before: "y"),
               "the rough key orders numbers by value and letters without their case")

        let ranged = Options.parse(["-g", "640x4.796e+2", "-S", "0.5", "-z", "150", "--start-file", "b.png", "a.png"])
        assert(ranged.geometry == CGSize(width: 640, height: 480) && ranged.slideshow == 0.5 && ranged.zoom == 1.5
               && ranged.startFile == "b.png" && ranged.paths == ["a.png"], "options take their arguments")
        assert(Options.parse(["-g", "800x600+10+10", "-S", "0.01", "a.png"]).geometry == CGSize(width: 800, height: 600)
               && Options.parse(["-S", "0.01", "a.png"]).slideshow == 0.1,
               "-g takes the size of an X geometry, and -S no less than a tenth of a second")
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
        try checkKeyHandler(directory: directory)
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
        let loads = ui.loads
        press("g")
        assert(ui.loads == loads, "g on the image that shows keeps it as it is")

        // 8 thumbnails in rows of 3, 3 and 2
        var rows = GridLayout()
        rows.viewSize = CGSize(width: 3 * rows.cellSize, height: 400)
        rows.count = 8
        assert(rows.neighbor(of: 1, .up) == 1 && rows.neighbor(of: 6, .down) == 6
               && rows.neighbor(of: 4, .down) == 7 && rows.neighbor(of: 5, .down) == 7,
               "the selection stays in its place at the top and bottom rows, and goes down to a short last row's end")

        // -z with -t: no image is loaded for the zoom to go to until one shows
        var startOptions = Options()
        startOptions.zoom = 2
        startOptions.thumbnailMode = true
        let zoomed = Viewer(options: startOptions, files: files)
        zoomed.ui = ui
        zoomed.resizeCanvas(CGSize(width: 640, height: 480))
        zoomed.start()
        _ = zoomed.handle(Keystroke(key: "Return"))
        assert(zoomed.viewport.zoom == 2, "-z holds from the first image that loads, also after the grid")
        // and with a file that would not load at the start, from the reload that loads it
        startOptions.thumbnailMode = false
        ui.fails = true
        let late = Viewer(options: startOptions, files: files)
        late.ui = ui
        late.resizeCanvas(CGSize(width: 640, height: 480))
        late.start()
        ui.fails = false
        _ = late.handle(Keystroke(key: "r"))
        assert(late.viewport.zoom == 2, "-z holds from a reload that loads what the start could not")

        assert((0x20...0x7e).map { String(UnicodeScalar(UInt8($0))) }
            .allSatisfy { $0.first!.isLetter || $0.first!.isNumber || Viewer.keysymNames[$0] != nil },
            "each key that types a sign has nsxiv's name for a key-handler")

        // m marks the last image and stays there, with nothing after it to go to
        let beeps = ui.beeps
        press("G")
        press("m")
        assert(viewer.current == 3 && viewer.files[3].marked && ui.beeps == beeps, "m on the last image marks it without a beep")

        // A slideshow counts an image's second from when a key went to it. An animation of three
        // frames outlasts that second: the slideshow waits for the frame after its last, and a still
        // goes on at once.
        startOptions.zoom = nil
        startOptions.slideshow = 1
        let show = Viewer(options: startOptions, files: files)
        show.ui = ui
        show.start()
        ui.delays = [0.5, 0.5, 0.5]
        let before = DispatchTime.now()
        _ = show.handle(Keystroke(key: "j"))
        let after = DispatchTime.now()
        assert(show.slideshowDue.map { before + 1 <= $0 && $0 <= after + 1 } == true, "a slideshow's delay starts with the image a key went to")
        show.slideshowFired()
        show.advanceFrame()
        show.advanceFrame()
        assert(show.current == 1 && show.frameIndex == 2, "a slideshow whose delay is over waits for an animation's first run")
        ui.delays = [0.1]
        show.advanceFrame()
        assert(show.current == 2, "the end of an animation's first run brings a slideshow's next image")
        show.slideshowFired()
        assert(show.current == 3, "a slideshow leaves a still when its delay is over")
    }

    // A key-handler gets the marked files on its stdin and the key by nsxiv's name. One that only
    // reads the files leaves the image that shows as it is loaded; one that rewrites that image,
    // though another is the marked one, has it loaded anew.
    static func checkKeyHandler(directory: URL) throws {
        let fm = FileManager.default
        let shown = directory.appendingPathComponent("shown.png").path
        let marked = directory.appendingPathComponent("marked.png").path
        let config = directory.appendingPathComponent("config")
        let handler = config.appendingPathComponent("\(Config.appName)/exec/key-handler")
        try fm.createDirectory(at: handler.deletingLastPathComponent(), withIntermediateDirectories: true)
        for path in [shown, marked] { try Data("only stamped, never decoded".utf8).write(to: URL(fileURLWithPath: path)) }
        // for the key w, the handler appends to shown.png, which it finds from its own path
        try Data("""
        #!/bin/sh
        cat >"$0.files"
        echo "$1" >"$0.key"
        [ "$1" != w ] || echo more >>"${0%/config/*}/shown.png"

        """.utf8).write(to: handler)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: handler.path)
        setenv("XDG_CONFIG_HOME", config.path, 1)

        let ui = FakeUI()
        let viewer = Viewer(options: Options(), files: [FileEntry(path: shown), FileEntry(path: marked)])
        viewer.ui = ui
        viewer.start()
        viewer.toggleMark(at: 1)
        func run(_ key: String) {
            _ = viewer.handle(Keystroke(key: "x", ctrl: true))
            _ = viewer.handle(Keystroke(key: key))
        }
        let loads = ui.loads
        run("c")
        let given = try String(contentsOfFile: handler.path + ".files", encoding: .utf8)
        assert(given == marked + "\n" && ui.loads == loads,
               "a key-handler gets the marked files, and one that only reads them costs no load: \(given)")
        run("w")
        assert(ui.loads == loads + 1, "a key-handler that rewrote the image that shows has it loaded anew")
        _ = viewer.handle(Keystroke(key: "x", ctrl: true))
        _ = viewer.handle(Keystroke(key: ",", ctrl: true))
        let named = try String(contentsOfFile: handler.path + ".key", encoding: .utf8)
        assert(named == "C-comma\n", "a key-handler gets nsxiv's name for the key: \(named)")
        _ = viewer.handle(Keystroke(key: "x", ctrl: true))
        _ = viewer.handle(Keystroke(key: "Return", ctrl: true, alt: true, shift: true))
        let modified = try String(contentsOfFile: handler.path + ".key", encoding: .utf8)
        assert(modified == "C-M-S-Return\n", "a key-handler gets Control, Alt and Shift as nsxiv names them: \(modified)")
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

        // Shift counts with a key it leaves as it is, Return or the space bar, not with J, which it made of j
        func pressed(_ characters: String, _ held: NSEvent.ModifierFlags, code: UInt16) -> Keystroke? {
            AppController.keystroke(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: held, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        let keys = [pressed("\r", [.shift, .option], code: 36), pressed("J", [.shift, .control], code: 38),
                    pressed(" ", [.shift], code: 49)]
        assert(keys == [Keystroke(key: "Return", alt: true, shift: true), Keystroke(key: "J", ctrl: true),
                        Keystroke(key: " ", shift: true)], "a key names the modifiers that did not make it: \(keys)")

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
            let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "j",
                                         charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
            app.postEvent(typed, atStart: false)
            assert(app.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: false) != nil,
                   "a posted key must wait in the queue, or the next check checks nothing")
            controller.keyHandlerDidRun()
            assert(app.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: true) == nil,
                   "a key typed while a key-handler ran must not reach the viewer")
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
        for (typed, name) in Viewer.keysymNames {
            let keysym = KeySym(typed.unicodeScalars.first!.value)
            assert(String(cString: XKeysymToString(keysym)) == name, "X names the key that types \(typed) otherwise than \(name)")
        }
        let cut = ImlibRenderer.truncatedHead("abcdefgh", width: 5) { $0.count }
        assert(cut == "…efgh" && ImlibRenderer.truncatedHead("abc", width: 5) { $0.count } == "abc",
               "long names lose their start: \(cut)")

        let typed = TerminalUI.keys(in: Array("j\u{1b}[A\u{1b}[1;5D\u{18}\r\u{7f}\u{1b}[3~\u{1b}OP\u{0}\u{e9}\u{1b}j".utf8))
        let named: [Keystroke?] = [
            Keystroke(key: "j"), Keystroke(key: "Up"), Keystroke(key: "Left", ctrl: true), Keystroke(key: "x", ctrl: true),
            Keystroke(key: "Return"), Keystroke(key: "BackSpace"), Keystroke(key: "Delete"), Keystroke(key: "F1"),
            Keystroke(key: " ", ctrl: true), nil, Keystroke(key: "j", alt: true), // Alt and j
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
               && TerminalUI.keys(in: Array("\u{1b}_j".utf8)).keys == [Keystroke(key: "_", alt: true), Keystroke(key: "j")],
               "Alt and _ is still _, and a reply cut after ESC _ is no keys: \(halfReply)")

        // The kitty keyboard protocol. Three taps of j in one burst, each a press with its text and a
        // release, are three keys; a held k, its press and the repeats that piled up after it, is one,
        // and so are the repeats of a later burst, before the release.
        let esc = "\u{1b}["
        let taps = TerminalUI.keys(in: Array(String(repeating: "\(esc)106;;106u\(esc)106;1:3u", count: 3).utf8))
        let heldKey = TerminalUI.keys(in: Array("\(esc)107;1:1;107u\(esc)107;1:2;107u\(esc)107;1:2;107u".utf8))
        let repeats = TerminalUI.keys(in: Array("\(esc)107;1:2;107u\(esc)107;1:2;107u\(esc)107;1:3u".utf8))
        assert(taps.keys == [Keystroke?](repeating: Keystroke(key: "j"), count: 3) && taps.rest.isEmpty
               && heldKey.keys == [Keystroke(key: "k")] && repeats.keys == [Keystroke(key: "k")],
               "with the kitty keyboard protocol each press is a key, and a held key one a burst: \(taps) \(heldKey) \(repeats)")
        // Shift and j by the text it types, and with Control by the key Shift makes of j; C-m, which is
        // no Return; Escape, at once; Shift alone, which is no key, so it ends no C-x prefix; Return with
        // Shift and Alt, which a key-handler gets; an arrow as herdr and as Alacritty send it, whose
        // release is no second arrow; the brace AltGr and 7 type on a German keyboard; Shift and Tab;
        // F1; the terminal's answer to the query for the protocol, which is no key; and letters in the
        // case Shift and Caps Lock give them together: M for Control and m under Caps Lock, J for
        // Control, Shift and j where the terminal names no key Shift makes, j for Shift and j under
        // Caps Lock, where Shift does not count, as it changed the key; no key for Control, Shift
        // and i on a Turkish keyboard, where the terminal names the dotted capital Shift makes of it;
        // and the bracket for Control and the bracket, though a terminal names its brace without Shift
        let reported = TerminalUI.keys(in: Array(("\(esc)106:74;2;74u\(esc)106:74;6u\(esc)109;5u\(esc)27u\(esc)57441;2u"
            + "\(esc)13;4u\(esc)1;1:1A\(esc)1;1:3A\(esc)A\(esc)1;1:3A\(esc)55;;123u\(esc)9;2u\(esc)P\(esc)?0u"
            + "\(esc)109;69u\(esc)106;6u\(esc)106:74;66;106u\(esc)105:304;6u\(esc)91:123;5u").utf8))
        let reportedKeys: [Keystroke?] = [
            Keystroke(key: "J"), Keystroke(key: "J", ctrl: true), Keystroke(key: "m", ctrl: true), Keystroke(key: "Escape"),
            Keystroke(key: "Return", alt: true, shift: true), Keystroke(key: "Up"), Keystroke(key: "Up"),
            Keystroke(key: "{"), Keystroke(key: "ISO_Left_Tab"), Keystroke(key: "F1"), nil,
            Keystroke(key: "M", ctrl: true), Keystroke(key: "J", ctrl: true), Keystroke(key: "j"), nil,
            Keystroke(key: "[", ctrl: true),
        ]
        assert(reported.keys == reportedKeys && reported.rest.isEmpty,
               "the kitty keyboard protocol's keys arrive as the keys X11 names: \(reported)")
        // what the probe read: herdr's answers, a j typed meanwhile, and the start of a Left whose D
        // comes in the next read, which must not count alone, as D would drop the image
        let probed = TerminalUI.keys(in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}[?62;22cj\u{1b}[".utf8))
        assert(probed.keys == [nil, Keystroke(key: "j")] && TerminalUI.keys(in: probed.rest + [0x44]).keys == [Keystroke(key: "Left")],
               "keys typed during the probe count, and the answers end only a C-x prefix: \(probed)")
        // herdr's answer, that of a terminal that cannot read the viewer's files, that of one
        // without kitty graphics, and an answer still on its way
        let herdr = TerminalUI.graphics(in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}_Gi=32;OK\u{1b}\\\u{1b}[?62;22c".utf8))
        // kitty's, with all of the keyboard protocol on, as its flags before the attributes say, foot's,
        // with those and sixels, and that of a terminal that reports no key with text as a sequence
        let kittyKeys = TerminalUI.graphics(in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}[?31u\u{1b}[?62;22c".utf8))
        let footKeys = TerminalUI.graphics(in: Array("\u{1b}[?31u\u{1b}[?62;4;22c".utf8))
        let fewKeys = TerminalUI.graphics(in: Array("\u{1b}[?7u\u{1b}[?62;22c".utf8))
        let remote = TerminalUI.graphics(
            in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}_Gi=32;EBADF:Failed to read image file\u{1b}\\\u{1b}[?62;22c".utf8))
        let none = TerminalUI.graphics(in: Array("\u{1b}[?1;2c".utf8))
        // foot's attributes, and a VT132's, whose 4 is its class rather than sixels
        let foot = TerminalUI.graphics(in: Array("\u{1b}[?62;4;22c".utf8))
        let vt132 = TerminalUI.graphics(in: Array("\u{1b}[?4;2c".utf8))
        assert(herdr! == (true, true, false, false) && remote! == (true, false, false, false)
               && none! == (false, false, false, false) && foot! == (false, false, true, false)
               && vt132! == (false, false, false, false) && kittyKeys! == (true, false, false, true)
               && footKeys! == (false, false, true, true) && fewKeys! == (false, false, false, false)
               && TerminalUI.graphics(in: Array("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}[?62".utf8)) == nil
               && TerminalUI.graphics(in: Array("\u{1b}[?31u\u{1b}[?62".utf8)) == nil,
               "the probe tells kitty graphics, frames in files, sixels and the whole keyboard protocol from their absence, once the device attributes came")
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
        // a zoom set by hand carries over to the next image, so it is among what decides whether that
        // image's frame has room; the zoom a fit mode gave the image that shows is not
        var byHand = whole, further = whole
        byHand.setZoom(0.5)
        further.setZoom(0.25)
        assert(TerminalUI.frameSettings(byHand) != TerminalUI.frameSettings(further)
               && TerminalUI.frameSettings(whole) == TerminalUI.frameSettings(filling),
               "what decides the next image's frame: \(TerminalUI.frameSettings(byHand)) \(TerminalUI.frameSettings(whole))")
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

        // A thumbnail goes to the cache at its image's path, with the image's time, and comes from
        // there while the image keeps that time: a 640x400 image rewritten as 100x100 at the same
        // time keeps its thumbnail of 320 pixels. A fresh thumbnail, and an image with another time,
        // take the image again. Without writing, the cache gets none, and one whose image is gone
        // leaves it.
        let cache = directory.appendingPathComponent("cache").path
        let wide = directory.appendingPathComponent("wide.png").path, unkept = directory.appendingPathComponent("unkept.png").path
        func opaque(_ path: String, _ width: Int32, _ height: Int32, time: Date) throws {
            imlib_context_set_image(imlib_create_image(width, height)!)
            imlib_image_set_has_alpha(0)
            imlib_image_set_format("png")
            imlib_save_image(path)
            imlib_free_image()
            try fm.setAttributes([.modificationDate: time], ofItemAtPath: path)
        }
        func thumbnailWidth(_ path: String, fresh: Bool = false, write: Bool = true) -> Int32 {
            guard let thumb = ImlibRenderer.thumbnail(path, cache: cache, fresh: fresh, write: write) else { return 0 }
            imlib_context_set_image(thumb)
            defer { imlib_free_image() }
            return imlib_image_get_width()
        }
        try opaque(wide, 640, 400, time: later)
        try opaque(unkept, 640, 400, time: later)
        // a cache that others could read is closed to them before a thumbnail goes there
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let firstWidth = thumbnailWidth(wide)
        let keptThere = try fm.contentsOfDirectory(atPath: cache + directory.path)
        let cacheMode = (try fm.attributesOfItem(atPath: cache)[.posixPermissions] as? NSNumber)?.intValue
        assert(firstWidth == 320 && FileList.stamp(cache + wide)?.prefix(2) == FileList.stamp(wide)?.prefix(2)
               && keptThere == ["wide.png"] && cacheMode == 0o700,
               "a thumbnail goes to a cache of the user's alone, whole and with its image's time: \(keptThere) \(String(describing: cacheMode))")
        // and none to one that others could write to, whose links may lead anywhere
        let openCache = directory.appendingPathComponent("open-cache").path
        try fm.createDirectory(atPath: openCache, withIntermediateDirectories: false)
        chmod(openCache, 0o777)
        if let unused = ImlibRenderer.thumbnail(wide, cache: openCache, write: true) {
            imlib_context_set_image(unused)
            imlib_free_image()
        }
        assert((try? fm.contentsOfDirectory(atPath: openCache)) == [], "a cache that others could write to gets no thumbnail")
        // and -c leaves such a directory as it is, though it holds a thumbnail whose image is gone
        let stray = openCache + directory.path + "/gone.png"
        try fm.createDirectory(atPath: openCache + directory.path, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: stray))
        ImlibRenderer.cleanThumbnailCache(openCache)
        assert(fm.fileExists(atPath: stray), "-c takes nothing from a directory that is no cache of the user's")
        // nor through a link another user made to a directory of the user's, which stays as it is;
        // only root, as in a container, can give the link to another user
        let theirLink = directory.appendingPathComponent("their-link").path
        let linked = directory.appendingPathComponent("linked").path
        try fm.createDirectory(atPath: linked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        if getuid() == 0 {
            guard symlink(linked, theirLink) == 0, lchown(theirLink, 65534, 65534) == 0 else {
                fatalError("root could not give a link to another user")
            }
            if let unused = ImlibRenderer.thumbnail(wide, cache: theirLink, write: true) {
                imlib_context_set_image(unused)
                imlib_free_image()
            }
            let linkedMode = (try fm.attributesOfItem(atPath: linked)[.posixPermissions] as? NSNumber)?.intValue
            assert((try? fm.contentsOfDirectory(atPath: linked)) == [] && linkedMode == 0o755,
                   "a cache behind another user's link gets no thumbnail and keeps its mode: \(String(describing: linkedMode))")
        }
        try opaque(wide, 100, 100, time: later)
        assert(thumbnailWidth(wide) == 320, "an image that keeps its time has its thumbnail from the cache")
        assert(thumbnailWidth(wide, fresh: true) == 100 && thumbnailWidth(wide) == 100, "a fresh thumbnail is made of the image")
        try opaque(wide, 640, 400, time: later.addingTimeInterval(60))
        assert(thumbnailWidth(wide) == 320, "an image with another time gets a new thumbnail")
        assert(thumbnailWidth(unkept, write: false) == 320 && !fm.fileExists(atPath: cache + unkept),
               "without writing, a thumbnail stays out of the cache")
        assert(thumbnailWidth(unkept) == 320 && fm.fileExists(atPath: cache + unkept), "a thumbnail goes to the cache")
        // also that of an image whose name leaves a filesystem of 255 bytes a name no room to grow
        let longest = directory.appendingPathComponent(String(repeating: "n", count: 251) + ".png").path
        try opaque(longest, 640, 400, time: later)
        assert(thumbnailWidth(longest) == 320 && fm.fileExists(atPath: cache + longest),
               "an image with the longest name has its thumbnail kept")
        try fm.removeItem(atPath: wide)
        ImlibRenderer.cleanThumbnailCache(cache)
        assert(!fm.fileExists(atPath: cache + wide) && fm.fileExists(atPath: cache + unkept),
               "the cache loses the thumbnails of images that are gone, and no others")

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
