#if os(Linux)
import CX11
import Foundation

// The viewer in a terminal, for a machine without a display, as over SSH: the renderer draws
// the view, chafa turns it into colored symbols for the terminal's cells, and the status bar
// takes the last line. Keys arrive as the bytes the terminal sends for them.
// shortcut: symbols only, which reach the screen through any multiplexer; the kitty graphics
// protocol would show every pixel, if viewing over plain SSH from such a terminal matters
final class TerminalUI: ViewerUI {
    private let viewer: Viewer
    private let renderer: ImlibRenderer
    private let tty: Int32
    private let chafa: [String] // the command, without the size and the file
    private let frame: String // the drawn view, as chafa reads it
    private var canvas: Imlib_Image?
    private var canvasSize = (width: 0, height: 0)
    private var cols = 80
    private var rows = 24
    private var cellWidth = 8 // canvas pixels across a cell, which is 16 pixels high
    private var redrawDue: DispatchTime?
    private var sources: [DispatchSourceProtocol] = []
    private var cutOff: [UInt8] = [] // an escape sequence the last read ended inside
    private var cutOffTimeout: DispatchWorkItem?

    // what atexit puts back
    private static var saved: (tty: Int32, mode: termios, frame: String)?

    // nil without a terminal, and without chafa, which it warns about
    init?(viewer: Viewer) {
        let tty = open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard tty >= 0 else { return nil }
        var mode = termios()
        guard tcgetattr(tty, &mode) == 0 else {
            close(tty)
            return nil
        }
        guard let about = Self.output(of: ["chafa", "--version"]) else {
            warn("showing images in a terminal needs chafa")
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
        // as in "Chafa version 1.18.3"
        let version = String(decoding: about, as: UTF8.self).split(whereSeparator: \.isWhitespace).dropFirst(2)
            .first?.split(separator: ".").compactMap { Int($0) } ?? []
        self.viewer = viewer
        self.tty = tty
        frame = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        // chafa 1.16 and later may probe the terminal, whose answers would then arrive as keys
        chafa = ["chafa", "--format=symbols", "--stretch", "--polite=on", "--relative=off", "--animate=off"]
            + (version.count > 1 && (version[0], version[1]) >= (1, 16) ? ["--probe=off"] : [])
        renderer = ImlibRenderer(viewer: viewer)
        renderer.drawsBar = false // the terminal's last line shows it
        Self.saved = (tty, mode, frame)
        atexit { TerminalUI.restoreTerminal() }
        Self.enter()

        renderer.onThumbnail = { [unowned self] in self.setNeedsRedraw(after: 0.3) }
        viewer.ui = self
        let input = DispatchSource.makeReadSource(fileDescriptor: tty, queue: .main)
        input.setEventHandler { [unowned self] in self.readKeys() }
        sources.append(input)
        signal(SIGWINCH, SIG_IGN)
        let resized = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resized.setEventHandler { [unowned self] in self.layoutChanged() }
        sources.append(resized)
        // a kill, or a closed terminal, ends the viewer as q does
        for stop in [SIGINT, SIGTERM, SIGHUP] {
            signal(stop, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: stop, queue: .main)
            source.setEventHandler { viewer.quit() }
            sources.append(source)
        }
        sources.forEach { $0.resume() }
    }

    func run() -> Never {
        viewer.start()
        dispatchMain()
    }

    // -o and Q print to the terminal once it is back
    func willQuit() { Self.restoreTerminal() }

    // the handler gets the terminal as the viewer found it, for its prompts and its output
    func keyHandlerWillRun() { Self.leave() }

    func keyHandlerDidRun() {
        Self.enter()
        setNeedsRedraw() // the alternate screen comes back empty
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
        writeAll(saved.tty, Array("\u{1b}[0m\u{1b}[?7h\u{1b}[?25h\u{1b}[?1049l".utf8))
        tcsetattr(saved.tty, TCSAFLUSH, &saved.mode)
    }

    private static func restoreTerminal() {
        guard let frame = Self.saved?.frame else { return }
        leave()
        unlink(frame)
        Self.saved = nil
    }

    // MARK: - keys

    private func readKeys() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = read(tty, &bytes, bytes.count)
        if n < 0, errno == EINTR || errno == EAGAIN { return }
        guard n > 0 else { viewer.quit() } // the terminal went away
        cutOffTimeout?.cancel()
        let parsed = Self.keys(in: cutOff + bytes[..<n])
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
        setNeedsRedraw()
    }

    func viewChanged() { setNeedsRedraw() }
    func gridChanged() { setNeedsRedraw() }
    func barChanged() { setNeedsRedraw() }
    func beep() { Self.writeAll(tty, [0x07]) }

    func layoutChanged() {
        var size = winsize()
        if ioctl(tty, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            cols = Int(size.ws_col)
            rows = Int(size.ws_row)
            // a cell's real shape where the terminal reports its pixels, else the usual 1:2
            if size.ws_xpixel > 0, size.ws_ypixel > 0 {
                let ratio = Double(size.ws_xpixel) / Double(cols) / (Double(size.ws_ypixel) / Double(rows))
                cellWidth = max(1, Int((16 * ratio).rounded()))
            }
        }
        let canvas = CGSize(width: cols * cellWidth, height: imageRows * 16)
        viewer.resizeCanvas(canvas)
        viewer.resizeGrid(canvas)
        setNeedsRedraw()
    }

    func invalidateThumbnails(_ entries: [FileEntry]) {
        renderer.invalidateThumbnails(entries)
        setNeedsRedraw()
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

    // shortcut: each frame costs a chafa run, so thumbnails that come in one at a time redraw
    // the grid at most every 0.3 s
    private func setNeedsRedraw(after delay: Double = 0.01) {
        let due = DispatchTime.now() + delay
        if let redrawDue, redrawDue <= due { return }
        redrawDue = due
        DispatchQueue.main.asyncAfter(deadline: due) { [self] in
            guard let redrawDue, redrawDue <= .now() else { return }
            self.redrawDue = nil
            render()
        }
    }

    private func render() {
        var out = Array("\u{1b}[H".utf8)
        // a frame chafa could not draw clears the screen, so no other image stays under this name
        if cols > 0, imageRows > 0 { out += drawnRows(cols: cols, rows: imageRows) ?? Array("\u{1b}[2J".utf8) }
        if viewer.barVisible, rows > 0 { out += Array("\u{1b}[\(rows);1H\u{1b}[0;7m\(statusLine())\u{1b}[0m".utf8) }
        out += Array("\u{1b}[H".utf8) // where a stray warning lands without scrolling the screen
        Self.writeAll(tty, out)
    }

    // the view as rows of colored symbols, one per cell, from chafa
    private func drawnRows(cols: Int, rows: Int) -> [UInt8]? {
        let width = cols * cellWidth, height = rows * 16
        if canvasSize.width != width || canvasSize.height != height {
            if let canvas {
                imlib_context_set_image(canvas)
                imlib_free_image()
            }
            canvas = imlib_create_image(Int32(width), Int32(height))
            canvasSize = (width, height)
            if let canvas {
                imlib_context_set_image(canvas)
                imlib_image_set_format("png")
                imlib_image_attach_data_value("compression", nil, 1, nil) // quick to write, read at once
            }
        }
        guard let canvas else { return nil }
        renderer.render(into: canvas, width: width, height: height, scale: 1)
        imlib_context_set_image(canvas)
        truncate(frame, 0) // a save that fails leaves chafa no older frame to draw
        imlib_save_image(frame)
        guard var drawn = Self.output(of: chafa + ["--size=\(cols)x\(rows)", frame]).map({ [UInt8]($0) })
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
