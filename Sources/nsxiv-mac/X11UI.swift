#if os(Linux)
import CX11
import Foundation

// The X11 side of the viewer, drawn with Imlib2 and Xft as in nsxiv.
final class X11UI: ViewerUI {
    private let viewer: Viewer
    private let dpy: OpaquePointer
    private let screen: Int32
    private let visual: UnsafeMutablePointer<Visual>
    private let colormap: Colormap
    private let depth: Int32
    private let win: Window
    private let gc: GC
    private let font: UnsafeMutablePointer<XftFont>?
    private let barHeight: Int
    private let wmDelete, wmState, wmFullscreen, wmName, utf8String, atomType: Atom

    private let background: XColor
    private let barBackground, selection, mark: UInt
    private var textColor = XftColor()

    private var width: Int
    private var height: Int
    private var buffer: Pixmap = 0
    private var bufferSize = (width: 0, height: 0)
    private var textDraw: OpaquePointer?
    private var title = ""
    private var mapped = false
    private var fullscreen = false
    private var redrawPending = false
    private var events: DispatchSourceRead?

    // the open file: its composed frames, and the current one rotated and flipped
    private var frames: [Imlib_Image] = []
    private var shown: Imlib_Image?
    private let colorModifier: Imlib_Color_Modifier

    private var thumbs: [String: Imlib_Image] = [:]
    private var failedThumbs: Set<String> = []
    private var thumbnailPending = false

    private var pointer = CGPoint.zero
    private var dragging = false
    private var dragged = false
    private var lastClick: (time: Time, index: Int)?

    init(viewer: Viewer) {
        guard let dpy = XOpenDisplay(nil) else {
            warn("cannot open display \(ProcessInfo.processInfo.environment["DISPLAY"] ?? "(DISPLAY unset)")")
            exit(1)
        }
        let screen = XDefaultScreen(dpy)
        let visual: UnsafeMutablePointer<Visual> = XDefaultVisual(dpy, screen)
        let colormap = XDefaultColormap(dpy, screen)
        let depth = XDefaultDepth(dpy, screen)
        self.viewer = viewer
        self.dpy = dpy
        self.screen = screen
        self.visual = visual
        self.colormap = colormap
        self.depth = depth

        let background = Self.color(Config.background, dpy, colormap)
        self.background = background
        barBackground = Self.color(Config.barBackground, dpy, colormap).pixel
        selection = Self.color(Config.selectionColor, dpy, colormap).pixel
        mark = Self.color(Config.markColor, dpy, colormap).pixel

        let size = viewer.options.geometry ?? CGSize(width: Config.winWidth, height: Config.winHeight)
        width = Int(size.width)
        height = Int(size.height)
        var attrs = XSetWindowAttributes()
        attrs.colormap = colormap
        attrs.border_pixel = 0
        attrs.background_pixel = background.pixel
        attrs.event_mask = KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask
            | PointerMotionMask | StructureNotifyMask | ExposureMask | PropertyChangeMask
        let win = XCreateWindow(dpy, XRootWindow(dpy, screen), 0, 0, UInt32(size.width), UInt32(size.height), 0,
                                depth, UInt32(InputOutput), visual,
                                UInt(CWColormap | CWBorderPixel | CWBackPixel | CWEventMask), &attrs)
        self.win = win
        let gc: GC = XCreateGC(dpy, win, 0, nil)
        self.gc = gc
        XSetLineAttributes(dpy, gc, 3, LineSolid, CapButt, JoinMiter)

        var protocols = XInternAtom(dpy, "WM_DELETE_WINDOW", 0)
        wmDelete = protocols
        wmState = XInternAtom(dpy, "_NET_WM_STATE", 0)
        wmFullscreen = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", 0)
        wmName = XInternAtom(dpy, "_NET_WM_NAME", 0)
        utf8String = XInternAtom(dpy, "UTF8_STRING", 0)
        atomType = XInternAtom(dpy, "ATOM", 0)
        XSetWMProtocols(dpy, win, &protocols, 1)
        var hint = XClassHint(res_name: strdup(Config.appName), res_class: strdup(Config.appName))
        XSetClassHint(dpy, win, &hint)
        // auto-repeat then sends presses alone, and the release comes when the key does
        // shortcut: a server without it sends a release before each repeat, so dropRepeats
        // keeps them all; X.org, Xvfb and XWayland have it
        var detectable: Int32 = 0
        XkbSetDetectableAutoRepeat(dpy, 1, &detectable)

        let font: UnsafeMutablePointer<XftFont>? = XftFontOpenName(dpy, screen, Config.barFont)
        if font == nil { warn("cannot load font \(Config.barFont)") }
        self.font = font
        barHeight = font.map { Int($0.pointee.ascent + $0.pointee.descent) + 8 } ?? 0

        imlib_context_set_display(dpy)
        imlib_context_set_visual(visual)
        imlib_context_set_colormap(colormap)
        colorModifier = imlib_create_color_modifier()

        if XftColorAllocName(dpy, visual, colormap, Config.foreground, &textColor) == 0 {
            warn("cannot allocate color \(Config.foreground)")
        }
        viewer.ui = self
    }

    private struct RepeatScan {
        let keycode: UInt32
        var released = false
    }

    private static func color(_ name: String, _ dpy: OpaquePointer, _ colormap: Colormap) -> XColor {
        var color = XColor(), exact = XColor()
        if XAllocNamedColor(dpy, colormap, name, &color, &exact) == 0 {
            warn("cannot allocate color \(name)")
        }
        return color
    }

    func run() -> Never {
        viewer.start()
        XMapWindow(dpy, win)
        mapped = true
        let source = DispatchSource.makeReadSource(fileDescriptor: XConnectionNumber(dpy), queue: .main)
        source.setEventHandler { [unowned self] in self.drainEvents() }
        source.resume()
        events = source
        XFlush(dpy)
        dispatchMain()
    }

    // MARK: - events

    private func drainEvents() {
        var ev = XEvent()
        while XPending(dpy) > 0 {
            XNextEvent(dpy, &ev)
            switch ev.type {
            case KeyPress:
                keyPressed(&ev.xkey)
                dropRepeats(of: ev.xkey.keycode)
            case ButtonPress: buttonPressed(ev.xbutton)
            case ButtonRelease: buttonReleased(ev.xbutton)
            case MotionNotify:
                // only the latest position matters, up to the next event of another kind
                var next = XEvent()
                while XEventsQueued(dpy, QueuedAlready) > 0 {
                    XPeekEvent(dpy, &next)
                    guard next.type == MotionNotify else { break }
                    XNextEvent(dpy, &ev)
                }
                pointerMoved(to: CGPoint(x: Int(ev.xmotion.x), y: Int(ev.xmotion.y)))
            case ConfigureNotify: resized(Int(ev.xconfigure.width), Int(ev.xconfigure.height))
            case Expose: if ev.xexpose.count == 0 { setNeedsRedraw() }
            case PropertyNotify: if ev.xproperty.atom == wmState { fullscreenChanged() }
            case ClientMessage: if UInt(bitPattern: ev.xclient.data.l.0) == wmDelete { viewer.quit() }
            default: break
            }
        }
    }

    private func keyPressed(_ key: inout XKeyEvent) {
        var sym: KeySym = 0
        var text = [CChar](repeating: 0, count: 8)
        XLookupString(&key, &text, Int32(text.count), &sym, nil)
        guard let name = Self.keyName(sym) else { return }
        _ = viewer.handle(Keystroke(key: name, ctrl: key.state & UInt32(ControlMask) != 0))
    }

    // A held key outruns large decodes. The presses of that key queued while the last one
    // was handled go, past other events but not past the key's release, so taps still count.
    private func dropRepeats(of keycode: UInt32) {
        var scan = RepeatScan(keycode: keycode)
        var dropped = XEvent()
        while withUnsafeMutablePointer(to: &scan, { scan in
            XCheckIfEvent(dpy, &dropped, { _, event, arg in
                guard let e = event?.pointee, let arg, e.type == KeyPress || e.type == KeyRelease else { return 0 }
                let scan = UnsafeMutableRawPointer(arg).assumingMemoryBound(to: RepeatScan.self)
                guard e.xkey.keycode == scan.pointee.keycode, !scan.pointee.released else { return 0 }
                if e.type == KeyRelease { scan.pointee.released = true }
                return e.type == KeyPress ? 1 : 0
            }, UnsafeMutableRawPointer(scan).assumingMemoryBound(to: CChar.self))
        }) != 0 {}
    }

    // printable ASCII as typed, other keys by their keysym name; a modifier alone is no key
    static func keyName(_ sym: KeySym) -> String? {
        switch sym {
        case 0x20...0x7e: return String(UnicodeScalar(UInt8(sym)))
        case KeySym(XK_Shift_L)...KeySym(XK_Hyper_R), KeySym(XK_Mode_switch), KeySym(XK_Num_Lock),
             KeySym(XK_ISO_Level3_Shift), KeySym(NoSymbol): return nil
        default: return XKeysymToString(sym).map { String(cString: $0) }
        }
    }

    private func buttonPressed(_ b: XButtonEvent) {
        let p = CGPoint(x: Int(b.x), y: Int(b.y))
        let inCanvas = Int(b.y) < canvasHeight
        switch Int32(b.button) {
        case Button1 where !viewer.thumbnailMode:
            pointer = p
            dragging = true
            dragged = false
        case Button1:
            // no drag starts here, so the release after a double click cannot navigate
            guard inCanvas, let i = viewer.grid.index(at: p) else { return }
            if let last = lastClick, last.index == i, b.time &- last.time < 400 {
                lastClick = nil
                viewer.open(i)
            } else {
                lastClick = (b.time, i)
                viewer.select(i)
            }
        case Button3:
            if !viewer.thumbnailMode {
                viewer.switchMode()
            } else if inCanvas, let i = viewer.grid.index(at: p) {
                viewer.toggleMark(at: i) // marks without moving the selection, like nsxiv
            }
        case Button4, Button5:
            let dir = Int32(b.button) == Button4 ? 1 : -1
            if viewer.thumbnailMode {
                viewer.scrollGrid(by: -CGFloat(dir) * viewer.grid.cellSize / 3)
            } else {
                viewer.zoomStep(dir) // the wheel zooms, as with a mouse on macOS
            }
        default: break
        }
    }

    private func buttonReleased(_ b: XButtonEvent) {
        guard Int32(b.button) == Button1, dragging else { return }
        dragging = false
        guard !viewer.thumbnailMode, !dragged, Int(b.y) < canvasHeight else { return }
        let navW = CGFloat(width) * Config.navWidthFraction
        if CGFloat(b.x) < navW {
            viewer.navigate(-1)
        } else if CGFloat(b.x) > CGFloat(width) - navW {
            viewer.navigate(1)
        }
    }

    private func pointerMoved(to p: CGPoint) {
        defer { pointer = p }
        guard dragging, !viewer.thumbnailMode else { return }
        dragged = true
        // X counts y downward, the viewport upward
        viewer.pan(dx: p.x - pointer.x, dy: pointer.y - p.y)
    }

    private func resized(_ w: Int, _ h: Int) {
        guard w != width || h != height else { return }
        width = w
        height = h
        layoutChanged()
    }

    private var canvasHeight: Int { max(0, height - (viewer.barVisible ? barHeight : 0)) }

    // MARK: - ViewerUI

    func loadImage(_ url: URL) -> ImageInfo? {
        freeImage()
        guard let first = imlib_load_image_frame(url.path, 1) else { return nil }
        imlib_context_set_image(first)
        var info = Imlib_Frame_Info()
        imlib_image_get_frame_info(&info)
        var delays = [0.1]
        if info.frame_count > 1, info.frame_flags & IMLIB_IMAGE_ANIMATED != 0,
           let animation = Self.compose(url.path, info) {
            imlib_context_set_image(first)
            imlib_free_image_and_decache()
            frames = animation.frames
            delays = animation.delays
        } else {
            frames = [first]
        }
        imlib_context_set_image(frames[0])
        let size = CGSize(width: Int(imlib_image_get_width()), height: Int(imlib_image_get_height()))
        return ImageInfo(size: size, delays: delays)
    }

    func imageChanged() {
        if let shown, !frames.contains(shown) {
            imlib_context_set_image(shown)
            imlib_free_image()
        }
        shown = nil
        if viewer.image != nil, frames.indices.contains(viewer.frameIndex) {
            let frame = frames[viewer.frameIndex]
            if viewer.rotation == 0, !viewer.flipH, !viewer.flipV {
                shown = frame
            } else {
                imlib_context_set_image(frame)
                if let copy = imlib_clone_image() {
                    imlib_context_set_image(copy)
                    // turn first, then flip what is on screen, as the macOS side does
                    imlib_image_orientate(Int32(viewer.rotation / 90))
                    if viewer.flipH { imlib_image_flip_horizontal() }
                    if viewer.flipV { imlib_image_flip_vertical() }
                    shown = copy
                }
            }
        }
        imlib_context_set_color_modifier(colorModifier)
        imlib_reset_color_modifier()
        if viewer.gamma != 0 { imlib_modify_color_modifier_gamma(viewer.gammaValue) }
        if viewer.contrast != 0 { imlib_modify_color_modifier_contrast(viewer.contrastValue) }
        if let name = viewer.currentEntry?.url.lastPathComponent, name != title {
            title = name
            let bytes = Array(name.utf8)
            XChangeProperty(dpy, win, wmName, utf8String, 8, PropModeReplace, bytes, Int32(bytes.count))
            XStoreName(dpy, win, name) // for window managers without EWMH
        }
        setNeedsRedraw()
    }

    func viewChanged() { setNeedsRedraw() }
    func gridChanged() { setNeedsRedraw() }
    func barChanged() { setNeedsRedraw() }
    func beep() { XBell(dpy, 0) }

    func layoutChanged() {
        let size = CGSize(width: width, height: canvasHeight)
        viewer.resizeCanvas(size)
        viewer.resizeGrid(size)
        setNeedsRedraw()
    }

    func invalidateThumbnails(_ entries: [FileEntry]) {
        for entry in entries {
            failedThumbs.remove(entry.path)
            if let thumb = thumbs.removeValue(forKey: entry.path) {
                imlib_context_set_image(thumb)
                imlib_free_image()
            }
        }
        setNeedsRedraw()
    }

    func fitWindow() {
        guard !fullscreen, let size = viewer.fittedSize, size.width > 0, size.height > 0 else { return }
        let barH = CGFloat(viewer.barVisible ? barHeight : 0)
        // shortcut: caps at the whole X screen, which spans every monitor; ask XRandR for
        // the window's monitor when large images open across two screens
        let screenW = CGFloat(XDisplayWidth(dpy, screen)), screenH = CGFloat(XDisplayHeight(dpy, screen))
        let scale = min(1, screenW / size.width, (screenH - barH) / size.height)
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        setSizeHints(aspect: (w, h))
        XResizeWindow(dpy, win, UInt32(w), UInt32(h + Int(barH)))
    }

    func resetWindowSize() {
        setSizeHints(aspect: nil) // the grid resizes freely
        guard !fullscreen, viewer.options.geometry == nil else { return }
        XResizeWindow(dpy, win, UInt32(Config.winWidth), UInt32(Config.winHeight))
    }

    // the window manager keeps the image's aspect while the user resizes, as mpv does
    private func setSizeHints(aspect: (Int, Int)?) {
        var hints = XSizeHints()
        if let aspect {
            hints.flags = PAspect | PBaseSize
            hints.min_aspect.x = Int32(aspect.0)
            hints.min_aspect.y = Int32(aspect.1)
            hints.max_aspect = hints.min_aspect
            hints.base_height = Int32(viewer.barVisible ? barHeight : 0)
        }
        XSetWMNormalHints(dpy, win, &hints)
    }

    func toggleFullscreen() {
        guard mapped else {
            // an unmapped window states it; the window manager reads that when it maps it
            var state = wmFullscreen
            withUnsafeBytes(of: &state) {
                _ = XChangeProperty(dpy, win, wmState, atomType, 32, PropModeReplace,
                                    $0.bindMemory(to: UInt8.self).baseAddress, 1)
            }
            return
        }
        // the window manager answers with a property change, see fullscreenChanged
        var ev = XEvent()
        ev.xclient.type = ClientMessage
        ev.xclient.window = win
        ev.xclient.message_type = wmState
        ev.xclient.format = 32
        ev.xclient.data.l.0 = 2 // _NET_WM_STATE_TOGGLE
        ev.xclient.data.l.1 = Int(bitPattern: wmFullscreen)
        XSendEvent(dpy, XRootWindow(dpy, screen), 0, SubstructureNotifyMask | SubstructureRedirectMask, &ev)
    }

    // follows the window manager's state, which its own fullscreen shortcut changes too
    private func fullscreenChanged() {
        var type: Atom = 0
        var format: Int32 = 0
        var count: UInt = 0, after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        guard XGetWindowProperty(dpy, win, wmState, 0, 64, 0, atomType, &type, &format, &count, &after,
                                 &data) == Success else { return }
        defer { if let data { XFree(data) } }
        // format 32 items arrive as C longs
        let now = data.map { bytes in
            bytes.withMemoryRebound(to: Atom.self, capacity: Int(count)) { atoms in
                (0..<Int(count)).contains { atoms[$0] == wmFullscreen }
            }
        } ?? false
        guard now != fullscreen else { return }
        fullscreen = now
        if !fullscreen { fitWindow() }
    }

    func enterEditMode() -> Bool {
        warn("edit mode needs macOS: it draws with Core Graphics and reads text with Vision")
        return false
    }

    // MARK: - images

    private func freeImage() {
        if let shown, !frames.contains(shown) {
            imlib_context_set_image(shown)
            imlib_free_image()
        }
        shown = nil
        for frame in frames {
            imlib_context_set_image(frame)
            imlib_free_image_and_decache() // a reload must read the file again
        }
        frames = []
    }

    // Imlib2 hands out raw frames; each one is drawn over what the previous one left
    private static func compose(_ path: String, _ first: Imlib_Frame_Info)
        -> (frames: [Imlib_Image], delays: [TimeInterval])? {
        let w = first.canvas_w, h = first.canvas_h
        guard w > 0, h > 0, let blank = imlib_create_image(w, h) else { return nil }
        imlib_context_set_image(blank)
        clear(0, 0, w, h)
        imlib_context_set_anti_alias(0)
        imlib_context_set_color_modifier(nil)
        imlib_context_set_operation(IMLIB_OP_COPY)
        var frames: [Imlib_Image] = []
        var delays: [TimeInterval] = []
        var previous = Imlib_Frame_Info() // the last frame's disposal and area
        var undo: Imlib_Image? // the canvas before the last frame, kept when that frame asks to be undone
        for n in 1...first.frame_count {
            guard let raw = imlib_load_image_frame(path, n) else { break }
            imlib_context_set_image(raw)
            var info = Imlib_Frame_Info()
            imlib_image_get_frame_info(&info)
            let fw = info.frame_w > 0 ? info.frame_w : imlib_image_get_width()
            let fh = info.frame_h > 0 ? info.frame_h : imlib_image_get_height()
            // start from the canvas the previous frame asked to leave
            let undone = previous.frame_flags & IMLIB_FRAME_DISPOSE_PREV != 0
            imlib_context_set_image(undone ? undo ?? blank : frames.last ?? blank)
            let canvas = imlib_clone_image()
            if let old = undo {
                imlib_context_set_image(old)
                imlib_free_image()
                undo = nil
            }
            guard let canvas else {
                imlib_context_set_image(raw)
                imlib_free_image_and_decache()
                break
            }
            imlib_context_set_image(canvas)
            if previous.frame_flags & IMLIB_FRAME_DISPOSE_CLEAR != 0 {
                clear(previous.frame_x, previous.frame_y, previous.frame_w, previous.frame_h)
            }
            if info.frame_flags & IMLIB_FRAME_DISPOSE_PREV != 0 { undo = imlib_clone_image() }
            imlib_context_set_blend(info.frame_flags & IMLIB_FRAME_BLEND != 0 ? 1 : 0)
            imlib_blend_image_onto_image(raw, 1, 0, 0, fw, fh, info.frame_x, info.frame_y, fw, fh)
            frames.append(canvas)
            // like ImageIO's unclamped delays: 10 ms or less means the 100 ms browsers use
            let delay = Double(info.frame_delay) / 1000
            delays.append(delay < 0.011 ? 0.1 : delay)
            previous = info
            imlib_context_set_image(raw)
            imlib_free_image_and_decache()
        }
        for image in [blank, undo].compactMap({ $0 }) {
            imlib_context_set_image(image)
            imlib_free_image()
        }
        guard frames.count > 1 else {
            for frame in frames {
                imlib_context_set_image(frame)
                imlib_free_image()
            }
            return nil
        }
        return (frames, delays)
    }

    private static func clear(_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) {
        imlib_image_set_has_alpha(1)
        imlib_context_set_blend(0)
        imlib_context_set_color(0, 0, 0, 0)
        imlib_image_fill_rectangle(x, y, w, h)
    }

    // one thumbnail per turn of the main queue, so keys stay responsive while a directory loads
    private func scheduleThumbnail() {
        guard !thumbnailPending else { return }
        thumbnailPending = true
        DispatchQueue.main.async { [self] in
            thumbnailPending = false
            guard viewer.thumbnailMode,
                  let path = viewer.grid.visible.lazy.map({ self.viewer.files[$0].path })
                      .first(where: { self.thumbs[$0] == nil && !self.failedThumbs.contains($0) })
            else { return }
            if let thumb = Self.makeThumbnail(path) {
                pruneThumbnails()
                thumbs[path] = thumb
            } else {
                failedThumbs.insert(path)
            }
            setNeedsRedraw()
        }
    }

    private static func makeThumbnail(_ path: String) -> Imlib_Image? {
        guard let full = imlib_load_image_frame(path, 1) else { return nil }
        imlib_context_set_image(full)
        let w = imlib_image_get_width(), h = imlib_image_get_height()
        // the largest grid size; X11 draws one pixel per point
        let s = min(1, Config.thumbSizes.last! / CGFloat(max(w, h, 1)))
        imlib_context_set_anti_alias(1)
        let thumb = imlib_create_cropped_scaled_image(0, 0, w, h, max(1, Int32(CGFloat(w) * s)),
                                                      max(1, Int32(CGFloat(h) * s)))
        imlib_free_image_and_decache()
        return thumb
    }

    // shortcut: past 2000 thumbnails (100 KB each at most) the ones out of view go;
    // an LRU would keep more when a huge grid is scrolled back and forth
    private func pruneThumbnails() {
        guard thumbs.count >= 2000 else { return }
        let keep = Set(viewer.grid.visible.map { viewer.files[$0].path })
        for (path, thumb) in thumbs where !keep.contains(path) {
            imlib_context_set_image(thumb)
            imlib_free_image()
        }
        thumbs = thumbs.filter { keep.contains($0.key) }
    }

    // MARK: - drawing

    private func setNeedsRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.async { [self] in
            redrawPending = false
            render()
        }
    }

    private func render() {
        guard width > 0, height > 0 else { return }
        if bufferSize.width != width || bufferSize.height != height {
            if buffer != 0 { XFreePixmap(dpy, buffer) }
            buffer = XCreatePixmap(dpy, win, UInt32(width), UInt32(height), UInt32(depth))
            bufferSize = (width, height)
            if let textDraw {
                XftDrawChange(textDraw, buffer)
            } else {
                textDraw = XftDrawCreate(dpy, buffer, visual, colormap)
            }
        }
        fill(background.pixel, 0, 0, width, height)
        if viewer.thumbnailMode { renderGrid() } else { renderImage() }
        if viewer.barVisible, barHeight > 0 { renderBar() }
        XCopyArea(dpy, buffer, win, gc, 0, 0, UInt32(width), UInt32(height), 0, 0)
        XFlush(dpy)
        // drawing can pull events into Xlib's queue, where the fd source does not see them
        if XEventsQueued(dpy, QueuedAlready) > 0 {
            DispatchQueue.main.async { [self] in drainEvents() }
        }
    }

    private func fill(_ pixel: UInt, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        XSetForeground(dpy, gc, pixel)
        XFillRectangle(dpy, buffer, gc, Int32(x), Int32(y), UInt32(max(0, w)), UInt32(max(0, h)))
    }

    private func renderImage() {
        let w = CGFloat(width), h = CGFloat(canvasHeight)
        guard let shown else {
            if let text = viewer.errorText {
                drawText(text, x: (width - textWidth(text)) / 2, y: canvasHeight / 2)
            }
            return
        }
        let view = viewer.viewport
        let r = view.imageRect
        let dx = r.minX, dy = h - r.maxY, z = view.zoom // X counts y downward from the top
        imlib_context_set_image(shown)
        let iw = CGFloat(imlib_image_get_width()), ih = CGFloat(imlib_image_get_height())
        // only the source pixels that land in the window, in whole pixels so zoom stays steady
        let sx0 = max(0, (-dx / z).rounded(.down)), sy0 = max(0, (-dy / z).rounded(.down))
        let sx1 = min(iw, ((w - dx) / z).rounded(.up)), sy1 = min(ih, ((h - dy) / z).rounded(.up))
        guard sx1 > sx0, sy1 > sy0 else { return }
        let x = Int32((dx + sx0 * z).rounded()), y = Int32((dy + sy0 * z).rounded())
        let dw = Int32(max(1, ((sx1 - sx0) * z).rounded())), dh = Int32(max(1, ((sy1 - sy0) * z).rounded()))
        let sx = Int32(sx0), sy = Int32(sy0), sw = Int32(sx1 - sx0), sh = Int32(sy1 - sy0)
        imlib_context_set_drawable(buffer)
        imlib_context_set_anti_alias(view.antialias ? 1 : 0)
        imlib_context_set_color_modifier(colorModifier)
        guard imlib_image_has_alpha() != 0, let backdrop = imlib_create_image(dw, dh) else {
            imlib_render_image_part_on_drawable_at_size(sx, sy, sw, sh, x, y, dw, dh)
            return
        }
        // Imlib2 blends onto a drawable by reading it back; composing over a backdrop is faster
        imlib_context_set_image(backdrop)
        paintBackdrop(dw, dh, checkered: view.alphaLayer)
        imlib_context_set_blend(1)
        imlib_context_set_operation(IMLIB_OP_COPY)
        imlib_blend_image_onto_image(shown, 0, sx, sy, sw, sh, 0, 0, dw, dh)
        imlib_context_set_color_modifier(nil)
        imlib_render_image_on_drawable(x, y)
        imlib_free_image()
    }

    // the window background, or the 12 px white and gray checkerboard the macOS side draws
    private func paintBackdrop(_ w: Int32, _ h: Int32, checkered: Bool) {
        imlib_image_set_has_alpha(0)
        guard checkered else {
            imlib_context_set_blend(0)
            imlib_context_set_color(Int32(background.red >> 8), Int32(background.green >> 8),
                                    Int32(background.blue >> 8), 255)
            imlib_image_fill_rectangle(0, 0, w, h)
            return
        }
        guard let data = imlib_image_get_data() else { return }
        let width = Int(w)
        for y in 0..<Int(h) {
            for x in 0..<width {
                data[y * width + x] = (x / 12 + y / 12) & 1 == 0 ? 0xFFFF_FFFF : 0xFFBF_BFBF
            }
        }
        imlib_image_put_back_data(data)
    }

    private func renderGrid() {
        let grid = viewer.grid
        var missing = false
        imlib_context_set_drawable(buffer)
        imlib_context_set_color_modifier(nil)
        imlib_context_set_anti_alias(1)
        for i in grid.visible {
            let entry = viewer.files[i]
            let cell = grid.cellRect(i)
            let inner = cell.insetBy(dx: Config.thumbPadding, dy: Config.thumbPadding)
            if let thumb = thumbs[entry.path] {
                imlib_context_set_image(thumb)
                let tw = CGFloat(imlib_image_get_width()), th = CGFloat(imlib_image_get_height())
                let s = min(inner.width / tw, inner.height / th, 1)
                let dw = tw * s, dh = th * s
                imlib_context_set_blend(1)
                imlib_render_image_on_drawable_at_size(Int32(inner.midX - dw / 2), Int32(inner.midY - dh / 2),
                                                       Int32(dw), Int32(dh))
            } else {
                let p = inner.insetBy(dx: inner.width * 0.25, dy: inner.height * 0.25)
                fill(barBackground, Int(p.minX), Int(p.minY), Int(p.width), Int(p.height))
                if !failedThumbs.contains(entry.path) { missing = true }
            }
            if i == viewer.current {
                XSetForeground(dpy, gc, selection)
                let s = cell.insetBy(dx: 2, dy: 2)
                XDrawRectangle(dpy, buffer, gc, Int32(s.minX), Int32(s.minY), UInt32(s.width), UInt32(s.height))
            }
            if entry.marked {
                XSetForeground(dpy, gc, mark)
                XFillArc(dpy, buffer, gc, Int32(cell.maxX - 14), Int32(cell.minY + 6), 8, 8, 0, 360 * 64)
            }
        }
        if missing { scheduleThumbnail() }
    }

    private func renderBar() {
        let y = canvasHeight
        fill(barBackground, 0, y, width, barHeight)
        guard let font else { return }
        let ascent = Int(font.pointee.ascent), descent = Int(font.pointee.descent)
        let baseline = y + (barHeight - ascent - descent) / 2 + ascent
        let pad = 8
        let status = viewer.statusText
        let rightWidth = textWidth(status.right)
        drawText(status.right, x: width - rightWidth - pad, y: baseline)
        drawText(Self.truncatedHead(status.left, width: width - rightWidth - pad * 3, measure: textWidth),
                 x: pad, y: baseline)
    }

    // "…name", the way nsxiv and the macOS bar cut a long name
    static func truncatedHead(_ s: String, width: Int, measure: (String) -> Int) -> String {
        guard width > 0 else { return "" }
        guard measure(s) > width else { return s }
        var rest = Substring(s)
        while !rest.isEmpty, measure("…\(rest)") > width {
            rest = rest.dropFirst()
        }
        return rest.isEmpty ? "" : "…\(rest)"
    }

    private func textWidth(_ s: String) -> Int {
        guard let font, !s.isEmpty else { return 0 }
        var extents = XGlyphInfo()
        let bytes = Array(s.utf8)
        XftTextExtentsUtf8(dpy, font, bytes, Int32(bytes.count), &extents)
        return Int(extents.xOff)
    }

    private func drawText(_ s: String, x: Int, y: Int) {
        guard let font, let textDraw, !s.isEmpty else { return }
        let bytes = Array(s.utf8)
        XftDrawStringUtf8(textDraw, &textColor, font, Int32(x), Int32(y), bytes, Int32(bytes.count))
    }
}
#endif
