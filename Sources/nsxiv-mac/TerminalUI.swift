#if os(Linux)
import CX11
import Foundation

// The viewer in a terminal, for a machine without a display, as over SSH: the renderer draws
// the view, and the status bar takes the last line. A terminal with the kitty graphics protocol,
// as kitty, Ghostty, WezTerm or a herdr pane in one of them, gets the view as an image at its
// own pixels; any other gets it from chafa as colored symbols, one per cell. Keys arrive as the
// bytes the terminal sends for them.
final class TerminalUI: ViewerUI {
    private let viewer: Viewer
    private let renderer: ImlibRenderer
    private let tty: Int32
    private let kitty: Bool
    private let chafa: [String] // the command, without the size and the file
    private let frame: String // the drawn view as a PNG file, for chafa or the terminal
    private var canvas: Imlib_Image?
    private var canvasPixels = (width: 0, height: 0)
    private var cols = 80
    private var rows = 24
    private var cell = (width: 8.0, height: 16.0) // pixels, where the terminal says; else the usual 1:2 shape
    private var shownImage = 0 // the kitty image on screen, 1 or 2; 0 when there may be others
    private var imageDirty = true // false when only the status bar changed since the last frame
    private var redrawDue: DispatchTime?
    private var sources: [DispatchSourceProtocol] = []
    private var cutOff: [UInt8] = [] // an escape sequence the last read ended inside
    private var cutOffTimeout: DispatchWorkItem?
    private let probeInput: [UInt8] // the probe's answers, which the key parser skips, and keys typed meanwhile

    // what atexit puts back
    private static var saved: (tty: Int32, mode: termios, frame: String, kitty: Bool)?

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
        Self.saved = (tty, mode, frame, false)
        atexit { TerminalUI.restoreTerminal() }
        Self.enter()
        let probe = Self.probeKittyGraphics(tty)
        let kitty = probe.shows
        Self.saved?.kitty = kitty
        var chafa: [String] = []
        if !kitty {
            guard let about = Self.output(of: ["chafa", "--version"]) else {
                Self.restoreTerminal()
                warn("showing images in this terminal needs chafa")
                return nil
            }
            // as in "Chafa version 1.18.3"
            let version = String(decoding: about, as: UTF8.self).split(whereSeparator: \.isWhitespace).dropFirst(2)
                .first?.split(separator: ".").compactMap { Int($0) } ?? []
            // chafa's default symbols add box-drawing lines, which streak a photo; chafa 1.16 and
            // later may probe the terminal, whose answers would then arrive as keys
            chafa = ["chafa", "--format=symbols", "--symbols=block+space-wide-inverted", "--stretch", "--polite=on",
                     "--relative=off", "--animate=off"]
                + (version.count > 1 && (version[0], version[1]) >= (1, 16) ? ["--probe=off"] : [])
        }
        self.viewer = viewer
        self.tty = tty
        self.kitty = kitty
        self.chafa = chafa
        self.frame = frame
        probeInput = probe.input
        renderer = ImlibRenderer(viewer: viewer)
        renderer.drawsBar = false // the terminal's last line shows it

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

    // -o and Q print to the terminal once it is back
    func willQuit() { Self.restoreTerminal() }

    // the handler gets the terminal as the viewer found it, for its prompts and its output
    func keyHandlerWillRun() { Self.leave() }

    func keyHandlerDidRun() {
        Self.enter()
        shownImage = 0 // the handler may have left images of its own
        setNeedsRedraw(image: true) // the alternate screen comes back empty
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
        guard let frame = Self.saved?.frame else { return }
        leave()
        unlink(frame)
        Self.saved = nil
    }

    // MARK: - kitty graphics

    // every image on screen, quietly
    private static let deleteImages = "\u{1b}_Ga=d,d=A,q=2\u{1b}\\"

    // A terminal with kitty graphics answers a query for a one-pixel image with OK, before the
    // device attributes any terminal reports; one that never answers gets symbols after a second.
    // Everything read meanwhile comes back too, for the keys typed during the probe.
    private static func probeKittyGraphics(_ tty: Int32) -> (shows: Bool, input: [UInt8]) {
        writeAll(tty, Array("\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\\u{1b}[c".utf8))
        var reply: [UInt8] = []
        let deadline = Date().addingTimeInterval(1)
        while deadline.timeIntervalSinceNow > 0 {
            var ready = pollfd(fd: tty, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            var bytes = [UInt8](repeating: 0, count: 256)
            let n = read(tty, &bytes, bytes.count)
            guard n > 0 else { break }
            reply += bytes[..<n]
            if let shows = kittyGraphics(in: reply) { return (shows, reply) }
        }
        return (false, reply)
    }

    // what a reply to that query says; nil until the device attributes end it
    static func kittyGraphics(in reply: [UInt8]) -> Bool? {
        let text = String(decoding: reply, as: UTF8.self)
        guard let attributes = text.range(of: "\u{1b}[?"), text[attributes.upperBound...].contains("c") else { return nil }
        return text[..<attributes.lowerBound].contains("\u{1b}_Gi=31;OK")
    }

    // a PNG as a kitty image at the cursor, scaled to cols by rows cells, in the protocol's chunks
    // of at most 4096 bytes of base64; q=2 keeps the terminal's answers from arriving as keys
    static func kittyImage(_ png: Data, id: Int, cols: Int, rows: Int) -> [UInt8] {
        let payload = [UInt8](png.base64EncodedData())
        var out: [UInt8] = []
        var start = 0
        repeat {
            let end = min(start + 4096, payload.count)
            let more = end < payload.count ? 1 : 0
            let keys = start == 0 ? "a=T,f=100,t=d,i=\(id),q=2,C=1,c=\(cols),r=\(rows),m=\(more)" : "m=\(more),q=2"
            out += Array("\u{1b}_G\(keys);".utf8) + payload[start..<end] + Array("\u{1b}\\".utf8)
            start = end
        } while start < payload.count
        return out
    }

    // the next frame as a kitty image; the one it replaces goes once it is covered, so the
    // screen never shows a gap
    // shortcut: every frame goes whole, so an animation plays slowly over a slow link; kitty's
    // animation frames would send only what changed, if animations there matter
    private func kittyFrame(_ png: Data) -> [UInt8] {
        let id = shownImage == 1 ? 2 : 1
        var out = Array((shownImage == 0 ? Self.deleteImages : "").utf8) // what other programs left
        out += Self.kittyImage(png, id: id, cols: cols, rows: imageRows)
        if shownImage != 0 { out += Array("\u{1b}_Ga=d,d=I,i=\(shownImage),q=2\u{1b}\\".utf8) }
        shownImage = id
        return out
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
        let parsed = Self.keys(in: cutOff + bytes)
        cutOff = parsed.rest
        handle(parsed.keys)
        guard !cutOff.isEmpty else { return }
        // the rest of a sequence comes within a moment; a lone escape is the Escape key
        let timeout = DispatchWorkItem { [unowned self] in
            let lone = self.cutOff == [0x1b]
            self.cutOff = []
            self.handle([lone ? Keystroke(key: "Escape") : nil])
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
                // ESC _ G starts a kitty graphics reply, up to ESC \; ESC _ alone is Alt and _
                if next == 0x5f, i + 2 < bytes.count, bytes[i + 2] == 0x47 {
                    guard let end = (i + 2..<bytes.count).first(where: { bytes[$0] == 0x5c && bytes[$0 - 1] == 0x1b })
                    else { return (keys, Array(bytes[i...])) }
                    i = end + 1
                    continue
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

    func loadImage(_ url: URL) -> ImageInfo? { renderer.loadImage(url) }

    func imageChanged() {
        renderer.imageChanged()
        setNeedsRedraw(image: true)
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
        viewer.resizeCanvas(canvasSize)
        viewer.resizeGrid(canvasSize)
        setNeedsRedraw(image: true)
    }

    // the view in units of a sixteenth of a cell's height, so zoom reads the same either way
    private var canvasSize: CGSize {
        CGSize(width: Double(cols) * 16 * cell.width / cell.height, height: Double(imageRows) * 16)
    }

    func invalidateThumbnails(_ entries: [FileEntry]) {
        renderer.invalidateThumbnails(entries)
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

    // A frame costs a chafa run or a whole image, so one in which only the status bar changed, as
    // after a mark, rewrites just the bar, as cbzr keeps a page's image when its chrome changes.
    // shortcut: thumbnails that come in one at a time redraw the grid at most every 0.3 s
    private func setNeedsRedraw(image: Bool, after delay: Double = 0.01) {
        if image { imageDirty = true }
        let due = DispatchTime.now() + delay
        if let redrawDue, redrawDue <= due { return }
        redrawDue = due
        DispatchQueue.main.asyncAfter(deadline: due) { [self] in
            guard let redrawDue, redrawDue <= .now() else { return }
            self.redrawDue = nil
            render()
        }
    }

    // In synchronized output, the terminal shows the frame once it is whole, so the bar never
    // names an image that has yet to come; terminals without it ignore the mode.
    private func render() {
        var out = Array("\u{1b}[?2026h\u{1b}[H".utf8)
        if imageDirty {
            imageDirty = false
            // a frame that could not be drawn clears the screen, so no other image stays under this name
            if cols > 0, imageRows > 0 {
                let drawn = drawCanvas().flatMap { kitty ? Self.png(of: $0).map { kittyFrame($0) } : drawnRows($0) }
                if drawn == nil { shownImage = 0 }
                out += drawn ?? Array("\(kitty ? Self.deleteImages : "")\u{1b}[2J".utf8)
            } else if shownImage != 0 { // no row left for an image, as in a one-row terminal with the bar
                out += Array(Self.deleteImages.utf8)
                shownImage = 0
            }
        }
        if viewer.barVisible, rows > 0 { out += Array("\u{1b}[\(rows);1H\u{1b}[0;7m\(statusLine())\u{1b}[0m".utf8) }
        out += Array("\u{1b}[H\u{1b}[?2026l".utf8) // home, where a stray warning cannot scroll the screen
        Self.writeAll(tty, out)
    }

    // the view drawn into the canvas, at the terminal's own pixels for a kitty image, at 16 pixels
    // a row for chafa, which needs no more for its symbols
    private func drawCanvas() -> Imlib_Image? {
        let scale = kitty ? cell.height / 16 : 1
        let width = max(1, Int((canvasSize.width * scale).rounded()))
        let height = max(1, Int((canvasSize.height * scale).rounded()))
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
        guard let canvas else { return nil }
        renderer.render(into: canvas, width: width, height: height, scale: scale)
        return canvas
    }

    // The canvas as a PNG, written the way cbzr writes its pages: 8-bit RGB, each row with the Up
    // filter, zlib at its fastest level. libpng, which Imlib2 saves with, tries all five filters on
    // every row; for a 2560x1638 frame that took 306 ms against 116 ms here, for 3% less data.
    // shortcut: such a frame still takes about 0.25 s to draw and encode and 2.4 MB to send; draw
    // fewer pixels where the image is upscaled anyway, if larger terminals feel slow
    static func png(of image: Imlib_Image) -> Data? {
        imlib_context_set_image(image)
        let width = Int(imlib_image_get_width()), height = Int(imlib_image_get_height())
        guard let argb = imlib_image_get_data_for_reading_only() else { return nil }
        let stride = 1 + 3 * width
        var rows = [UInt8](repeating: 0, count: stride * height)
        var above = [UInt8](repeating: 0, count: 3 * width) // the row above, before its filter
        rows.withUnsafeMutableBufferPointer { rows in
            above.withUnsafeMutableBufferPointer { above in
                for y in 0..<height {
                    let row = rows.baseAddress! + y * stride, pixels = argb + y * width
                    row[0] = 2 // Up: each byte less the one above it
                    for x in 0..<width {
                        let p = pixels[x], i = 3 * x
                        let r = UInt8(truncatingIfNeeded: p >> 16), g = UInt8(truncatingIfNeeded: p >> 8)
                        let b = UInt8(truncatingIfNeeded: p)
                        row[1 + i] = r &- above[i]
                        row[2 + i] = g &- above[i + 1]
                        row[3 + i] = b &- above[i + 2]
                        above[i] = r
                        above[i + 1] = g
                        above[i + 2] = b
                    }
                }
            }
        }
        var size = compressBound(uLong(rows.count))
        var deflated = [UInt8](repeating: 0, count: Int(size))
        guard compress2(&deflated, &size, rows, uLong(rows.count), Z_BEST_SPEED) == Z_OK else { return nil }
        func bigEndian(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).bigEndian, Array.init) }
        var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        func chunk(_ type: String, _ body: ArraySlice<UInt8>) {
            let typed = Array(type.utf8) + body
            png.append(contentsOf: bigEndian(body.count))
            png.append(contentsOf: typed)
            png.append(contentsOf: bigEndian(Int(crc32(0, typed, uInt(typed.count)))))
        }
        chunk("IHDR", ArraySlice(bigEndian(width) + bigEndian(height) + [8, 2, 0, 0, 0])) // 8-bit RGB
        chunk("IDAT", deflated[..<Int(size)])
        chunk("IEND", [])
        return png
    }

    // the canvas as rows of colored symbols, one per cell, from chafa, which reads it from a file
    private func drawnRows(_ canvas: Imlib_Image) -> [UInt8]? {
        imlib_context_set_image(canvas)
        truncate(frame, 0) // a save that fails leaves chafa no older frame to draw
        imlib_save_image(frame)
        guard var drawn = Self.output(of: chafa + ["--size=\(cols)x\(imageRows)", frame]).map({ [UInt8]($0) })
        else { return nil }
        if drawn.last == 0x0a { drawn.removeLast() } // a newline after the bottom row would scroll the screen
        return drawn
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

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var done = 0
        while done < bytes.count {
            let n = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return } // the terminal went away
            done += n
        }
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
