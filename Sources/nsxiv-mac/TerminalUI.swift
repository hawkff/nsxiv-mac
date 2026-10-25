#if os(Linux)
import CX11
import Foundation

// The viewer in a terminal, for a machine without a display, as over SSH: the renderer draws
// the view, and the status bar takes the last line. A terminal with the kitty graphics protocol,
// as kitty, Ghostty, WezTerm or a herdr pane in one of them, gets the view as an image at its
// own pixels; one with sixels, as foot, xterm or Konsole, gets it from chafa as a sixel image at
// its pixels; any other gets it from chafa as colored symbols, one per cell. Keys arrive as the
// bytes the terminal sends for them.
//
// A kitty terminal keeps the images it gets, and shows one again for a command of a few dozen
// bytes: the frames of the last views stay there, and while the viewer waits for a key it
// sends the next and the previous image ahead, so moving to them, or back to an earlier view,
// takes microseconds. A terminal on the same machine reads each new frame as raw pixels from a
// file in /tmp, a RAM disk on most systems; a remote one gets it as PNG through the terminal.
// Sixels stay with the viewer, and chafa makes the next image's while it waits.
//
// In tmux, kitty graphics need allow-passthrough: the viewer wraps its commands for tmux to pass
// to the terminal around it, and shows each image as Unicode placeholders, text that tmux keeps
// and redraws with the pane. Sixels go to tmux itself, which shows them where its client can.
final class TerminalUI: ViewerUI {
    private let viewer: Viewer
    private let renderer: ImlibRenderer
    private let tty: Int32
    private let kitty: Bool
    private let sixel: Bool // chafa's sixels, where kitty graphics are missing
    private let imageFiles: String? // the directory of frames the terminal reads itself
    private let chafa: [String] // the command, without the size and the file
    private let frame: String // the drawn view as a PNG file, for chafa; with -ahead, the next image's
    private var canvas: Imlib_Image?
    private var canvasPixels = (width: 0, height: 0)
    private var cols = 80
    private var rows = 24
    private var cell = (width: 8.0, height: 16.0) // pixels, where the terminal says; else the usual 1:2 shape
    private var imageDirty = true // false when only the status bar changed since the last frame

    // what decides the pixels of a frame of the image view, to show it again without drawing it
    private struct FrameKey: Hashable {
        let path: String
        let frame: Int, rotation: Int, flipH: Bool, flipV: Bool, gamma: Int, contrast: Int
        let x: CGFloat, y: CGFloat, zoom: CGFloat, antialias: Bool, alphaLayer: Bool
        let width: Int, height: Int // the frame's pixels
    }
    private var kept: [FrameKey: (id: UInt32, bytes: Int)] = [:] // frames the terminal holds
    private var keptOrder: [FrameKey] = [] // least recently shown first
    private var shownImage: UInt32 = 0 // the kitty image on screen, 0 for none
    private var shownKey: FrameKey?
    private var lastImageID: UInt32 = 0
    private var lastIndex = 0 // of the image shown, for the way the viewer is going
    private var direction = 1
    private var prefetch: DispatchWorkItem?
    private var notAhead: Set<String> = [] // neighbors that cannot go ahead: animations, broken files, huge images
    private var chafaFrames: [FrameKey: [UInt8]] = [:] // chafa's last frames, as symbols or sixels
    private var chafaOrder: [FrameKey] = [] // least recently shown first
    private var chafaAhead = false // chafa making a frame ahead, in the background
    private var framesForgotten = 0 // a frame made ahead from before that is stale
    private var placeholderCache: (layout: [Int], cells: String) = ([], "")
    // the files loaded or sent ahead: what loading them gave, and their times just before
    private var loaded: [String: (info: ImageInfo, stamp: [Int])] = [:]
    private var rendererPath: String? // the file the renderer holds; another loads once it must draw
    private var redrawDue: DispatchTime?
    private var sources: [DispatchSourceProtocol] = []
    private var cutOff: [UInt8] = [] // an escape sequence the last read ended inside
    private var cutOffTimeout: DispatchWorkItem?
    private let probeInput: [UInt8] // the probe's answers, which the key parser skips, and keys typed meanwhile
    // herdr sends an image on to its client, across SSH for a remote one, only once the image is
    // placed, which for a frame of 2560x1600 takes over a second there: a frame sent ahead also gets
    // a placement of one cell, under the background of the status bar's last cell, so it is on the
    // client by the time it shows
    private let placeAhead = ProcessInfo.processInfo.environment["TERM_PROGRAM"] == "herdr"

    // what atexit puts back
    private static var saved: (tty: Int32, mode: termios, frame: String, kitty: Bool, imageFiles: String?)?
    private static var tmux = false // kitty graphics through tmux, to the terminal around it

    // nil without a terminal, and without chafa in a terminal that cannot show images, which
    // it warns about
    init?(viewer: Viewer) {
        let tty = open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard tty >= 0 else { return nil }
        var mode = termios()
        guard tcgetattr(tty, &mode) == 0 else {
            close(tty)
            return nil
        }
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/nsxiv-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else {
            close(tty)
            return nil
        }
        close(fd)
        let frame = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        // the terminal reads and deletes only files in a temporary directory, with this in the path
        var directory = Array("/tmp/tty-graphics-protocol-nsxiv-XXXXXX".utf8CString)
        let imageFiles = mkdtemp(&directory).map { String(cString: $0) }
        // a kill, or a closed terminal, ends the viewer as q does, once the main queue runs; ignored
        // from here, a signal during the probe cannot end the viewer with the terminal still raw
        var stops: [DispatchSourceProtocol] = []
        for stop in [SIGINT, SIGTERM, SIGHUP] {
            signal(stop, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: stop, queue: .main)
            source.setEventHandler { viewer.quit() }
            source.resume()
            stops.append(source)
        }
        Self.saved = (tty, mode, frame, false, imageFiles)
        atexit { TerminalUI.restoreTerminal() }
        Self.enter()
        // tmux takes a kitty query as a title, so in tmux the viewer asks it what it passes on, and
        // asks the terminal around it only through it; seen from outside, as over SSH, a terminal
        // multiplexer gets no query
        let environment = ProcessInfo.processInfo.environment
        let inTmux = environment["TMUX"].map { !$0.isEmpty } ?? false
        let tmux = inTmux ? Self.tmuxSupport(Self.output(of: ["tmux", "display", "-p"]
            + (environment["TMUX_PANE"].map { ["-t", $0] } ?? []) + [Self.tmuxFormat])
            .map { String(decoding: $0, as: UTF8.self) } ?? "") : nil
        Self.tmux = tmux?.passthrough ?? false
        let nested = !inTmux && ["screen", "tmux"].contains { (environment["TERM"] ?? "").hasPrefix($0) }
        var probe = (kitty: false, files: false, sixel: tmux?.sixel ?? false, input: [UInt8]())
        if tmux?.passthrough ?? !nested {
            probe = Self.probeGraphics(tty, files: imageFiles)
            if let tmux { probe.sixel = tmux.sixel } // tmux draws sixels, so what counts is what it can
        }
        let kitty = probe.kitty
        Self.saved?.kitty = kitty
        if !probe.files, let imageFiles {
            try? FileManager.default.removeItem(atPath: imageFiles)
            Self.saved?.imageFiles = nil
        }
        var chafa: [String] = []
        var sixel = false
        if !kitty {
            guard let about = Self.output(of: ["chafa", "--version"]) else {
                Self.restoreTerminal()
                warn("showing images in this terminal needs chafa")
                return nil
            }
            // as in "Chafa version 1.18.3"
            let parts = String(decoding: about, as: UTF8.self).split(whereSeparator: \.isWhitespace).dropFirst(2)
                .first?.split(separator: ".").compactMap { Int($0) } ?? []
            let version = parts.count > 1 ? (parts[0], parts[1]) : (0, 0)
            // sixels go at the terminal's pixels, which it may not give
            var size = winsize()
            let pixels = ioctl(tty, UInt(TIOCGWINSZ), &size) == 0 && size.ws_xpixel > 0 && size.ws_ypixel > 0
            // Sixels need chafa 1.14, which can be kept from wrapping them for tmux, as tmux draws
            // them itself. chafa keeps the canvas's pixels, the view being large enough at the scale
            // it gives sixels, 1, and only pads them below. Undithered, they take a third of the
            // bytes, closer to the image. chafa's default symbols add box-drawing lines, which
            // streak a photo. chafa 1.16 and later may probe the terminal, whose answers would
            // then arrive as keys.
            sixel = probe.sixel && pixels && version >= (1, 14)
            chafa = (sixel ? ["chafa", "--format=sixels", "--dither=none", "--passthrough=none"]
                : ["chafa", "--format=symbols", "--symbols=block+space-wide-inverted", "--stretch"])
                + ["--polite=on", "--relative=off", "--animate=off"] + (version >= (1, 16) ? ["--probe=off"] : [])
        }
        self.viewer = viewer
        self.tty = tty
        self.kitty = kitty
        self.sixel = sixel
        self.imageFiles = probe.files ? imageFiles : nil
        self.chafa = chafa
        self.frame = frame
        probeInput = probe.input
        // unlike another viewer's in the same terminal; in tmux, the high byte of the ids, from the
        // pane, so viewers in two panes differ
        // shortcut: panes 255 apart share it; a registry in a tmux option would part them
        let pane = environment["TMUX_PANE"].flatMap { Int($0.dropFirst()) } ?? Int(getpid())
        lastImageID = Self.tmux ? UInt32(pane % 255 + 1) << 24 : UInt32(getpid() & 0xffff) << 8
        renderer = ImlibRenderer(viewer: viewer)
        renderer.drawsBar = false // the terminal's last line shows it
        renderer.clearBackground = true // the terminal's own shows around the image

        renderer.onThumbnail = { [unowned self] in self.setNeedsRedraw(image: true, after: 0.3) }
        viewer.ui = self
        let input = DispatchSource.makeReadSource(fileDescriptor: tty, queue: .main)
        input.setEventHandler { [unowned self] in self.readKeys() }
        signal(SIGWINCH, SIG_IGN)
        let resized = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resized.setEventHandler { [unowned self] in self.layoutChanged() }
        input.resume()
        resized.resume()
        sources = stops + [input, resized]
    }

    func run() -> Never {
        viewer.start()
        take(probeInput[...])
        dispatchMain()
    }

    // -o and Q print to the terminal once it is back, without the frames it kept
    func willQuit() {
        Self.writeAll(tty, imagesLeft())
        Self.restoreTerminal()
    }

    // the handler gets the terminal as the viewer found it, for its prompts and its output
    func keyHandlerWillRun() {
        Self.writeAll(tty, imagesLeft())
        Self.leave()
    }

    // the viewer's images out of the terminal, kept or shown: tmux's placeholders show the image
    // through a placement that deleting what is on screen leaves
    private func imagesLeft() -> [UInt8] {
        Array(Set(kept.values.map(\.id) + [shownImage]).subtracting([0]).map { Self.delete($0) }.joined().utf8)
    }

    func keyHandlerDidRun() {
        Self.enter()
        // the alternate screen comes back empty, without the images it held, and the handler may
        // have left images of its own
        shownImage = 0
        shownKey = nil
        kept = [:]
        keptOrder = []
        setNeedsRedraw(image: true)
    }

    // raw keys and the alternate screen, for as long as the viewer has the terminal
    private static func enter() {
        guard let saved = Self.saved else { return }
        // keys as they come and without echo, C-c and C-z among them; output turns "\n" into
        // "\r\n", which chafa's rows rely on
        var raw = saved.mode
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_oflag |= tcflag_t(OPOST | ONLCR)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        tcsetattr(saved.tty, TCSAFLUSH, &raw)
        // the alternate screen, with no cursor and no wrapping, so a line too long cannot scroll it
        writeAll(saved.tty, Array("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?7l".utf8))
    }

    private static func leave() {
        guard var saved = Self.saved else { return }
        let images = saved.kitty ? deleteImages : "" // the frame's image goes with the alternate screen
        writeAll(saved.tty, Array("\(images)\u{1b}[0m\u{1b}[?7h\u{1b}[?25h\u{1b}[?1049l".utf8))
        tcsetattr(saved.tty, TCSAFLUSH, &saved.mode)
    }

    private static func restoreTerminal() {
        guard let saved = Self.saved else { return }
        leave()
        unlink(saved.frame)
        unlink(saved.frame + "-ahead")
        if let imageFiles = saved.imageFiles { try? FileManager.default.removeItem(atPath: imageFiles) }
        Self.saved = nil
    }

    // MARK: - kitty graphics

    // every image on screen, quietly; not in tmux, where it would take those of other panes, and
    // the viewer's own show through virtual placements, which go by their ids
    private static var deleteImages: String { tmux ? "" : command("a=d,d=A,q=2") }

    // a kitty graphics command, wrapped in tmux for tmux to pass to the terminal around it
    private static func command(_ keys: String) -> String {
        let command = "\u{1b}_G\(keys)\u{1b}\\"
        return tmux ? passthrough(command) : command
    }

    // what tmux passes unread to the terminal around it, its escapes doubled
    static func passthrough(_ sequence: String) -> String {
        "\u{1b}Ptmux;\(sequence.replacingOccurrences(of: "\u{1b}", with: "\u{1b}\u{1b}"))\u{1b}\\"
    }

    // What tmux passes on: kitty graphics with allow-passthrough, to a client with UTF-8, which
    // the placeholders are, and sixels where tmux draws them, from tmux 3.6, and its client shows
    // them; tmux claims sixels whatever is around it. A client that is another tmux, or screen,
    // gets neither.
    static let tmuxFormat = "#{allow-passthrough}|#{client_utf8}|#{sixel_support}|#{client_termfeatures}|#{client_termname}"

    static func tmuxSupport(_ answer: String) -> (passthrough: Bool, sixel: Bool) {
        let fields = answer.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5, !["screen", "tmux"].contains(where: { fields[4].hasPrefix($0) }) else { return (false, false) }
        return (["on", "all"].contains(fields[0]) && fields[1] == "1",
                fields[2] == "1" && fields[3].split(separator: ",").contains("sixel"))
    }

    // A terminal with kitty graphics answers a query for a one-pixel image with OK, before the
    // device attributes any terminal reports, which name sixels where it has them; one that never
    // answers gets symbols after a second. A second query, for the pixel in a file, tells whether
    // the terminal reads the viewer's files. In tmux, all three go to the terminal around it.
    // Everything read meanwhile comes back too, for the keys typed during the probe.
    private static func probeGraphics(_ tty: Int32, files: String?) -> (kitty: Bool, files: Bool, sixel: Bool, input: [UInt8]) {
        var query = command("i=31,s=1,v=1,a=q,t=d,f=24;AAAA")
        if let files, FileManager.default.createFile(atPath: files + "/probe", contents: Data([0, 0, 0])) {
            query += command("i=32,s=1,v=1,a=q,t=t,f=24;\(Data((files + "/probe").utf8).base64EncodedString())")
        }
        writeAll(tty, Array((query + (tmux ? passthrough("\u{1b}[c") : "\u{1b}[c")).utf8))
        var reply: [UInt8] = []
        let deadline = Date().addingTimeInterval(1)
        while deadline.timeIntervalSinceNow > 0 {
            var ready = pollfd(fd: tty, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            var bytes = [UInt8](repeating: 0, count: 256)
            let n = read(tty, &bytes, bytes.count)
            guard n > 0 else { break }
            reply += bytes[..<n]
            if let answer = graphics(in: reply) { return (answer.kitty, answer.files, answer.sixel, reply) }
        }
        return (false, false, false, reply)
    }

    // what the replies to those queries say; nil until the device attributes end them, whose
    // parameters after the first name the terminal's features, 4 for sixels
    static func graphics(in reply: [UInt8]) -> (kitty: Bool, files: Bool, sixel: Bool)? {
        let text = String(decoding: reply, as: UTF8.self)
        guard let attributes = text.range(of: "\u{1b}[?"), let end = text[attributes.upperBound...].firstIndex(of: "c")
        else { return nil }
        let answers = text[..<attributes.lowerBound]
        let features = text[attributes.upperBound..<end].split(separator: ";").dropFirst()
        return (answers.contains("\u{1b}_Gi=31;OK"), answers.contains("\u{1b}_Gi=32;OK"), features.contains("4"))
    }

    // the kitty images that a reply says are gone, as when the terminal needed their room
    static func missingImages(in bytes: [UInt8]) -> [UInt32] {
        String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1b}_Gi=").dropFirst().compactMap { reply in
            guard let end = reply.range(of: "\u{1b}\\"), !reply[..<end.lowerBound].hasSuffix(";OK") else { return nil }
            return UInt32(reply.prefix { $0.isNumber })
        }
    }

    // a PNG as a kitty image, in the protocol's chunks of at most 4096 bytes of base64, each
    // a command of its own; the keys go on the first. q=2 keeps the terminal's answers from
    // arriving as keys.
    static func kittyImage(_ png: Data, keys: String) -> [UInt8] {
        let payload = [UInt8](png.base64EncodedData())
        // a command split around its payload, which holds no escape to double for tmux
        let parts = command("\u{0}").components(separatedBy: "\u{0}").map { Array($0.utf8) }
        var out: [UInt8] = []
        var start = 0
        repeat {
            let end = min(start + 4096, payload.count)
            let more = end < payload.count ? 1 : 0
            let chunkKeys = start == 0 ? "\(keys),f=100,t=d,q=2,m=\(more)" : "m=\(more),q=2"
            out += parts[0] + Array("\(chunkKeys);".utf8) + payload[start..<end] + parts[1]
            start = end
        } while start < payload.count
        return out
    }

    // The canvas sent to the terminal as image id, with the bytes the terminal stores for it: raw
    // pixels in a file the terminal reads and deletes itself, kept as they came, or PNG through
    // the terminal, decoded to RGBA. A canvas the image does not cover goes with its alpha, so the
    // terminal's background shows around the image. With place, it also shows at the top left,
    // scaled to the image rows, as placement 1.
    private func transmit(_ canvas: Imlib_Image, id: UInt32, place: Bool, opaque: Bool,
                          hidden: Bool = false) -> (command: [UInt8], bytes: Int)? {
        // hidden: placement 2, one cell at the cursor below cell backgrounds
        let keys = place ? "a=T,\(placement(id))" : hidden ? "a=T,i=\(id),p=2,c=1,r=1,z=-1073741825,C=1" : "a=t,i=\(id)"
        imlib_context_set_image(canvas)
        let width = Int(imlib_image_get_width()), height = Int(imlib_image_get_height())
        if let imageFiles, let path = Self.pixelFile(of: canvas, at: "\(imageFiles)/\(id)", alpha: !opaque) {
            let file = Data(path.utf8).base64EncodedString(), channels = opaque ? 3 : 4
            return (Array(Self.command("\(keys),f=\(8 * channels),s=\(width),v=\(height),t=t,q=2;\(file)").utf8),
                    channels * width * height)
        }
        return Self.png(of: canvas, alpha: !opaque).map { (Self.kittyImage($0, keys: keys), 4 * width * height) }
    }

    // the canvas as raw RGB, or RGBA, in the file at path; nil when the file could not take it
    // whole, as on a full disk, which the terminal would answer only with an error the viewer
    // does not ask for
    private static func pixelFile(of canvas: Imlib_Image, at path: String, alpha: Bool) -> String? {
        imlib_context_set_image(canvas)
        let width = Int(imlib_image_get_width()), height = Int(imlib_image_get_height())
        guard let argb = imlib_image_get_data_for_reading_only() else { return nil }
        let channels = alpha ? 4 : 3
        let pixels = [UInt8](unsafeUninitializedCapacity: channels * width * height) { bytes, count in
            for i in 0..<width * height {
                let p = argb[i], at = channels * i
                bytes[at] = UInt8(truncatingIfNeeded: p >> 16)
                bytes[at + 1] = UInt8(truncatingIfNeeded: p >> 8)
                bytes[at + 2] = UInt8(truncatingIfNeeded: p)
                if alpha { bytes[at + 3] = UInt8(truncatingIfNeeded: p >> 24) }
            }
            count = channels * width * height
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let whole = writeAll(fd, pixels)
        close(fd)
        if !whole { unlink(path) }
        return whole ? path : nil
    }

    private static func delete(_ id: UInt32) -> String { command("a=d,d=I,i=\(id),q=2") }

    // Placement 1 of image id over the image rows: at the top left, or in tmux a virtual one, which
    // the placeholders show
    private func placement(_ id: UInt32) -> String {
        Self.tmux ? "U=1,i=\(id),p=1,c=\(cols),r=\(placedRows)" : "i=\(id),p=1,C=1,c=\(cols),r=\(imageRows)"
    }

    // the rows a placeholder can name
    private var placedRows: Int { min(imageRows, Self.diacritics.count) }

    // An id no kept frame uses. In tmux, its low byte goes in a 256-color foreground, from 16 up,
    // as tmux may turn the first 16 into other colors, and its high byte stays the viewer's own.
    private func newImageID() -> UInt32 {
        let used = Set(kept.values.map(\.id))
        repeat {
            if Self.tmux {
                let low = lastImageID & 0xff
                lastImageID = lastImageID & 0xff00_0000 | (low < 16 || low == 255 ? 16 : low + 1)
            } else {
                lastImageID = lastImageID % 0xff_ffff + 1
            }
        } while used.contains(lastImageID) || lastImageID == shownImage
        return lastImageID
    }

    // The terminal holds the frames the viewer kept, within what herdr keeps a pane, 64 MiB, and
    // fewer than the ids tmux's placeholders tell apart. A kept frame shows again by placement
    // alone; the one it replaces loses its placement only.
    private static let keptBudget = 56 << 20
    private static let keptLimit = 128

    // a frame the terminal holds, now the most recently shown
    private func keep(_ key: FrameKey, id: UInt32, bytes: Int) {
        kept[key] = (id, bytes)
        keptOrder.removeAll { $0 == key }
        keptOrder.append(key)
    }

    // the frames past the budget out of the terminal, least recently shown first, all but the
    // shown one and spared, one just sent ahead
    private func trimKept(sparing spared: FrameKey? = nil) -> [UInt8] {
        var out = ""
        var total = kept.values.reduce(0) { $0 + $1.bytes }
        while total > Self.keptBudget || kept.count > Self.keptLimit,
              let oldest = keptOrder.first(where: { $0 != spared && $0 != shownKey }),
              let frame = kept.removeValue(forKey: oldest) {
            keptOrder.removeAll { $0 == oldest }
            total -= frame.bytes
            out += Self.delete(frame.id)
        }
        return Array(out.utf8)
    }

    // The view, from a kept frame or a new one, in place of what the screen shows, and what goes
    // once it shows: the frame there before loses its placement, or goes entirely when it was not
    // kept, with the frames past the budget
    private func kittyFrame(_ key: FrameKey?) -> (show: [UInt8], hide: [UInt8])? {
        // what other programs left, before the viewer sent any image of its own
        var show = Array((shownImage == 0 && kept.isEmpty ? Self.deleteImages : "").utf8)
        let id: UInt32
        if let key, let frame = kept[key] {
            id = frame.id
            keep(key, id: id, bytes: frame.bytes)
            // q=1 leaves an answer when the terminal dropped the image, so it goes again
            show += Array(Self.command("a=p,\(placement(id)),q=1").utf8)
        } else {
            id = newImageID()
            guard let canvas = drawCanvas(), let sent = transmit(canvas.image, id: id, place: true, opaque: canvas.opaque)
            else { return nil }
            show += sent.command
            if let key { keep(key, id: id, bytes: sent.bytes) }
        }
        if Self.tmux { show += Array(placeholders(id).utf8) }
        let hide = shownImage != id ? Array(hideShown().utf8) : []
        shownImage = id
        shownKey = key
        return (show, hide + trimKept())
    }

    // The image as text in tmux, which redraws it with the pane, and which the terminal around it
    // shows as image id: its low byte is the foreground of the 256 colors. The cells are the same
    // for every image of the viewer's, so they are made once a layout.
    private func placeholders(_ id: UInt32) -> String {
        let layout = [cols, placedRows, Int(id >> 24)]
        if placeholderCache.layout != layout {
            placeholderCache = (layout, Self.placeholderCells(columns: cols, rows: placedRows, high: Int(id >> 24)))
        }
        return "\u{1b}[38;5;\(id & 0xff)m\(placeholderCache.cells)\u{1b}[39m"
    }

    // U+10EEEE in each cell, the row, column 0 and the id's high byte in diacritics on the first
    // cell of each row, from which the cells after it count on. Diacritics on every cell would
    // nearly triple the text, which tmux redraws a cell at a time as they come: past 8 bytes a
    // cell, tmux drops what it has yet to send and redraws the window, and with allow-passthrough
    // on it drops what passes through until it has.
    // shortcut: a tmux menu over part of a row leaves the cells right of it blank until it closes
    static func placeholderCells(columns: Int, rows: Int, high: Int) -> String {
        var text = ""
        for row in 0..<min(rows, diacritics.count) where columns > 0 {
            text += "\u{1b}[\(row + 1);1H\u{10EEEE}\(diacritics[row])\(diacritics[0])\(diacritics[high])"
            text += String(repeating: "\u{10EEEE}", count: columns - 1)
        }
        return text
    }

    // the kitty graphics protocol's diacritics for numbers in placeholders, the nth for n
    private static let diacritics = [
        0x0305, 0x030d, 0x030e, 0x0310, 0x0312, 0x033d, 0x033e, 0x033f, 0x0346, 0x034a, 0x034b, 0x034c,
        0x0350, 0x0351, 0x0352, 0x0357, 0x035b, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
        0x036a, 0x036b, 0x036c, 0x036d, 0x036e, 0x036f, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
        0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059c, 0x059d, 0x059e, 0x059f, 0x05a0, 0x05a1,
        0x05a8, 0x05a9, 0x05ab, 0x05ac, 0x05af, 0x05c4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
        0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065a, 0x065b, 0x065d, 0x065e, 0x06d6, 0x06d7, 0x06d8,
        0x06d9, 0x06da, 0x06db, 0x06dc, 0x06df, 0x06e0, 0x06e1, 0x06e2, 0x06e4, 0x06e7, 0x06e8, 0x06eb,
        0x06ec, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073a, 0x073d, 0x073f, 0x0740, 0x0741, 0x0743,
        0x0745, 0x0747, 0x0749, 0x074a, 0x07eb, 0x07ec, 0x07ed, 0x07ee, 0x07ef, 0x07f0, 0x07f1, 0x07f3,
        0x0816, 0x0817, 0x0818, 0x0819, 0x081b, 0x081c, 0x081d, 0x081e, 0x081f, 0x0820, 0x0821, 0x0822,
        0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082a, 0x082b, 0x082c, 0x082d, 0x0951, 0x0953, 0x0954,
        0x0f82, 0x0f83, 0x0f86, 0x0f87, 0x135d, 0x135e, 0x135f, 0x17dd, 0x193a, 0x1a17, 0x1a75, 0x1a76,
        0x1a77, 0x1a78, 0x1a79, 0x1a7a, 0x1a7b, 0x1a7c, 0x1b6b, 0x1b6d, 0x1b6e, 0x1b6f, 0x1b70, 0x1b71,
        0x1b72, 0x1b73, 0x1cd0, 0x1cd1, 0x1cd2, 0x1cda, 0x1cdb, 0x1ce0, 0x1dc0, 0x1dc1, 0x1dc3, 0x1dc4,
        0x1dc5, 0x1dc6, 0x1dc7, 0x1dc8, 0x1dc9, 0x1dcb, 0x1dcc, 0x1dd1, 0x1dd2, 0x1dd3, 0x1dd4, 0x1dd5,
        0x1dd6, 0x1dd7, 0x1dd8, 0x1dd9, 0x1dda, 0x1ddb, 0x1ddc, 0x1ddd, 0x1dde, 0x1ddf, 0x1de0, 0x1de1,
        0x1de2, 0x1de3, 0x1de4, 0x1de5, 0x1de6, 0x1dfe, 0x20d0, 0x20d1, 0x20d4, 0x20d5, 0x20d6, 0x20d7,
        0x20db, 0x20dc, 0x20e1, 0x20e7, 0x20e9, 0x20f0, 0x2cef, 0x2cf0, 0x2cf1, 0x2de0, 0x2de1, 0x2de2,
        0x2de3, 0x2de4, 0x2de5, 0x2de6, 0x2de7, 0x2de8, 0x2de9, 0x2dea, 0x2deb, 0x2dec, 0x2ded, 0x2dee,
        0x2def, 0x2df0, 0x2df1, 0x2df2, 0x2df3, 0x2df4, 0x2df5, 0x2df6, 0x2df7, 0x2df8, 0x2df9, 0x2dfa,
        0x2dfb, 0x2dfc, 0x2dfd, 0x2dfe, 0x2dff, 0xa66f, 0xa67c, 0xa67d, 0xa6f0, 0xa6f1, 0xa8e0, 0xa8e1,
        0xa8e2, 0xa8e3, 0xa8e4, 0xa8e5, 0xa8e6, 0xa8e7, 0xa8e8, 0xa8e9, 0xa8ea, 0xa8eb, 0xa8ec, 0xa8ed,
        0xa8ee, 0xa8ef, 0xa8f0, 0xa8f1, 0xaab0, 0xaab2, 0xaab3, 0xaab7, 0xaab8, 0xaabe, 0xaabf, 0xaac1,
        0xfe20, 0xfe21, 0xfe22, 0xfe23, 0xfe24, 0xfe25, 0xfe26, 0x10a0f, 0x10a38, 0x1d185, 0x1d186, 0x1d187,
        0x1d188, 0x1d189, 0x1d1aa, 0x1d1ab, 0x1d1ac, 0x1d1ad, 0x1d242, 0x1d243, 0x1d244
    ].map { String(UnicodeScalar(UInt32($0))!) }

    // the shown frame off the screen, a kept one with its pixels still in the terminal: d=A would
    // free it, and kitty might free every frame sent ahead with it
    private func hideShown() -> String {
        defer {
            shownImage = 0
            shownKey = nil
        }
        guard shownImage != 0 else { return "" }
        let keptShown = kept.values.contains { $0.id == shownImage }
        return keptShown ? Self.command("a=d,d=i,i=\(shownImage),p=1,q=2") : Self.delete(shownImage)
    }

    // The key of the current view, nil in the grid and without an image
    private func currentKey() -> FrameKey? {
        guard !viewer.thumbnailMode, viewer.image != nil, let path = viewer.currentEntry?.path else { return nil }
        let pixels = framePixels(viewer.viewport, image: true)
        return key(path: path, frame: viewer.frameIndex, rotation: viewer.rotation, flipH: viewer.flipH,
                   flipV: viewer.flipV, view: viewer.viewport, pixels: pixels)
    }

    private func key(path: String, frame: Int, rotation: Int, flipH: Bool, flipV: Bool, view: Viewport,
                     pixels: (width: Int, height: Int, scale: Double)) -> FrameKey {
        FrameKey(path: path, frame: frame, rotation: rotation, flipH: flipH, flipV: flipV, gamma: viewer.gamma,
                 contrast: viewer.contrast, x: view.imageRect.minX, y: view.imageRect.minY, zoom: view.zoom,
                 antialias: view.antialias, alphaLayer: view.alphaLayer, width: pixels.width, height: pixels.height)
    }

    // While no key comes, the next image, then the previous one, goes to the terminal in its
    // first view, each in a turn of the main queue of its own, unless a key is waiting by then;
    // for sixels, chafa makes its frame in the background.
    // shortcut: Imlib2 decodes on the main queue, so a key that comes during a prefetch waits
    // for it, and images over 25 megapixels are left out; a second process would decode alongside
    private func schedulePrefetch() {
        prefetch?.cancel()
        guard kitty || sixel, hasImageArea, !viewer.thumbnailMode else { return }
        let work = DispatchWorkItem { [unowned self] in self.prefetchNeighbor() }
        prefetch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func prefetchNeighbor() {
        var ready = pollfd(fd: tty, events: Int16(POLLIN), revents: 0)
        guard !imageDirty, !chafaAhead, poll(&ready, 1, 0) == 0 else { return } // a key or a frame comes first
        // the shown frame stays, and so does the neighbor before: one that would push it out waits,
        // or the two would push each other out for as long as no key comes
        var reserved = kept.values.first { $0.id == shownImage }?.bytes ?? 0
        for index in [viewer.current + direction, viewer.current - direction] where viewer.files.indices.contains(index) {
            let entry = viewer.files[index]
            if let frame = kept.first(where: { $0.key.path == entry.path }) {
                reserved += frame.value.bytes
                continue
            }
            if chafaFrames.keys.contains(where: { $0.path == entry.path }) { continue }
            // peek decodes, so a neighbor it turned down waits for its file to change
            guard !notAhead.contains(entry.path) else { continue }
            let stamp = Self.stamp(entry.path)
            guard let next = renderer.peek(entry.url) else {
                notAhead.insert(entry.path)
                continue
            }
            defer { renderer.release(next.image) }
            guard next.size.width * next.size.height <= 25_000_000 else {
                notAhead.insert(entry.path)
                continue
            }
            var view = viewer.viewport
            view.setImageSize(next.size, resetView: true) // as loading it will
            let pixels = framePixels(view, image: true)
            let bytes = (imageFiles == nil ? 4 : 3) * pixels.width * pixels.height // as transmit counts
            guard !kitty || reserved + bytes <= Self.keptBudget else { return }
            let key = key(path: entry.path, frame: 0, rotation: 0, flipH: false, flipV: false, view: view, pixels: pixels)
            guard let canvas = makeCanvas(pixels.width, pixels.height) else { return }
            let opaque = renderer.drawStill(next.image, view: view, into: canvas, width: pixels.width,
                                            height: pixels.height, scale: pixels.scale)
            if !kitty { // chafa reads the frame from a file of its own, as the view's may be drawn meanwhile
                guard let png = Self.png(of: canvas, level: Z_NO_COMPRESSION, alpha: !opaque),
                      FileManager.default.createFile(atPath: frame + "-ahead", contents: png) else { return }
                if let stamp { loaded[entry.path] = (ImageInfo(size: next.size, delays: [0.1]), stamp) }
                chafaAhead = true
                let arguments = chafa + [chafaSize, frame + "-ahead"]
                let forgotten = framesForgotten
                DispatchQueue.global(qos: .utility).async {
                    let drawn = Self.chafaOutput(arguments, sixelHeight: pixels.height)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.chafaAhead = false
                        // a file that changed, or another layout, meanwhile makes the frame stale;
                        // after a failure, the next frame tries again
                        guard let drawn, forgotten == self.framesForgotten else { return }
                        self.keepChafa(key, drawn)
                        self.schedulePrefetch()
                    }
                }
                return
            }
            // in a file, a frame with transparency takes 4 bytes a pixel, which must fit before it is written
            guard imageFiles == nil || opaque || reserved + 4 * pixels.width * pixels.height <= Self.keptBudget else { return }
            let id = newImageID()
            // a frame that went as PNG, as when the disk is full, takes more room than counted
            // under the status bar's last cell, whose background hides it
            let hidden = placeAhead && !Self.tmux && viewer.barVisible && rows > imageRows
            guard let sent = transmit(canvas, id: id, place: false, opaque: opaque, hidden: hidden),
                  reserved + sent.bytes <= Self.keptBudget
            else { return }
            if let stamp { loaded[entry.path] = (ImageInfo(size: next.size, delays: [0.1]), stamp) }
            keep(key, id: id, bytes: sent.bytes)
            let cell = hidden ? Array("\u{1b}[\(rows);\(cols)H".utf8) : []
            Self.writeAll(tty, cell + sent.command + (hidden ? Array("\u{1b}[H".utf8) : []) + trimKept(sparing: key))
            schedulePrefetch()
            return
        }
    }

    // MARK: - keys

    private func readKeys() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = read(tty, &bytes, bytes.count)
        if n < 0, errno == EINTR || errno == EAGAIN { return }
        guard n > 0 else { viewer.quit() } // the terminal went away
        take(bytes[..<n])
    }

    // the keys in what the terminal sent; a sequence it ends inside waits for the next bytes
    private func take(_ bytes: ArraySlice<UInt8>) {
        cutOffTimeout?.cancel()
        prefetch?.cancel() // the next frame first; prefetching resumes after it
        for id in Self.missingImages(in: cutOff + bytes) { forget(id) }
        let parsed = Self.keys(in: cutOff + bytes)
        cutOff = parsed.rest
        handle(parsed.keys)
        guard !cutOff.isEmpty else { return }
        // the rest of a sequence comes within a moment; a lone escape is the Escape key, and ESC _
        // Alt and _
        let timeout = DispatchWorkItem { [unowned self] in
            let rest = self.cutOff
            self.cutOff = []
            switch rest {
            case [0x1b]: self.handle([Keystroke(key: "Escape")])
            case [0x1b, 0x5f]: self.handle([Keystroke(key: "_")])
            default: self.handle([nil])
            }
        }
        cutOffTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: timeout)
    }

    private func handle(_ keys: [Keystroke?]) {
        for key in Self.collapsingRepeats(keys) {
            guard let key else {
                viewer.endPrefix()
                continue
            }
            // C-c quits, as in most terminal programs, where no binding and no C-x prefix took it
            if !viewer.handle(key), key == Keystroke(key: "c", ctrl: true) { viewer.quit() }
        }
    }

    // The keys in a burst of terminal input, named as on X11: printable text as typed, control
    // bytes as C-letter, the usual escape sequences by keysym name, nil for a key with no name.
    // An escape sequence the burst ends inside comes back as rest, to join the next burst.
    // shortcut: C-m and C-[ send the bytes of Return and Escape, so those two bindings need the
    // kitty keyboard protocol, which the viewer does not turn on
    static func keys(in bytes: [UInt8]) -> (keys: [Keystroke?], rest: [UInt8]) {
        var keys: [Keystroke?] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1b {
                guard i + 1 < bytes.count else { return (keys, [b]) } // Escape, or a sequence's start
                let next = bytes[i + 1]
                // ESC _ G starts a kitty graphics reply, up to ESC \; ESC _ alone is Alt and _, so a
                // burst that ends after ESC _ leaves it to the next one
                if next == 0x5f {
                    guard i + 2 < bytes.count else { return (keys, Array(bytes[i...])) }
                    if bytes[i + 2] == 0x47 {
                        guard let end = (i + 2..<bytes.count).first(where: { bytes[$0] == 0x5c && bytes[$0 - 1] == 0x1b })
                        else { return (keys, Array(bytes[i...])) }
                        i = end + 1
                        continue
                    }
                }
                guard next == 0x5b || next == 0x4f else { // not ESC [ or ESC O
                    if (0x20...0x7e).contains(next) { // Alt and a key: the key, as on X11
                        keys.append(Keystroke(key: String(UnicodeScalar(next))))
                        i += 2
                    } else {
                        keys.append(Keystroke(key: "Escape"))
                        i += 1
                    }
                    continue
                }
                // parameters, then the final byte; any other byte cuts the sequence short
                var end = i + 2
                while end < bytes.count, (0x20...0x3f).contains(bytes[end]) { end += 1 }
                guard end < bytes.count else { return (keys, Array(bytes[i...])) }
                guard (0x40...0x7e).contains(bytes[end]) else {
                    keys.append(nil) // and the byte that cut it starts the next key
                    i = end
                    continue
                }
                let params = String(decoding: bytes[(i + 2)..<end], as: UTF8.self).split(separator: ";").map(String.init)
                // the second parameter is 1 plus the modifier bits, 4 being Ctrl: ESC [1;5A is C-Up
                let ctrl = params.count > 1 && (Int(params[1]).map { $0 > 1 && ($0 - 1) & 4 != 0 } ?? false)
                keys.append(sequenceName(bytes[end], params.first, ss3: bytes[i + 1] == 0x4f)
                    .map { Keystroke(key: $0, ctrl: ctrl) })
                i = end + 1
                continue
            }
            i += 1
            switch b {
            case 0x0d: keys.append(Keystroke(key: "Return"))
            case 0x09: keys.append(Keystroke(key: "Tab"))
            case 0x7f: keys.append(Keystroke(key: "BackSpace"))
            case 0x00: keys.append(Keystroke(key: " ", ctrl: true))
            case 0x1d: keys.append(Keystroke(key: "]", ctrl: true))
            case 0x1e: keys.append(Keystroke(key: "6", ctrl: true))
            case 0x01...0x1a: keys.append(Keystroke(key: String(UnicodeScalar(b + 0x60)), ctrl: true))
            case 0x20...0x7e: keys.append(Keystroke(key: String(UnicodeScalar(b))))
            case 0x80...0xbf: break // the rest of a character that is not ASCII
            default: keys.append(nil) // another control byte, or a character that is not ASCII
            }
        }
        return (keys, [])
    }

    private static func sequenceName(_ final: UInt8, _ first: String?, ss3: Bool) -> String? {
        switch final {
        case 0x41: return "Up"
        case 0x42: return "Down"
        case 0x43: return "Right"
        case 0x44: return "Left"
        case 0x46: return "End"
        case 0x48: return "Home"
        case 0x5a: return "ISO_Left_Tab" // Shift-Tab
        case 0x50...0x53 where ss3 || first == "1": return "F\(final - 0x4f)"
        case 0x7e:
            let names = ["1": "Home", "2": "Insert", "3": "Delete", "4": "End", "5": "Prior", "6": "Next",
                         "7": "Home", "8": "End", "11": "F1", "12": "F2", "13": "F3", "14": "F4", "15": "F5",
                         "17": "F6", "18": "F7", "19": "F8", "20": "F9", "21": "F10", "23": "F11", "24": "F12"]
            return first.flatMap { names[$0] }
        default: return nil
        }
    }

    // A key held over slow frames repeats faster than they draw: a run of three or more of one
    // key in one burst counts once, while a double tap still counts twice
    static func collapsingRepeats(_ keys: [Keystroke?]) -> [Keystroke?] {
        var out: [Keystroke?] = []
        var i = 0
        while i < keys.count {
            var end = i + 1
            while end < keys.count, keys[end] == keys[i] { end += 1 }
            out += end - i >= 3 ? [keys[i]] : Array(keys[i..<end])
            i = end
        }
        return out
    }

    // MARK: - ViewerUI

    // A still whose frame the terminal holds shows without Imlib2 or the disk, which on a network
    // share costs a round trip a file: its file's times are compared off the main queue, and a
    // file that changed loads again
    func loadImage(_ url: URL) -> ImageInfo? {
        if let file = loaded[url.path], !file.info.isAnimated, kept.keys.contains(where: { $0.path == url.path }) {
            DispatchQueue.global(qos: .userInitiated).async {
                guard Self.stamp(url.path) != file.stamp else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.viewer.currentEntry?.path == url.path else { return }
                    self.viewer.reloadCurrent()
                }
            }
            return file.info
        }
        return loadNow(url)
    }

    // a file that changed since its frames were drawn, as one rewritten while another showed,
    // loads without them
    private func loadNow(_ url: URL) -> ImageInfo? {
        let stamp = Self.stamp(url.path) // before the load, so a change during it shows next time
        if loaded[url.path]?.stamp != stamp { forgetFiles([url.path]) }
        let info = renderer.loadImage(url)
        rendererPath = url.path
        loaded[url.path] = info.flatMap { info in stamp.map { (info, $0) } }
        return info
    }

    // the renderer with the current image, before it draws it
    private func loadRenderer() {
        guard let entry = viewer.currentEntry, rendererPath != entry.path else { return }
        _ = loadNow(entry.url)
        renderer.imageChanged()
    }

    // what tells a file that changed from one that did not: its times, size and inode
    private static func stamp(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [info.st_mtim.tv_sec, info.st_mtim.tv_nsec, info.st_ctim.tv_sec, info.st_ctim.tv_nsec,
                Int(info.st_size), Int(truncatingIfNeeded: info.st_ino)]
    }

    func imageChanged() {
        if rendererPath == viewer.currentEntry?.path { renderer.imageChanged() }
        if viewer.current != lastIndex {
            direction = viewer.current > lastIndex ? 1 : -1
            lastIndex = viewer.current
        }
        setNeedsRedraw(image: true)
    }

    // a frame the terminal no longer holds, as a kept one it dropped for room, goes again if shown
    private func forget(_ id: UInt32) {
        for (key, frame) in kept where frame.id == id {
            kept[key] = nil
            keptOrder.removeAll { $0 == key }
        }
        if id == shownImage {
            shownImage = 0
            shownKey = nil
            setNeedsRedraw(image: true)
        }
    }

    // kept frames that no longer match, as of a file that changed or of another terminal size
    private func forgetFrames(where stale: (FrameKey) -> Bool) {
        framesForgotten += 1
        var out = ""
        for (key, frame) in kept where stale(key) {
            kept[key] = nil
            keptOrder.removeAll { $0 == key }
            if frame.id != shownImage { out += Self.delete(frame.id) } // the shown one goes once replaced
        }
        chafaFrames = chafaFrames.filter { !stale($0.key) }
        chafaOrder.removeAll(where: stale)
        if !out.isEmpty { Self.writeAll(tty, Array(out.utf8)) }
    }

    // a file that changed loads anew, for the frames and for what loading it gave
    private func forgetFiles(_ paths: Set<String>) {
        forgetFrames { paths.contains($0.path) }
        for path in paths { loaded[path] = nil }
        notAhead.subtract(paths)
        if let rendererPath, paths.contains(rendererPath) { self.rendererPath = nil }
    }

    func viewChanged() { setNeedsRedraw(image: true) }
    func gridChanged() { setNeedsRedraw(image: viewer.thumbnailMode) } // marks show in the grid only
    func barChanged() { setNeedsRedraw(image: false) }
    func beep() { Self.writeAll(tty, [0x07]) }

    func layoutChanged() {
        var size = winsize()
        if ioctl(tty, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            cols = Int(size.ws_col)
            rows = Int(size.ws_row)
            // whole pixels: a window may report a few pixels beyond its last cell
            if size.ws_xpixel >= size.ws_col, size.ws_ypixel >= size.ws_row {
                cell = (Double(Int(size.ws_xpixel) / cols), Double(Int(size.ws_ypixel) / rows))
            }
        }
        forgetFrames { _ in true }
        viewer.resizeCanvas(canvasSize)
        viewer.resizeGrid(canvasSize)
        setNeedsRedraw(image: true)
    }

    // the view in units of a sixteenth of a cell's height, so zoom reads the same either way
    private var canvasSize: CGSize {
        guard sixel else { return CGSize(width: Double(cols) * 16 * cell.width / cell.height, height: Double(imageRows) * 16) }
        return CGSize(width: Double(sixelPixels.width) * 16 / cell.height, height: Double(sixelPixels.height) * 16 / cell.height)
    }

    // A sixel image's pixels: 10 to a column, which chafa pads a width to, and whole bands of 6
    // rows, short of the screen's last row, as an image that reaches it scrolls the screen in most
    // terminals
    private var sixelPixels: (width: Int, height: Int) {
        (cols * Int(cell.width) / 10 * 10, min(imageRows, rows - 1) * Int(cell.height) / 6 * 6)
    }

    func invalidateThumbnails(_ entries: [FileEntry]) {
        renderer.invalidateThumbnails(entries)
        forgetFiles(Set(entries.map(\.path)))
        setNeedsRedraw(image: true)
    }

    // the terminal keeps its size, and the view fills it already
    func fitWindow() {}
    func resetWindowSize() {}
    func toggleFullscreen() {}

    func enterEditMode() -> Bool {
        warn("edit mode needs macOS: it draws with Core Graphics and reads text with Vision")
        return false
    }

    // MARK: - drawing

    private var imageRows: Int { max(0, rows - (viewer.barVisible ? 1 : 0)) }

    // room for a frame: rows above the bar, and for sixels whole bands short of the last row
    private var hasImageArea: Bool { cols > 0 && imageRows > 0 && (!sixel || sixelPixels.height > 0) }

    // A frame costs a chafa run or a whole image, so one in which only the status bar changed, as
    // after a mark, rewrites just the bar.
    // shortcut: thumbnails that come in one at a time redraw the grid at most every 0.3 s
    private func setNeedsRedraw(image: Bool, after delay: Double = 0) {
        if image { imageDirty = true }
        let due = DispatchTime.now() + delay
        if let redrawDue, redrawDue <= due { return }
        redrawDue = due
        let draw = { [self] in
            guard let redrawDue, redrawDue <= .now() else { return }
            self.redrawDue = nil
            render()
        }
        // the next turn of the main queue, after the keys read with this one; a timer takes longer
        if delay == 0 { DispatchQueue.main.async(execute: draw) } else { DispatchQueue.main.asyncAfter(deadline: due, execute: draw) }
    }

    // In synchronized output, the terminal shows the frame once it is whole, so the bar never
    // names an image that has yet to come; terminals without it ignore the mode.
    private func render() {
        var out = Array("\u{1b}[?2026h\u{1b}[H".utf8)
        // in tmux, what goes once the frame shows: tmux passes graphics on at once, but draws text
        // as synchronized output ends, so the frame before would go while its placeholders show
        var after: [UInt8] = []
        if imageDirty {
            imageDirty = false
            // a frame that could not be drawn clears the screen, so no other image stays under this name
            if hasImageArea {
                if kitty, let frame = kittyFrame(currentKey()) {
                    out += frame.show
                    if Self.tmux { after = frame.hide } else { out += frame.hide }
                } else if !kitty, let drawn = chafaFrame(currentKey()) {
                    // a sixel image leaves what it does not cover, as the last row and its own
                    // transparent pixels, so each starts on a clear screen
                    // shortcut: xterm, without synchronized output, shows the screen blank meanwhile
                    if sixel { out += Array("\u{1b}[2J".utf8) }
                    out += drawn
                } else { // the next redraw, even of the bar alone, tries again
                    imageDirty = true
                    out += Array((hideShown() + "\u{1b}[2J").utf8)
                }
            } else { // no row left for an image, as in a one-row terminal with the bar
                out += Array((hideShown() + (sixel ? "\u{1b}[2J" : "")).utf8)
            }
        }
        if viewer.barVisible, rows > 0 { out += Array("\u{1b}[\(rows);1H\u{1b}[0;7m\(statusLine())\u{1b}[0m".utf8) }
        out += Array("\u{1b}[H\u{1b}[?2026l".utf8) + after // home, where a stray warning cannot scroll the screen
        Self.writeAll(tty, out)
        if !imageDirty { schedulePrefetch() }
    }

    // The pixels a frame of view takes: the terminal's own for a kitty or sixel image, 16 a row for
    // chafa's symbols, which need no more. A kitty terminal scales an image up as Imlib2 does,
    // linearly, so an image shown larger than its pixels goes at those, which it scales itself;
    // not over the checkerboard, whose squares would grow with it.
    private func framePixels(_ view: Viewport, image: Bool) -> (width: Int, height: Int, scale: Double) {
        var scale = kitty || sixel ? cell.height / 16 : 1
        if kitty, image, view.antialias, !view.alphaLayer, view.zoom * scale > 1 { scale = 1 / view.zoom }
        return (max(1, Int((canvasSize.width * scale).rounded())), max(1, Int((canvasSize.height * scale).rounded())),
                scale)
    }

    // the current view drawn into the canvas, and whether it came out opaque
    private func drawCanvas() -> (image: Imlib_Image, opaque: Bool)? {
        if !viewer.thumbnailMode { loadRenderer() }
        let pixels = framePixels(viewer.viewport, image: !viewer.thumbnailMode && viewer.image != nil)
        guard let canvas = makeCanvas(pixels.width, pixels.height) else { return nil }
        return (canvas, renderer.render(into: canvas, width: pixels.width, height: pixels.height, scale: pixels.scale))
    }

    // the canvas, made anew for another size
    private func makeCanvas(_ width: Int, _ height: Int) -> Imlib_Image? {
        if canvasPixels.width != width || canvasPixels.height != height {
            if let canvas {
                imlib_context_set_image(canvas)
                imlib_free_image()
            }
            canvas = imlib_create_image(Int32(width), Int32(height))
            canvasPixels = (width, height)
            if let canvas {
                imlib_context_set_image(canvas)
                imlib_image_set_format("png")
                imlib_image_attach_data_value("compression", nil, 1, nil) // quick to write, read at once
            }
        }
        return canvas
    }

    // The canvas as a PNG: 8-bit RGB, or RGBA with alpha, each row with the Up filter, zlib at its
    // fastest level by default. libpng, which Imlib2 saves with, tries all five filters on every
    // row; for a 2560x1638 frame that took 306 ms against 116 ms here, for 3% less data.
    static func png(of image: Imlib_Image, level: Int32 = Z_BEST_SPEED, alpha: Bool = false) -> Data? {
        imlib_context_set_image(image)
        let width = Int(imlib_image_get_width()), height = Int(imlib_image_get_height())
        guard let argb = imlib_image_get_data_for_reading_only() else { return nil }
        let channels = alpha ? 4 : 3
        let stride = 1 + channels * width
        var rows = [UInt8](repeating: 0, count: stride * height)
        var above = [UInt8](repeating: 0, count: channels * width) // the row above, before its filter
        rows.withUnsafeMutableBufferPointer { rows in
            above.withUnsafeMutableBufferPointer { above in
                for y in 0..<height {
                    let row = rows.baseAddress! + y * stride, pixels = argb + y * width
                    row[0] = 2 // Up: each byte less the one above it
                    for x in 0..<width {
                        let p = pixels[x], i = channels * x
                        let r = UInt8(truncatingIfNeeded: p >> 16), g = UInt8(truncatingIfNeeded: p >> 8)
                        let b = UInt8(truncatingIfNeeded: p)
                        row[1 + i] = r &- above[i]
                        row[2 + i] = g &- above[i + 1]
                        row[3 + i] = b &- above[i + 2]
                        above[i] = r
                        above[i + 1] = g
                        above[i + 2] = b
                        if alpha {
                            let a = UInt8(truncatingIfNeeded: p >> 24)
                            row[4 + i] = a &- above[i + 3]
                            above[i + 3] = a
                        }
                    }
                }
            }
        }
        var size = compressBound(uLong(rows.count))
        var deflated = [UInt8](repeating: 0, count: Int(size))
        guard compress2(&deflated, &size, rows, uLong(rows.count), level) == Z_OK else { return nil }
        func bigEndian(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).bigEndian, Array.init) }
        var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        func chunk(_ type: String, _ body: ArraySlice<UInt8>) {
            let typed = Array(type.utf8) + body
            png.append(contentsOf: bigEndian(body.count))
            png.append(contentsOf: typed)
            png.append(contentsOf: bigEndian(Int(crc32(0, typed, uInt(typed.count)))))
        }
        chunk("IHDR", ArraySlice(bigEndian(width) + bigEndian(height) + [8, alpha ? 6 : 2, 0, 0, 0])) // 8-bit RGB(A)
        chunk("IDAT", deflated[..<Int(size)])
        chunk("IEND", [])
        return png
    }

    // The view from chafa, as rows of colored symbols, one per cell, or as a sixel image; chafa
    // reads the canvas from an uncompressed PNG file, the quickest to write and read. The last
    // views' frames stay for a return.
    private func chafaFrame(_ key: FrameKey?) -> [UInt8]? {
        if let key, let drawn = chafaFrames[key] {
            keepChafa(key, drawn)
            return drawn
        }
        guard let canvas = drawCanvas(), let png = Self.png(of: canvas.image, level: Z_NO_COMPRESSION, alpha: !canvas.opaque),
              FileManager.default.createFile(atPath: frame, contents: png),
              let drawn = Self.chafaOutput(chafa + [chafaSize, frame], sixelHeight: sixel ? canvasPixels.height : nil)
        else { return nil }
        if let key { keepChafa(key, drawn) }
        return drawn
    }

    // chafa's frame for key, among the last 8
    private func keepChafa(_ key: FrameKey, _ drawn: [UInt8]) {
        chafaFrames[key] = drawn
        chafaOrder.removeAll { $0 == key }
        chafaOrder.append(key)
        while chafaOrder.count > 8 { chafaFrames[chafaOrder.removeFirst()] = nil }
    }

    // the view's size for chafa, in cells: the terminal's for symbols, and for sixels chafa's own
    // of 10x20 pixels, enough for the canvas, which chafa then leaves at its size
    private var chafaSize: String {
        sixel ? "--size=\(sixelPixels.width / 10)x\((sixelPixels.height + 19) / 20)" : "--size=\(cols)x\(imageRows)"
    }

    // what chafa drew from the file its arguments end with, without the newline after the bottom
    // row, which would scroll the screen, and a sixel image cut to its canvas; off the main queue too
    private static func chafaOutput(_ arguments: [String], sixelHeight: Int?) -> [UInt8]? {
        guard var drawn = output(of: arguments).map({ [UInt8]($0) }) else { return nil }
        if drawn.last == 0x0a { drawn.removeLast() }
        return sixelHeight.map { sixelImage(drawn, height: $0) } ?? drawn
    }

    // A sixel image cut to height, a multiple of 6: chafa pads some below the image, to a cell of
    // its own, which would reach into the bar, or past the end of the screen, scrolling it.
    // A - starts each band of 6 rows, and the raster attributes after the introducer's q name the
    // height.
    static func sixelImage(_ drawn: [UInt8], height: Int) -> [UInt8] {
        guard drawn.starts(with: [0x1b, 0x50]), let q = drawn.firstIndex(of: 0x71) else { return drawn }
        var out = Array(drawn[...q])
        var rest = drawn[(q + 1)...]
        if rest.first == 0x22, let end = rest.firstIndex(where: { !(0x30...0x3b).contains($0) && $0 != 0x22 }) {
            let raster = rest[rest.startIndex..<end].dropFirst().split(separator: 0x3b).map { String(decoding: $0, as: UTF8.self) }
            out += raster.count == 4 ? Array("\"\(raster[0]);\(raster[1]);\(raster[2]);\(height)".utf8) : Array(rest[..<end])
            rest = rest[end...]
        }
        var bands = 1
        for i in rest.indices where rest[i] == 0x2d {
            bands += 1
            if bands > height / 6 { return out + rest[..<i] + [0x1b, 0x5c] }
        }
        return out + rest
    }

    // the status bar as text: the name, or what went wrong, then the fields that fit
    // shortcut: counts characters, so a name with wide ones may push the end past the edge
    private func statusLine() -> String {
        let status = viewer.statusText
        let room = max(0, cols - 2)
        let right = Viewer.fittedStatus(status.right, room: CGFloat(room)) { CGFloat($0.count) }
        let name = Self.printable(viewer.errorText ?? status.left)
        let left = ImlibRenderer.truncatedHead(name, width: room - right.count - 1) { $0.count }
        return " \(left)\(String(repeating: " ", count: max(0, room - left.count - right.count)))\(right) "
    }

    // a file name may hold control characters, which the terminal would run as commands
    static func printable(_ s: String) -> String {
        var shown = String.UnicodeScalarView()
        for c in s.unicodeScalars { shown.append(c.value < 0x20 || (0x7f...0x9f).contains(c.value) ? "?" : c) }
        return String(shown)
    }

    // false when not all of bytes went, as to a terminal that went away or a full disk
    @discardableResult
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var done = 0
        while done < bytes.count {
            let n = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }

    // a program's output, waited for without a nested run loop; nil when it fails or is missing
    private static func output(of arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return process.terminationStatus == 0 ? data : nil
    }
}
#endif
