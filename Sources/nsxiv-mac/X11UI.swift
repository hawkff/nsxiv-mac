#if os(Linux)
import CX11
import Foundation

// The X11 side of the viewer: an Xlib window that shows what ImlibRenderer draws.
final class X11UI: ViewerUI {
    private let viewer: Viewer
    private let dpy: OpaquePointer
    private let screen: Int32
    private let win: Window
    private let renderer: ImlibRenderer
    private let wmDelete, wmState, wmFullscreen, wmName, utf8String, atomType: Atom

    private var width: Int
    private var height: Int
    private var canvas: Imlib_Image? // the window's pixels, drawn by the renderer
    private var canvasSize = (width: 0, height: 0)
    private var title = ""
    private var mapped = false
    private var fullscreen = false
    private var redrawPending = false
    private var events: DispatchSourceRead?

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

        let size = viewer.options.geometry ?? CGSize(width: Config.winWidth, height: Config.winHeight)
        width = Int(size.width)
        height = Int(size.height)
        var attrs = XSetWindowAttributes()
        attrs.colormap = colormap
        attrs.border_pixel = 0
        attrs.background_pixel = XBlackPixel(dpy, screen)
        attrs.event_mask = KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask
            | PointerMotionMask | StructureNotifyMask | ExposureMask | PropertyChangeMask | FocusChangeMask
        let win = XCreateWindow(dpy, XRootWindow(dpy, screen), 0, 0, UInt32(size.width), UInt32(size.height), 0,
                                depth, UInt32(InputOutput), visual,
                                UInt(CWColormap | CWBorderPixel | CWBackPixel | CWEventMask), &attrs)
        self.win = win

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

        imlib_context_set_display(dpy)
        imlib_context_set_visual(visual)
        imlib_context_set_colormap(colormap)
        renderer = ImlibRenderer(viewer: viewer)
        renderer.onThumbnail = { [unowned self] in self.setNeedsRedraw() }
        viewer.ui = self
    }

    private struct RepeatScan {
        let keycode: UInt32
        var ended = false
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
            case Expose: if ev.xexpose.count == 0 { present() }
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
        guard let name = keyName(forKeysym: sym) else { return }
        _ = viewer.handle(Keystroke(key: name, ctrl: key.state & UInt32(ControlMask) != 0))
    }

    // A held key outruns large decodes. The presses of that key queued while the last one
    // was handled go, past other events but not past the key's release or a focus change
    // (which may take the release elsewhere), so taps still count.
    private func dropRepeats(of keycode: UInt32) {
        var scan = RepeatScan(keycode: keycode)
        var dropped = XEvent()
        while withUnsafeMutablePointer(to: &scan, { scan in
            XCheckIfEvent(dpy, &dropped, { _, event, arg in
                guard let e = event?.pointee, let arg else { return 0 }
                let scan = UnsafeMutableRawPointer(arg).assumingMemoryBound(to: RepeatScan.self)
                switch e.type {
                case FocusIn, FocusOut: scan.pointee.ended = true
                case KeyRelease where e.xkey.keycode == scan.pointee.keycode: scan.pointee.ended = true
                case KeyPress where e.xkey.keycode == scan.pointee.keycode && !scan.pointee.ended: return 1
                default: break
                }
                return 0
            }, UnsafeMutableRawPointer(scan).assumingMemoryBound(to: CChar.self))
        }) != 0 {}
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

    private var barHeight: Int { viewer.barVisible ? renderer.barHeight : 0 }
    private var canvasHeight: Int { max(0, height - barHeight) }

    // MARK: - ViewerUI

    func loadImage(_ url: URL) -> ImageInfo? { renderer.loadImage(url) }

    func imageChanged() {
        renderer.imageChanged()
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
        renderer.invalidateThumbnails(entries)
        setNeedsRedraw()
    }

    func fitWindow() {
        guard !fullscreen, let size = viewer.fittedSize, size.width > 0, size.height > 0 else { return }
        let barH = CGFloat(barHeight)
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
            hints.base_height = Int32(barHeight)
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
        if canvasSize.width != width || canvasSize.height != height {
            if let canvas {
                imlib_context_set_image(canvas)
                imlib_free_image()
            }
            canvas = imlib_create_image(Int32(width), Int32(height))
            canvasSize = (width, height)
        }
        guard let canvas else { return }
        renderer.render(into: canvas, width: width, height: height, scale: 1)
        present()
    }

    private func present() {
        guard let canvas, canvasSize.width == width, canvasSize.height == height else { return setNeedsRedraw() }
        imlib_context_set_image(canvas)
        imlib_context_set_drawable(win)
        imlib_context_set_blend(0)
        imlib_context_set_anti_alias(0)
        imlib_context_set_color_modifier(nil)
        imlib_render_image_on_drawable(0, 0)
        XFlush(dpy)
        // drawing can pull events into Xlib's queue, where the fd source does not see them
        if XEventsQueued(dpy, QueuedAlready) > 0 {
            DispatchQueue.main.async { [self] in drainEvents() }
        }
    }
}
#endif
