#if os(Linux)
import CX11
import Foundation

// The viewer in a terminal, for a machine without a display, as over SSH: the renderer draws
// the view, and the status bar takes the last line. A terminal with the kitty graphics protocol,
// as kitty, Ghostty, WezTerm or a herdr pane in one of them, gets the view as an image at its
// own pixels; any other gets it from chafa as colored symbols, one per cell. Keys arrive as the
// bytes the terminal sends for them.
//
// A kitty terminal keeps the images it gets, and shows one again for a command of a few dozen
// bytes: the frames of the last views stay there, and while the viewer waits for a key it
// sends the next and the previous image ahead, so moving to them, or back to an earlier view,
// takes microseconds. A terminal on the same machine reads each new frame as raw pixels from a
// file in /tmp, a RAM disk on most systems; a remote one gets it as PNG through the terminal.
final class TerminalUI: ViewerUI {
    private let viewer: Viewer
    private let renderer: ImlibRenderer
    private let tty: Int32
    private let kitty: Bool
    private let imageFiles: String? // the directory of frames the terminal reads itself
    private let chafa: [String] // the command, without the size and the file
    private let frame: String // the drawn view as a PNG file, for chafa
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
    private var shownImage: UInt32 = 0 // the kitty image on screen; 0 when other programs may have left some
    private var shownKey: FrameKey?
    private var lastImageID: UInt32 = 0
    private var lastIndex = 0 // of the image shown, for the way the viewer is going
    private var direction = 1
    private var prefetch: DispatchWorkItem?
    private var symbols: [FrameKey: [UInt8]] = [:] // chafa's last frames
    private var redrawDue: DispatchTime?
    private var sources: [DispatchSourceProtocol] = []
    private var cutOff: [UInt8] = [] // an escape sequence the last read ended inside
    private var cutOffTimeout: DispatchWorkItem?
    private let probeInput: [UInt8] // the probe's answers, which the key parser skips, and keys typed meanwhile

    // what atexit puts back
    private static var saved: (tty: Int32, mode: termios, frame: String, kitty: Bool, imageFiles: String?)?

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
        let probe = Self.probeKittyGraphics(tty, files: imageFiles)
        let kitty = probe.kitty
        Self.saved?.kitty = kitty
        if !probe.files, let imageFiles {
            try? FileManager.default.removeItem(atPath: imageFiles)
            Self.saved?.imageFiles = nil
        }
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
        self.imageFiles = probe.files ? imageFiles : nil
        self.chafa = chafa
        self.frame = frame
        probeInput = probe.input
        lastImageID = UInt32(getpid() & 0xffff) << 8 // unlike another viewer's in the same terminal
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

    // -o and Q print to the terminal once it is back, without the frames it kept
    func willQuit() {
        Self.writeAll(tty, Array(kept.values.map { Self.delete($0.id) }.joined().utf8))
        Self.restoreTerminal()
    }

    // the handler gets the terminal as the viewer found it, for its prompts and its output
    func keyHandlerWillRun() {
        Self.writeAll(tty, Array(kept.values.map { Self.delete($0.id) }.joined().utf8))
        Self.leave()
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
        if let imageFiles = saved.imageFiles { try? FileManager.default.removeItem(atPath: imageFiles) }
        Self.saved = nil
    }

    // MARK: - kitty graphics

    // every image on screen, quietly
    private static let deleteImages = "\u{1b}_Ga=d,d=A,q=2\u{1b}\\"

    // A terminal with kitty graphics answers a query for a one-pixel image with OK, before the
    // device attributes any terminal reports; one that never answers gets symbols after a second.
    // A second query, for the pixel in a file, tells whether the terminal reads the viewer's files.
    // Everything read meanwhile comes back too, for the keys typed during the probe.
    private static func probeKittyGraphics(_ tty: Int32, files: String?) -> (kitty: Bool, files: Bool, input: [UInt8]) {
        var query = "\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\"
        if let files, FileManager.default.createFile(atPath: files + "/probe", contents: Data([0, 0, 0])) {
            query += "\u{1b}_Gi=32,s=1,v=1,a=q,t=t,f=24;\(Data((files + "/probe").utf8).base64EncodedString())\u{1b}\\"
        }
        writeAll(tty, Array((query + "\u{1b}[c").utf8))
        var reply: [UInt8] = []
        let deadline = Date().addingTimeInterval(1)
        while deadline.timeIntervalSinceNow > 0 {
            var ready = pollfd(fd: tty, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            var bytes = [UInt8](repeating: 0, count: 256)
            let n = read(tty, &bytes, bytes.count)
            guard n > 0 else { break }
            reply += bytes[..<n]
            if let answer = kittyGraphics(in: reply) { return (answer.kitty, answer.files, reply) }
        }
        return (false, false, reply)
    }

    // what the replies to those queries say; nil until the device attributes end them
    static func kittyGraphics(in reply: [UInt8]) -> (kitty: Bool, files: Bool)? {
        let text = String(decoding: reply, as: UTF8.self)
        guard let attributes = text.range(of: "\u{1b}[?"), text[attributes.upperBound...].contains("c") else { return nil }
        let answers = text[..<attributes.lowerBound]
        return (answers.contains("\u{1b}_Gi=31;OK"), answers.contains("\u{1b}_Gi=32;OK"))
    }

    // the kitty images that a reply says are gone, as when the terminal needed their room
    static func missingImages(in bytes: [UInt8]) -> [UInt32] {
        String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1b}_Gi=").dropFirst().compactMap { reply in
            guard let end = reply.range(of: "\u{1b}\\"), !reply[..<end.lowerBound].hasSuffix(";OK") else { return nil }
            return UInt32(reply.prefix { $0.isNumber })
        }
    }

    // a PNG as a kitty image, in the protocol's chunks of at most 4096 bytes of base64; the
    // keys go on the first. q=2 keeps the terminal's answers from arriving as keys.
    static func kittyImage(_ png: Data, keys: String) -> [UInt8] {
        let payload = [UInt8](png.base64EncodedData())
        var out: [UInt8] = []
        var start = 0
        repeat {
            let end = min(start + 4096, payload.count)
            let more = end < payload.count ? 1 : 0
            let chunkKeys = start == 0 ? "\(keys),f=100,t=d,q=2,m=\(more)" : "m=\(more),q=2"
            out += Array("\u{1b}_G\(chunkKeys);".utf8) + payload[start..<end] + Array("\u{1b}\\".utf8)
            start = end
        } while start < payload.count
        return out
    }

    // The canvas sent to the terminal as image id: as raw RGB in a file the terminal reads and
    // deletes itself, or as PNG through the terminal. With place, it also shows at the top left,
    // scaled to the image rows, as placement 1.
    private func transmit(_ canvas: Imlib_Image, id: UInt32, place: Bool) -> [UInt8]? {
        let keys = place ? "a=T,i=\(id),p=1,C=1,c=\(cols),r=\(imageRows)" : "a=t,i=\(id)"
        guard let imageFiles else { return Self.png(of: canvas).map { Self.kittyImage($0, keys: keys) } }
        imlib_context_set_image(canvas)
        let width = Int(imlib_image_get_width()), height = Int(imlib_image_get_height())
        guard let argb = imlib_image_get_data_for_reading_only() else { return nil }
        let rgb = [UInt8](unsafeUninitializedCapacity: 3 * width * height) { rgb, count in
            for i in 0..<width * height {
                let p = argb[i]
                rgb[3 * i] = UInt8(truncatingIfNeeded: p >> 16)
                rgb[3 * i + 1] = UInt8(truncatingIfNeeded: p >> 8)
                rgb[3 * i + 2] = UInt8(truncatingIfNeeded: p)
            }
            count = 3 * width * height
        }
        let path = "\(imageFiles)/\(id)"
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        Self.writeAll(fd, rgb)
        close(fd)
        return Array("\u{1b}_G\(keys),f=24,s=\(width),v=\(height),t=t,q=2;\(Data(path.utf8).base64EncodedString())\u{1b}\\".utf8)
    }

    private static func delete(_ id: UInt32) -> String { "\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\" }

    // An id no kept frame uses, below 2^24, as tmux's placeholders carry ids in a 24-bit color
    private func newImageID() -> UInt32 {
        let used = Set(kept.values.map(\.id))
        repeat {
            lastImageID = lastImageID % 0xff_ffff + 1
        } while used.contains(lastImageID) || lastImageID == shownImage
        return lastImageID
    }

    // The terminal holds what the frames the viewer kept take as RGBA: herdr keeps 64 MiB a pane.
    // A kept frame shows again by placement alone; the one it replaces loses its placement only.
    private static let keptBudget = 56 << 20

    private func keep(_ key: FrameKey, id: UInt32, bytes: Int) -> [UInt8] {
        kept[key] = (id, bytes)
        keptOrder.removeAll { $0 == key }
        keptOrder.append(key)
        var out = ""
        var total = kept.values.reduce(0) { $0 + $1.bytes }
        while total > Self.keptBudget, let oldest = keptOrder.first(where: { $0 != key && $0 != shownKey }),
              let frame = kept.removeValue(forKey: oldest) {
            keptOrder.removeAll { $0 == oldest }
            total -= frame.bytes
            out += Self.delete(frame.id)
        }
        return Array(out.utf8)
    }

    // The view, from a kept frame or a new one, in place of what the screen shows: what is there
    // loses its placement once the new frame covers it, or goes entirely when it was not kept
    private func kittyFrame(_ key: FrameKey?) -> [UInt8]? {
        var out = Array((shownImage == 0 ? Self.deleteImages : "").utf8) // what other programs left
        let id: UInt32
        if let key, let frame = kept[key] {
            id = frame.id
            keptOrder.removeAll { $0 == key }
            keptOrder.append(key)
            // q=1 leaves an answer when the terminal dropped the image, so it goes again
            out += Array("\u{1b}_Ga=p,i=\(id),p=1,C=1,q=1,c=\(cols),r=\(imageRows)\u{1b}\\".utf8)
        } else {
            id = newImageID()
            guard let canvas = drawCanvas(), let sent = transmit(canvas, id: id, place: true) else { return nil }
            out += sent
            if let key { out += keep(key, id: id, bytes: 4 * canvasPixels.width * canvasPixels.height) }
        }
        if shownImage != 0, shownImage != id {
            let keptShown = kept.values.contains { $0.id == shownImage }
            out += Array((keptShown ? "\u{1b}_Ga=d,d=i,i=\(shownImage),p=1,q=2\u{1b}\\" : Self.delete(shownImage)).utf8)
        }
        shownImage = id
        shownKey = key
        return out
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
    // first view, each in a turn of the main queue of its own, unless a key is waiting by then.
    // shortcut: Imlib2 decodes on the main queue, so a key that comes during a prefetch waits
    // for it, and images over 25 megapixels are left out; a second process would decode alongside
    private func schedulePrefetch() {
        prefetch?.cancel()
        guard kitty, !viewer.thumbnailMode else { return }
        let work = DispatchWorkItem { [unowned self] in self.prefetchNeighbor() }
        prefetch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func prefetchNeighbor() {
        var ready = pollfd(fd: tty, events: Int16(POLLIN), revents: 0)
        guard !imageDirty, poll(&ready, 1, 0) == 0 else { return } // a key or a frame comes first
        for index in [viewer.current + direction, viewer.current - direction] where viewer.files.indices.contains(index) {
            let entry = viewer.files[index]
            guard !kept.keys.contains(where: { $0.path == entry.path }), let next = renderer.peek(entry.url) else { continue }
            defer { renderer.release(next.image) }
            guard next.size.width * next.size.height <= 25_000_000 else { continue }
            var view = viewer.viewport
            view.setImageSize(next.size, resetView: true) // as loading it will
            let pixels = framePixels(view, image: true)
            let shownBytes = kept.values.first { $0.id == shownImage }?.bytes ?? 0
            guard shownBytes + 4 * pixels.width * pixels.height <= Self.keptBudget else { return }
            let key = key(path: entry.path, frame: 0, rotation: 0, flipH: false, flipV: false, view: view, pixels: pixels)
            guard let canvas = makeCanvas(pixels.width, pixels.height) else { return }
            renderer.drawStill(next.image, view: view, into: canvas, width: pixels.width, height: pixels.height,
                               scale: pixels.scale)
            let id = newImageID()
            guard let sent = transmit(canvas, id: id, place: false) else { return }
            Self.writeAll(tty, sent + keep(key, id: id, bytes: 4 * pixels.width * pixels.height))
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
        var out = ""
        for (key, frame) in kept where stale(key) {
            kept[key] = nil
            keptOrder.removeAll { $0 == key }
            if frame.id != shownImage { out += Self.delete(frame.id) } // the shown one goes once replaced
        }
        symbols = symbols.filter { !stale($0.key) }
        if !out.isEmpty { Self.writeAll(tty, Array(out.utf8)) }
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
        CGSize(width: Double(cols) * 16 * cell.width / cell.height, height: Double(imageRows) * 16)
    }

    func invalidateThumbnails(_ entries: [FileEntry]) {
        renderer.invalidateThumbnails(entries)
        let paths = Set(entries.map(\.path))
        forgetFrames { paths.contains($0.path) }
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
        if imageDirty {
            imageDirty = false
            // a frame that could not be drawn clears the screen, so no other image stays under this name
            if cols > 0, imageRows > 0 {
                let drawn = kitty ? kittyFrame(currentKey()) : symbolRows(currentKey())
                if drawn == nil { // the next redraw, even of the bar alone, tries again
                    shownImage = 0
                    shownKey = nil
                    imageDirty = true
                }
                out += drawn ?? Array("\(kitty ? Self.deleteImages : "")\u{1b}[2J".utf8)
            } else if shownImage != 0 { // no row left for an image, as in a one-row terminal with the bar
                out += Array(Self.deleteImages.utf8)
                shownImage = 0
                shownKey = nil
            }
        }
        if viewer.barVisible, rows > 0 { out += Array("\u{1b}[\(rows);1H\u{1b}[0;7m\(statusLine())\u{1b}[0m".utf8) }
        out += Array("\u{1b}[H\u{1b}[?2026l".utf8) // home, where a stray warning cannot scroll the screen
        Self.writeAll(tty, out)
        if !imageDirty { schedulePrefetch() }
    }

    // The pixels a frame of view takes: the terminal's own for a kitty image, 16 a row for chafa,
    // which needs no more for its symbols. A kitty terminal scales an image up as Imlib2 does,
    // linearly, so an image shown larger than its pixels goes at those, which it scales itself.
    private func framePixels(_ view: Viewport, image: Bool) -> (width: Int, height: Int, scale: Double) {
        var scale = kitty ? cell.height / 16 : 1
        if kitty, image, view.antialias, view.zoom * scale > 1 { scale = 1 / view.zoom }
        return (max(1, Int((canvasSize.width * scale).rounded())), max(1, Int((canvasSize.height * scale).rounded())),
                scale)
    }

    // the current view drawn into the canvas
    private func drawCanvas() -> Imlib_Image? {
        let pixels = framePixels(viewer.viewport, image: !viewer.thumbnailMode && viewer.image != nil)
        guard let canvas = makeCanvas(pixels.width, pixels.height) else { return nil }
        renderer.render(into: canvas, width: pixels.width, height: pixels.height, scale: pixels.scale)
        return canvas
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

    // The canvas as a PNG: 8-bit RGB, each row with the Up filter, zlib at its fastest level by
    // default. libpng, which Imlib2 saves with, tries all five filters on every row; for a
    // 2560x1638 frame that took 306 ms against 116 ms here, for 3% less data.
    static func png(of image: Imlib_Image, level: Int32 = Z_BEST_SPEED) -> Data? {
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
        guard compress2(&deflated, &size, rows, uLong(rows.count), level) == Z_OK else { return nil }
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

    // The view as rows of colored symbols, one per cell, from chafa, which reads the canvas from an
    // uncompressed PNG file, the quickest to write and read. The last views' rows stay for a return.
    private func symbolRows(_ key: FrameKey?) -> [UInt8]? {
        if let key, let rows = symbols[key] { return rows }
        guard let canvas = drawCanvas(), let png = Self.png(of: canvas, level: Z_NO_COMPRESSION),
              FileManager.default.createFile(atPath: frame, contents: png),
              var drawn = Self.output(of: chafa + ["--size=\(cols)x\(imageRows)", frame]).map({ [UInt8]($0) })
        else { return nil }
        if drawn.last == 0x0a { drawn.removeLast() } // a newline after the bottom row would scroll the screen
        if let key {
            if symbols.count >= 8 { symbols = [:] }
            symbols[key] = drawn
        }
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
