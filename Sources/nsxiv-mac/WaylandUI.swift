#if os(Linux)
import CWayland
import CX11
import Foundation

// The Wayland side of the viewer: an xdg-shell toplevel that ImlibRenderer draws into
// shared-memory buffers, at the compositor's fractional scale where it offers one.
// The compositor owns the window size. The viewer picks a dimension only where the
// compositor leaves it open: a new floating window, or a niri column without a width.
final class WaylandUI: ViewerUI {
    private let viewer: Viewer
    private let renderer: ImlibRenderer
    private let display: OpaquePointer
    private var registry: OpaquePointer?
    private var compositor: OpaquePointer?
    private var shm: OpaquePointer?
    private var wmBase: OpaquePointer?
    private var seat: OpaquePointer?
    private var seatVersion: UInt32 = 0
    private var decorations: OpaquePointer?
    private var fractionalScaling: OpaquePointer?
    private var viewporter: OpaquePointer?
    private var outputs: [OpaquePointer: Output] = [:]
    private var outputNames: [UInt32: OpaquePointer] = [:]

    private var surface: OpaquePointer?
    private var xdgSurface: OpaquePointer?
    private var toplevel: OpaquePointer?
    private var viewport: OpaquePointer?

    // the window, in logical units
    private var size = (width: 0, height: 0)
    private var configured = false
    private var requested = (width: Int32(0), height: Int32(0)) // from the last configure; 0 is ours to pick
    private var pendingStates: [UInt32] = []
    private var states: Set<UInt32> = []
    private var bounds: (width: Int32, height: Int32)?
    private var wanted: CGSize
    private var picked: [CGSize] = [] // the last sizes the viewer chose itself, newest last
    private var scale120 = 120 // wp_fractional_scale_v1 sends the scale times 120
    private var enteredOutputs: Set<OpaquePointer> = []
    private var title = ""

    private var buffers: [ShmBuffer] = []
    private var redrawPending = false
    private var waitingForBuffer = false
    private var events: DispatchSourceRead?

    private var keyboard: OpaquePointer?
    private let xkb: OpaquePointer? = xkb_context_new(XKB_CONTEXT_NO_FLAGS)
    private var keymap: OpaquePointer?
    private var keyState: OpaquePointer?
    private var repeatRate: Int32 = 25
    private var repeatDelay: Int32 = 600
    private var repeatTimer: DispatchSourceTimer?
    private var repeatingKey: UInt32?

    private var pointer: OpaquePointer?
    private var pointerSerial: UInt32 = 0
    private var pointerAt = CGPoint.zero
    private var dragging = false
    private var dragged = false
    private var lastClick: (time: UInt32, index: Int)?
    private var scroll = (dx: 0.0, dy: 0.0, steps: Int32(0), smooth: false)
    private var cursorTheme: OpaquePointer?
    private var cursorSurface: OpaquePointer?
    private var cursorScale: Int32 = 0
    private var cursorHotspot = (x: Int32(0), y: Int32(0))

    private final class Output {
        var mode = (width: Int32(0), height: Int32(0)) // pixels
        var scale: Int32 = 1
    }

    // nil without a Wayland session, or when the compositor lacks xdg-shell
    init?(viewer: Viewer) {
        let env = ProcessInfo.processInfo.environment
        guard !(env["WAYLAND_DISPLAY"] ?? "").isEmpty || env["WAYLAND_SOCKET"] != nil,
              let display = wl_display_connect(nil) else { return nil }
        self.viewer = viewer
        self.display = display
        renderer = ImlibRenderer(viewer: viewer)
        wanted = viewer.options.geometry ?? CGSize(width: Config.winWidth, height: Config.winHeight)

        let data = Unmanaged.passUnretained(self).toOpaque()
        registry = wl_display_get_registry(display)
        wl_registry_add_listener(registry, Self.registryListener, data)
        wl_display_roundtrip(display) // the globals
        guard let compositor, shm != nil, let wmBase else {
            warn("the Wayland compositor lacks xdg-shell or wl_compositor 4; trying X11")
            wl_display_disconnect(display)
            return nil
        }
        wl_display_roundtrip(display) // seat capabilities and output modes

        surface = wl_compositor_create_surface(compositor)
        wl_surface_add_listener(surface, Self.surfaceListener, data)
        xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, surface)
        xdg_surface_add_listener(xdgSurface, Self.xdgSurfaceListener, data)
        toplevel = xdg_surface_get_toplevel(xdgSurface)
        xdg_toplevel_add_listener(toplevel, Self.toplevelListener, data)
        xdg_toplevel_set_title(toplevel, Config.appName)
        xdg_toplevel_set_app_id(toplevel, Config.appName)
        if let decorations {
            // KDE and sway draw a title bar, niri a border; GNOME has client-side ones only
            let decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decorations, toplevel)
            zxdg_toplevel_decoration_v1_set_mode(decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE.rawValue)
        }
        if let fractionalScaling, let viewporter {
            let fractional = wp_fractional_scale_manager_v1_get_fractional_scale(fractionalScaling, surface)
            wp_fractional_scale_v1_add_listener(fractional, Self.fractionalListener, data)
            viewport = wp_viewporter_get_viewport(viewporter, surface)
        }
        renderer.onThumbnail = { [unowned self] in self.setNeedsRedraw() }
        viewer.ui = self
    }

    func run() -> Never {
        viewer.start()
        wl_surface_commit(surface) // with no buffer: asks the compositor for the first configure
        wl_display_flush(display)
        let source = DispatchSource.makeReadSource(fileDescriptor: wl_display_get_fd(display), queue: .main)
        source.setEventHandler { [unowned self] in
            if wl_display_dispatch(self.display) < 0 {
                warn("lost the Wayland connection")
                exit(1)
            }
            wl_display_flush(self.display)
        }
        source.resume()
        events = source
        wl_display_dispatch_pending(display) // events the roundtrips read
        dispatchMain()
    }

    // MARK: - globals

    private func bind(_ name: UInt32, _ interface: String, _ version: UInt32) {
        // the newest versions whose events the listeners below handle
        let newest: [String: UInt32] = [
            "wl_compositor": 4, "wl_shm": 1, "wl_seat": 5, "wl_output": 2, "xdg_wm_base": 6,
            "zxdg_decoration_manager_v1": 1, "wp_fractional_scale_manager_v1": 1, "wp_viewporter": 1,
        ]
        guard let newestVersion = newest[interface], let table = nsx_interface(interface),
              interface != "wl_compositor" || version >= 4, // damage_buffer came with 4
              let raw = wl_registry_bind(registry, name, table, min(version, newestVersion)) else { return }
        let proxy = OpaquePointer(raw)
        let data = Unmanaged.passUnretained(self).toOpaque()
        switch interface {
        case "wl_compositor": compositor = proxy
        case "wl_shm": shm = proxy
        case "wl_seat":
            seat = proxy
            seatVersion = min(version, newestVersion)
            wl_seat_add_listener(proxy, Self.seatListener, data)
        case "wl_output":
            outputs[proxy] = Output()
            outputNames[name] = proxy
            wl_output_add_listener(proxy, Self.outputListener, data)
        case "xdg_wm_base":
            wmBase = proxy
            xdg_wm_base_add_listener(proxy, Self.wmBaseListener, data)
        case "zxdg_decoration_manager_v1": decorations = proxy
        case "wp_fractional_scale_manager_v1": fractionalScaling = proxy
        case "wp_viewporter": viewporter = proxy
        default: break
        }
    }

    // an unplugged monitor
    private func unbind(_ name: UInt32) {
        guard let output = outputNames.removeValue(forKey: name) else { return }
        outputs[output] = nil
        enteredOutputs.remove(output)
        wl_output_destroy(output)
        scaleChanged()
    }

    // keyboards and mice come and go; a removed one's objects never send events again
    private func seatCapabilities(_ capabilities: UInt32) {
        let data = Unmanaged.passUnretained(self).toOpaque()
        let hasKeyboard = capabilities & WL_SEAT_CAPABILITY_KEYBOARD.rawValue != 0
        if hasKeyboard, keyboard == nil {
            keyboard = wl_seat_get_keyboard(seat)
            wl_keyboard_add_listener(keyboard, Self.keyboardListener, data)
        } else if !hasKeyboard, let keyboard {
            stopRepeat()
            if seatVersion >= 3 { wl_keyboard_release(keyboard) } else { wl_keyboard_destroy(keyboard) }
            self.keyboard = nil
        }
        let hasPointer = capabilities & WL_SEAT_CAPABILITY_POINTER.rawValue != 0
        if hasPointer, pointer == nil {
            pointer = wl_seat_get_pointer(seat)
            wl_pointer_add_listener(pointer, Self.pointerListener, data)
        } else if !hasPointer, let pointer {
            dragging = false
            if seatVersion >= 3 { wl_pointer_release(pointer) } else { wl_pointer_destroy(pointer) }
            self.pointer = nil
        }
    }

    // MARK: - window size

    private var fullscreen: Bool { states.contains(XDG_TOPLEVEL_STATE_FULLSCREEN.rawValue) }
    private var barHeight: Int { viewer.barVisible ? renderer.barHeight : 0 }
    private var canvasHeight: Int { max(0, size.height - barHeight) }

    // pixels per logical unit
    private var scale: Double {
        if viewport != nil { return Double(scale120) / 120 }
        return Double(enteredOutputs.compactMap { outputs[$0]?.scale }.max() ?? 1)
    }

    // where the window may grow: the compositor's bounds, else the largest output, divided
    // by the fractional scale once it came (wl_output rounds 1.5 up to 2)
    private var maxSize: CGSize {
        if let bounds { return CGSize(width: Int(bounds.width), height: Int(bounds.height)) }
        let fractional = viewport != nil && scale120 != 120 ? Double(scale120) / 120 : nil
        let sizes = outputs.values.map { output -> CGSize in
            let s = fractional ?? Double(max(1, output.scale))
            return CGSize(width: Double(output.mode.width) / s, height: Double(output.mode.height) / s)
        }
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 1920, height: 1080)
    }

    // states in which the compositor's size binds; without them it is a hint
    private static let heldStates = Set([
        XDG_TOPLEVEL_STATE_MAXIMIZED, XDG_TOPLEVEL_STATE_FULLSCREEN, XDG_TOPLEVEL_STATE_RESIZING,
        XDG_TOPLEVEL_STATE_TILED_LEFT, XDG_TOPLEVEL_STATE_TILED_RIGHT,
        XDG_TOPLEVEL_STATE_TILED_TOP, XDG_TOPLEVEL_STATE_TILED_BOTTOM,
    ].map(\.rawValue))

    private func configure(_ serial: UInt32) {
        let wasFullscreen = fullscreen
        states = Set(pendingStates)
        let asked = CGSize(width: Int(requested.width), height: Int(requested.height))
        if states.contains(XDG_TOPLEVEL_STATE_RESIZING.rawValue), asked.width > 0, asked.height > 0 {
            wanted = asked // a dragged size lasts until the next image, as on X11
            remember(asked)
        } else if states.isDisjoint(with: Self.heldStates), picked.contains(asked) {
            // sway answers a floating window's own resize with a configure of that size, late
            // when keys come fast; such an answer leaves the size to the viewer.
            // shortcut: a compositor resize to one of the last eight picked sizes reads as an
            // answer too, track configure serials if that ever matters
            requested = (0, 0)
        }
        xdg_surface_ack_configure(xdgSurface, serial)
        configured = true
        if wasFullscreen, !fullscreen { fitWindow() }
        applySize()
        render() // every configure wants a commit, even one that changes nothing
    }

    // the compositor's size where it gives one, the viewer's where it leaves one open
    private func applySize() {
        var w = CGFloat(requested.width), h = CGFloat(requested.height)
        let barH = CGFloat(barHeight)
        if let image = viewer.fittedSize, image.width > 0, image.height > 0 {
            // one side given and one open, as in a niri column: hug the image at the zoom it
            // will get, which the default scale mode keeps at 100% or less
            let upTo = { (zoom: CGFloat) in self.viewer.viewport.scaleMode == .down ? min(1, zoom) : zoom }
            if w == 0, h > barH { w = min(maxSize.width, (image.width * upTo((h - barH) / image.height)).rounded()) }
            if h == 0, w > 0 { h = min(maxSize.height, (image.height * upTo(w / image.width)).rounded() + barH) }
        }
        if w == 0 { w = wanted.width }
        if h == 0 { h = wanted.height }
        let width = max(1, Int(w)), height = max(1, Int(h))
        guard width != size.width || height != size.height else { return }
        size = (width, height)
        if requested.width == 0, requested.height == 0 { remember(CGSize(width: width, height: height)) }
        layoutChanged()
    }

    private func remember(_ size: CGSize) {
        picked.append(size)
        if picked.count > 8 { picked.removeFirst() }
    }

    // MARK: - ViewerUI

    func loadImage(_ url: URL) -> ImageInfo? { renderer.loadImage(url) }

    func imageChanged() {
        renderer.imageChanged()
        if let name = viewer.currentEntry?.url.lastPathComponent, name != title {
            title = name
            xdg_toplevel_set_title(toplevel, name)
        }
        setNeedsRedraw()
    }

    func viewChanged() { setNeedsRedraw() }
    func gridChanged() { setNeedsRedraw() }
    func barChanged() { setNeedsRedraw() }
    func beep() {} // Wayland has no bell a client may ring

    func layoutChanged() {
        let width = size.width > 0 ? size.width : Int(wanted.width)
        let height = size.height > 0 ? size.height : Int(wanted.height)
        let canvas = CGSize(width: width, height: max(0, height - barHeight))
        viewer.resizeCanvas(canvas)
        viewer.resizeGrid(canvas)
        setNeedsRedraw()
    }

    func invalidateThumbnails(_ entries: [FileEntry]) {
        renderer.invalidateThumbnails(entries)
        setNeedsRedraw()
    }

    func fitWindow() {
        guard let image = viewer.fittedSize, image.width > 0, image.height > 0 else { return }
        let barH = CGFloat(barHeight), limit = maxSize
        let fit = min(1, limit.width / image.width, (limit.height - barH) / image.height)
        wanted = CGSize(width: (image.width * fit).rounded(), height: (image.height * fit).rounded() + barH)
        if configured, !fullscreen { applySize() }
    }

    func resetWindowSize() {
        guard viewer.options.geometry == nil else { return }
        wanted = CGSize(width: Config.winWidth, height: Config.winHeight)
        if configured, !fullscreen { applySize() }
    }

    func toggleFullscreen() {
        // before the first configure this asks to start in fullscreen
        if fullscreen {
            xdg_toplevel_unset_fullscreen(toplevel)
        } else {
            xdg_toplevel_set_fullscreen(toplevel, nil)
        }
        wl_display_flush(display)
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
        guard configured, let surface, let shm, size.width > 0, size.height > 0 else { return }
        let s = scale
        let w = Int((Double(size.width) * s).rounded()), h = Int((Double(size.height) * s).rounded())
        buffers.removeAll { !$0.busy && ($0.width != w || $0.height != h) }
        guard let buffer = buffers.first(where: { !$0.busy && $0.width == w && $0.height == h })
            ?? newBuffer(shm, width: w, height: h) else {
            waitingForBuffer = true // drawn when the compositor hands a buffer back
            return
        }
        renderer.render(into: buffer.image, width: w, height: h, scale: s)
        if let viewport {
            wp_viewport_set_destination(viewport, Int32(size.width), Int32(size.height))
        } else {
            wl_surface_set_buffer_scale(surface, Int32(s))
        }
        wl_surface_attach(surface, buffer.buffer, 0, 0)
        wl_surface_damage_buffer(surface, 0, 0, Int32.max, Int32.max)
        wl_surface_commit(surface)
        buffer.busy = true
        wl_display_flush(display)
    }

    private func newBuffer(_ shm: OpaquePointer, width: Int, height: Int) -> ShmBuffer? {
        guard buffers.count < 3, let buffer = ShmBuffer(shm: shm, width: width, height: height) else { return nil }
        buffer.released = { [unowned self] in
            guard self.waitingForBuffer else { return }
            self.waitingForBuffer = false
            self.setNeedsRedraw()
        }
        buffers.append(buffer)
        return buffer
    }

    private func scaleChanged() {
        loadCursor()
        fitWindow() // the screen's logical size may have changed with the scale
        setNeedsRedraw()
    }

    // a wl_buffer over memory both sides map; Imlib2 draws into the same pixels
    private final class ShmBuffer {
        let buffer: OpaquePointer
        let image: Imlib_Image
        let width: Int
        let height: Int
        var busy = false
        var released: () -> Void = {}
        private let pixels: UnsafeMutableRawPointer
        private let byteCount: Int

        init?(shm: OpaquePointer, width: Int, height: Int) {
            let stride = width * 4
            byteCount = stride * height
            let fd = nsx_shm_file(byteCount)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard let pixels = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                  pixels != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
            self.pixels = pixels
            self.width = width
            self.height = height
            let pool = wl_shm_create_pool(shm, fd, Int32(byteCount))
            buffer = wl_shm_pool_create_buffer(pool, 0, Int32(width), Int32(height), Int32(stride),
                                               WL_SHM_FORMAT_XRGB8888.rawValue) // Imlib2's ARGB words
            wl_shm_pool_destroy(pool)
            image = imlib_create_image_using_data(Int32(width), Int32(height),
                                                  pixels.assumingMemoryBound(to: UInt32.self))
            wl_buffer_add_listener(buffer, Self.listener, Unmanaged.passUnretained(self).toOpaque())
        }

        deinit {
            imlib_context_set_image(image)
            imlib_free_image() // leaves the mapped pixels to munmap
            wl_buffer_destroy(buffer)
            munmap(pixels, byteCount)
        }

        private static let listener = WaylandUI.make(wl_buffer_listener(release: { data, _ in
            let buffer = Unmanaged<ShmBuffer>.fromOpaque(data!).takeUnretainedValue()
            buffer.busy = false
            buffer.released()
        }))
    }

    // MARK: - keyboard

    private func loadKeymap(_ format: UInt32, _ fd: Int32, _ length: UInt32) {
        defer { close(fd) }
        guard format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1.rawValue,
              let text = mmap(nil, Int(length), PROT_READ, MAP_PRIVATE, fd, 0),
              text != UnsafeMutableRawPointer(bitPattern: -1) else { return }
        defer { munmap(text, Int(length)) }
        guard let map = xkb_keymap_new_from_string(xkb, text.assumingMemoryBound(to: CChar.self),
                                                   XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
        else { return }
        xkb_state_unref(keyState)
        xkb_keymap_unref(keymap)
        keymap = map
        keyState = xkb_state_new(map)
    }

    private func key(_ key: UInt32, pressed: Bool) {
        let code = key + 8 // evdev to xkb keycodes
        guard pressed else {
            if code == repeatingKey { stopRepeat() }
            return
        }
        deliver(code)
        if let keymap, repeatRate > 0, xkb_keymap_key_repeats(keymap, code) != 0 { startRepeat(code) }
    }

    private func deliver(_ code: UInt32) {
        guard let keyState, let name = keyName(forKeysym: UInt(xkb_state_key_get_one_sym(keyState, code)))
        else { return }
        let ctrl = xkb_state_mod_name_is_active(keyState, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0
        _ = viewer.handle(Keystroke(key: name, ctrl: ctrl))
    }

    // Wayland leaves key repeat to the client
    private func startRepeat(_ code: UInt32) {
        stopRepeat()
        repeatingKey = code
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // GCD folds the ticks a busy main queue missed into one handler call, so a held key
        // cannot pile repeats up behind a slow decode
        timer.schedule(deadline: .now() + .milliseconds(Int(repeatDelay)), repeating: 1 / Double(repeatRate))
        timer.setEventHandler { [unowned self] in self.deliver(code) }
        timer.resume()
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.cancel()
        repeatTimer = nil
        repeatingKey = nil
    }

    // MARK: - pointer

    private func pointerEntered(_ serial: UInt32, at p: CGPoint) {
        pointerSerial = serial
        pointerAt = p
        if cursorScale == 0 { loadCursor() }
        setCursor()
    }

    private func setCursor() {
        guard let pointer, let cursorSurface, pointerSerial != 0 else { return }
        wl_pointer_set_cursor(pointer, pointerSerial, cursorSurface, cursorHotspot.x, cursorHotspot.y)
    }

    // the theme's arrow at the window's scale; a client draws its own cursor on Wayland
    private func loadCursor() {
        guard let shm, let compositor else { return }
        let scale = Int32(self.scale.rounded(.up))
        guard scale != cursorScale else { return }
        cursorScale = scale
        let env = ProcessInfo.processInfo.environment
        let size = env["XCURSOR_SIZE"].flatMap { Int32($0) } ?? 24
        if let cursorTheme { wl_cursor_theme_destroy(cursorTheme) }
        cursorTheme = wl_cursor_theme_load(env["XCURSOR_THEME"], size * scale, shm)
        guard let cursorTheme,
              let cursor = wl_cursor_theme_get_cursor(cursorTheme, "default")
                ?? wl_cursor_theme_get_cursor(cursorTheme, "left_ptr"),
              let image = cursor.pointee.images[0], let buffer = wl_cursor_image_get_buffer(image) else { return }
        if cursorSurface == nil { cursorSurface = wl_compositor_create_surface(compositor) }
        wl_surface_set_buffer_scale(cursorSurface, scale)
        wl_surface_attach(cursorSurface, buffer, 0, 0)
        wl_surface_damage_buffer(cursorSurface, 0, 0, Int32.max, Int32.max)
        wl_surface_commit(cursorSurface)
        cursorHotspot = (Int32(image.pointee.hotspot_x) / scale, Int32(image.pointee.hotspot_y) / scale)
        setCursor()
    }

    private func button(_ button: UInt32, pressed: Bool, time: UInt32) {
        let left: UInt32 = 0x110, right: UInt32 = 0x111 // BTN_LEFT, BTN_RIGHT from linux/input-event-codes.h
        let p = pointerAt
        let inCanvas = Int(p.y) < canvasHeight
        switch (button, pressed) {
        case (left, true) where !viewer.thumbnailMode:
            dragging = true
            dragged = false
        case (left, true):
            // no drag starts here, so the release after a double click cannot navigate
            guard inCanvas, let i = viewer.grid.index(at: p) else { return }
            if let last = lastClick, last.index == i, time &- last.time < 400 {
                lastClick = nil
                viewer.open(i)
            } else {
                lastClick = (time, i)
                viewer.select(i)
            }
        case (left, false):
            guard dragging else { return }
            dragging = false
            guard !viewer.thumbnailMode, !dragged, inCanvas else { return }
            let navW = CGFloat(size.width) * Config.navWidthFraction
            if p.x < navW {
                viewer.navigate(-1)
            } else if p.x > CGFloat(size.width) - navW {
                viewer.navigate(1)
            }
        case (right, true):
            if !viewer.thumbnailMode {
                viewer.switchMode()
            } else if inCanvas, let i = viewer.grid.index(at: p) {
                viewer.toggleMark(at: i) // marks without moving the selection, like nsxiv
            }
        default: break
        }
    }

    private func pointerMoved(to p: CGPoint) {
        defer { pointerAt = p }
        guard dragging, !viewer.thumbnailMode else { return }
        dragged = true
        viewer.pan(dx: p.x - pointerAt.x, dy: pointerAt.y - p.y) // the surface counts y downward
    }

    private func axis(_ axis: UInt32, _ value: Double) {
        if axis == WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue { scroll.dy += value } else { scroll.dx += value }
        if seatVersion < 5 { axisFrame() } // frames came with wl_seat 5
    }

    // one scroll gesture: a wheel zooms, as with a mouse on macOS; a touchpad pans
    private func axisFrame() {
        defer { scroll = (0, 0, 0, false) }
        if viewer.thumbnailMode {
            if !scroll.smooth, scroll.steps != 0 {
                viewer.scrollGrid(by: CGFloat(scroll.steps) * viewer.grid.cellSize / 3) // as on X11
            } else if scroll.dy != 0 {
                viewer.scrollGrid(by: CGFloat(scroll.dy))
            }
        } else if scroll.smooth {
            viewer.pan(dx: -CGFloat(scroll.dx), dy: CGFloat(scroll.dy))
        } else if scroll.steps != 0 || scroll.dy != 0 {
            let steps = scroll.steps != 0 ? Int(scroll.steps) : (scroll.dy > 0 ? 1 : -1)
            for _ in 0..<abs(steps) { viewer.zoomStep(steps > 0 ? -1 : 1) } // down zooms out
        }
    }

    // MARK: - listeners

    // libwayland keeps the pointer, so each listener lives as long as the process
    private static func make<T>(_ value: T) -> UnsafeMutablePointer<T> {
        let listener = UnsafeMutablePointer<T>.allocate(capacity: 1)
        listener.initialize(to: value)
        return listener
    }

    private static func ui(_ data: UnsafeMutableRawPointer?) -> WaylandUI {
        Unmanaged<WaylandUI>.fromOpaque(data!).takeUnretainedValue()
    }

    private static let registryListener = make(wl_registry_listener(
        global: { data, _, name, interface, version in
            guard let interface else { return }
            WaylandUI.ui(data).bind(name, String(cString: interface), version)
        },
        global_remove: { data, _, name in WaylandUI.ui(data).unbind(name) }))

    private static let seatListener = make(wl_seat_listener(
        capabilities: { data, _, capabilities in WaylandUI.ui(data).seatCapabilities(capabilities) },
        name: { _, _, _ in }))

    // newer libwayland headers list more events; the bound versions never send those
    private static let outputListener: UnsafeMutablePointer<wl_output_listener> = {
        var l = wl_output_listener()
        l.geometry = { _, _, _, _, _, _, _, _, _, _ in }
        l.mode = { data, output, flags, width, height, _ in
            guard let output, flags & WL_OUTPUT_MODE_CURRENT.rawValue != 0 else { return }
            WaylandUI.ui(data).outputs[output]?.mode = (width, height)
        }
        l.done = { _, _ in }
        l.scale = { data, output, factor in
            guard let output else { return }
            let ui = WaylandUI.ui(data)
            ui.outputs[output]?.scale = factor
            ui.scaleChanged()
        }
        return make(l)
    }()

    private static let surfaceListener: UnsafeMutablePointer<wl_surface_listener> = {
        var l = wl_surface_listener()
        l.enter = { data, _, output in
            guard let output else { return }
            let ui = WaylandUI.ui(data)
            ui.enteredOutputs.insert(output)
            ui.scaleChanged()
        }
        l.leave = { data, _, output in
            guard let output else { return }
            let ui = WaylandUI.ui(data)
            ui.enteredOutputs.remove(output)
            ui.scaleChanged()
        }
        return make(l)
    }()

    private static let wmBaseListener = make(xdg_wm_base_listener(
        ping: { _, base, serial in xdg_wm_base_pong(base, serial) }))

    private static let xdgSurfaceListener = make(xdg_surface_listener(
        configure: { data, _, serial in WaylandUI.ui(data).configure(serial) }))

    private static let toplevelListener = make(xdg_toplevel_listener(
        configure: { data, _, width, height, states in
            let ui = WaylandUI.ui(data)
            ui.requested = (width, height)
            ui.pendingStates = []
            if let states, let words = states.pointee.data {
                let count = states.pointee.size / MemoryLayout<UInt32>.size
                ui.pendingStates = Array(UnsafeBufferPointer(start: words.assumingMemoryBound(to: UInt32.self),
                                                             count: count))
            }
        },
        close: { data, _ in WaylandUI.ui(data).viewer.quit() },
        configure_bounds: { data, _, width, height in
            WaylandUI.ui(data).bounds = width > 0 && height > 0 ? (width, height) : nil
        },
        wm_capabilities: { _, _, _ in }))

    private static let fractionalListener = make(wp_fractional_scale_v1_listener(
        preferred_scale: { data, _, scale in
            let ui = WaylandUI.ui(data)
            ui.scale120 = Int(scale)
            ui.scaleChanged()
        }))

    private static let keyboardListener: UnsafeMutablePointer<wl_keyboard_listener> = {
        var l = wl_keyboard_listener()
        l.keymap = { data, _, format, fd, length in WaylandUI.ui(data).loadKeymap(format, fd, length) }
        l.enter = { _, _, _, _, _ in }
        l.leave = { data, _, _, _ in WaylandUI.ui(data).stopRepeat() }
        l.key = { data, _, _, _, key, state in
            WaylandUI.ui(data).key(key, pressed: state == WL_KEYBOARD_KEY_STATE_PRESSED.rawValue)
        }
        l.modifiers = { data, _, _, depressed, latched, locked, group in
            guard let keyState = WaylandUI.ui(data).keyState else { return }
            xkb_state_update_mask(keyState, depressed, latched, locked, 0, 0, group)
        }
        l.repeat_info = { data, _, rate, delay in
            let ui = WaylandUI.ui(data)
            ui.repeatRate = rate
            ui.repeatDelay = delay
        }
        return make(l)
    }()

    private static let pointerListener: UnsafeMutablePointer<wl_pointer_listener> = {
        var l = wl_pointer_listener()
        l.enter = { data, _, serial, _, x, y in
            WaylandUI.ui(data).pointerEntered(serial, at: CGPoint(x: wl_fixed_to_double(x), y: wl_fixed_to_double(y)))
        }
        l.leave = { data, _, _, _ in WaylandUI.ui(data).dragging = false }
        l.motion = { data, _, _, x, y in
            WaylandUI.ui(data).pointerMoved(to: CGPoint(x: wl_fixed_to_double(x), y: wl_fixed_to_double(y)))
        }
        l.button = { data, _, _, time, button, state in
            WaylandUI.ui(data).button(button, pressed: state == WL_POINTER_BUTTON_STATE_PRESSED.rawValue, time: time)
        }
        l.axis = { data, _, _, axis, value in WaylandUI.ui(data).axis(axis, wl_fixed_to_double(value)) }
        l.frame = { data, _ in WaylandUI.ui(data).axisFrame() }
        l.axis_source = { data, _, source in
            WaylandUI.ui(data).scroll.smooth = source == WL_POINTER_AXIS_SOURCE_FINGER.rawValue
                || source == WL_POINTER_AXIS_SOURCE_CONTINUOUS.rawValue
        }
        l.axis_stop = { _, _, _, _ in }
        l.axis_discrete = { data, _, axis, discrete in
            if axis == WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue { WaylandUI.ui(data).scroll.steps += discrete }
        }
        return make(l)
    }()
}
#endif
