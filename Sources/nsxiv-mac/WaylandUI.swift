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
    private var csd = false // no server-side decorations, as on GNOME: the window draws a title bar
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
    private var cursorName = "default"
    private var cursorShown = false // an enter or a new scale wants the cursor set again
    private var lastTitleClick: UInt32?
    private let sway = ProcessInfo.processInfo.environment["SWAYSOCK"] != nil
    private var swayRoom: CGSize? // what a floating window's content may take in its sway workspace
    private var swayFrom: CGSize? // the size before a burst of resizes, until sway places the window

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
            // KDE and sway draw a title bar, niri a border; the reply says whether they will
            let decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decorations, toplevel)
            zxdg_toplevel_decoration_v1_add_listener(decoration, Self.decorationListener, data)
            zxdg_toplevel_decoration_v1_set_mode(decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE.rawValue)
        } else {
            csd = true // GNOME and Weston leave decorations to the client
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
        Self.loadKWinHelper()
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
    // the title bar the window draws without server-side decorations, as tall as the status bar
    private var titleHeight: Int { csd && !fullscreen ? renderer.barHeight : 0 }
    private var chrome: Int { titleHeight + barHeight } // the rows that are not canvas
    private var canvasHeight: Int { max(0, size.height - chrome) }

    // pixels per logical unit
    private var scale: Double {
        if viewport != nil { return Double(scale120) / 120 }
        return Double(enteredOutputs.compactMap { outputs[$0]?.scale }.max() ?? 1)
    }

    // where the window may grow: the compositor's bounds, sway's workspace, else the largest
    // output, divided by the fractional scale once it came (wl_output rounds 1.5 up to 2)
    private var maxSize: CGSize {
        if let bounds { return CGSize(width: Int(bounds.width), height: Int(bounds.height)) }
        if let swayRoom { return swayRoom }
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
        let wasFullscreen = fullscreen, oldChrome = chrome
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
        if chrome != oldChrome { layoutChanged() } // the title bar goes with fullscreen
        setCursor(cursor(at: pointerAt)) // no resize arrow once the window is fullscreen or tiled
        if swayRoom == nil { swayResized(from: CGSize(width: size.width, height: size.height)) }
        render() // every configure wants a commit, even one that changes nothing
    }

    // the compositor's size where it gives one, the viewer's where it leaves one open
    private func applySize() {
        var w = CGFloat(requested.width), h = CGFloat(requested.height)
        let rows = CGFloat(chrome)
        if let image = viewer.fittedSize, image.width > 0, image.height > 0 {
            // one side given and one open, as in a niri column: hug the image at the zoom it
            // will get, which the default scale mode keeps at 100% or less
            let upTo = { (zoom: CGFloat) in self.viewer.viewport.scaleMode == .down ? min(1, zoom) : zoom }
            if w == 0, h > rows { w = min(maxSize.width, (image.width * upTo((h - rows) / image.height)).rounded()) }
            if h == 0, w > 0 { h = min(maxSize.height, (image.height * upTo(w / image.width)).rounded() + rows) }
        }
        // the 800x600 default overflows 1280x800 at scale 1.5
        if w == 0 { w = min(wanted.width, maxSize.width.rounded(.down)) }
        if h == 0 { h = min(wanted.height, maxSize.height.rounded(.down)) }
        let width = max(1, Int(w)), height = max(1, Int(h))
        guard width != size.width || height != size.height else { return }
        let old = CGSize(width: size.width, height: size.height)
        size = (width, height)
        if requested.width == 0, requested.height == 0 {
            remember(CGSize(width: width, height: height))
            if old.width > 0 { swayResized(from: old) }
        }
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
        let canvas = CGSize(width: width, height: max(0, height - chrome))
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
        let rows = CGFloat(chrome), limit = maxSize
        let fit = min(1, limit.width / image.width, (limit.height - rows) / image.height)
        wanted = CGSize(width: (image.width * fit).rounded(), height: (image.height * fit).rounded() + rows)
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
        let top = min(Int((Double(titleHeight) * s).rounded()), h - 1)
        renderer.render(into: buffer.image(below: top), width: w, height: h - top, scale: s)
        if top > 0 {
            renderer.renderTitle(title.isEmpty ? Config.appName : title, into: buffer.image, width: w, height: top, scale: s)
        }
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
        cursorShown = false
        setCursor(cursorName)
        fitWindow() // the screen's logical size may have changed with the scale
        // on another output, sway's workspace may leave another room
        if size.width > 0 { swayResized(from: CGSize(width: size.width, height: size.height)) }
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

        // Imlib2's view of the rows below a title bar, made when a title bar first needs it
        private var below: (top: Int, image: Imlib_Image)?

        func image(below top: Int) -> Imlib_Image {
            guard top > 0 else { return image }
            if let below, below.top == top { return below.image }
            if let below {
                imlib_context_set_image(below.image)
                imlib_free_image()
            }
            let rows: Imlib_Image = imlib_create_image_using_data(Int32(width), Int32(height - top),
                                                     (pixels + top * width * 4).assumingMemoryBound(to: UInt32.self))
            below = (top, rows)
            return rows
        }

        deinit {
            if let below {
                imlib_context_set_image(below.image)
                imlib_free_image()
            }
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
        cursorShown = false
        setCursor(cursor(at: p))
    }

    // a client draws its own cursor on Wayland: the theme's, at the window's scale
    private func setCursor(_ name: String) {
        if name != cursorName {
            cursorName = name
            cursorShown = false
        }
        guard !cursorShown, let shm, let compositor, let pointer, pointerSerial != 0 else { return }
        let scale = Int32(self.scale.rounded(.up))
        if scale != cursorScale || cursorTheme == nil {
            cursorScale = scale
            let env = ProcessInfo.processInfo.environment
            let size = env["XCURSOR_SIZE"].flatMap { Int32($0) } ?? 24
            if let cursorTheme { wl_cursor_theme_destroy(cursorTheme) }
            cursorTheme = wl_cursor_theme_load(env["XCURSOR_THEME"], size * scale, shm)
        }
        guard let cursorTheme,
              let cursor = wl_cursor_theme_get_cursor(cursorTheme, name)
                ?? wl_cursor_theme_get_cursor(cursorTheme, "default")
                ?? wl_cursor_theme_get_cursor(cursorTheme, "left_ptr"),
              let image = cursor.pointee.images[0], let buffer = wl_cursor_image_get_buffer(image) else { return }
        if cursorSurface == nil { cursorSurface = wl_compositor_create_surface(compositor) }
        wl_surface_set_buffer_scale(cursorSurface, scale)
        wl_surface_attach(cursorSurface, buffer, 0, 0)
        wl_surface_damage_buffer(cursorSurface, 0, 0, Int32.max, Int32.max)
        wl_surface_commit(cursorSurface)
        wl_pointer_set_cursor(pointer, pointerSerial, cursorSurface,
                              Int32(image.pointee.hotspot_x) / scale, Int32(image.pointee.hotspot_y) / scale)
        cursorShown = true
    }

    // BTN_LEFT and BTN_RIGHT from linux/input-event-codes.h
    private static let leftButton: UInt32 = 0x110
    private static let rightButton: UInt32 = 0x111

    // the edges of a floating window with its own decorations near p, as resize_edge bits
    private func edges(at p: CGPoint) -> UInt32 {
        guard csd, states.isDisjoint(with: Self.heldStates) else { return 0 }
        let e: CGFloat = 6, w = CGFloat(size.width), h = CGFloat(size.height)
        var edges: UInt32 = 0
        if p.y < e { edges |= XDG_TOPLEVEL_RESIZE_EDGE_TOP.rawValue }
        if p.y >= h - e { edges |= XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM.rawValue }
        if p.x < e { edges |= XDG_TOPLEVEL_RESIZE_EDGE_LEFT.rawValue }
        if p.x >= w - e { edges |= XDG_TOPLEVEL_RESIZE_EDGE_RIGHT.rawValue }
        return edges
    }

    // the names libwayland-cursor's own theme has too
    private static let edgeCursors: [UInt32: String] = [
        XDG_TOPLEVEL_RESIZE_EDGE_TOP.rawValue: "top_side",
        XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM.rawValue: "bottom_side",
        XDG_TOPLEVEL_RESIZE_EDGE_LEFT.rawValue: "left_side",
        XDG_TOPLEVEL_RESIZE_EDGE_RIGHT.rawValue: "right_side",
        XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT.rawValue: "top_left_corner",
        XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT.rawValue: "top_right_corner",
        XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT.rawValue: "bottom_left_corner",
        XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT.rawValue: "bottom_right_corner",
    ]

    private func cursor(at p: CGPoint) -> String { Self.edgeCursors[edges(at: p)] ?? "default" }

    // a press on the title bar or an edge the window draws itself: the compositor moves or
    // resizes the window, or shows its window menu
    private func decorationPressed(_ button: UInt32, at p: CGPoint, time: UInt32, serial: UInt32) -> Bool {
        guard let seat else { return false }
        let edges = edges(at: p)
        guard button == Self.leftButton && edges != 0 || p.y < CGFloat(titleHeight) else { return false }
        switch button {
        case Self.leftButton where edges != 0:
            xdg_toplevel_resize(toplevel, seat, serial, edges)
        case Self.rightButton:
            xdg_toplevel_show_window_menu(toplevel, seat, serial, Int32(p.x), Int32(p.y))
        case Self.leftButton where p.x >= CGFloat(size.width - titleHeight):
            viewer.quit() // the close button
        case Self.leftButton:
            if let last = lastTitleClick, time &- last < 400 {
                lastTitleClick = nil
                if states.contains(XDG_TOPLEVEL_STATE_MAXIMIZED.rawValue) {
                    xdg_toplevel_unset_maximized(toplevel)
                } else {
                    xdg_toplevel_set_maximized(toplevel)
                }
            } else {
                lastTitleClick = time
                xdg_toplevel_move(toplevel, seat, serial)
            }
        default: break
        }
        wl_display_flush(display)
        return true
    }

    private func button(_ button: UInt32, pressed: Bool, time: UInt32, serial: UInt32) {
        if pressed, decorationPressed(button, at: pointerAt, time: time, serial: serial) { return }
        let left = Self.leftButton, right = Self.rightButton
        let p = CGPoint(x: pointerAt.x, y: pointerAt.y - CGFloat(titleHeight)) // canvas coordinates
        let inCanvas = p.y >= 0 && Int(p.y) < canvasHeight
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
        setCursor(cursor(at: p))
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

    // MARK: - sway

    // sway keeps a floating window's top-left corner when the window resizes itself and sends
    // no configure_bounds, so a growing window ran off the screen. Its IPC can do what the
    // macOS side does: keep the window's center, keep it inside the workspace, and cap the
    // size to the workspace. Resizes within 50 ms share one placement.
    private func swayResized(from old: CGSize) {
        guard sway, swayFrom == nil, states.isDisjoint(with: Self.heldStates) else { return }
        swayFrom = old
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
            guard let from = swayFrom else { return }
            swayFrom = nil
            // fullscreen or maximized meanwhile: sway draws no title bar or borders then
            guard states.isDisjoint(with: Self.heldStates) else { return }
            let to = CGSize(width: size.width, height: size.height), pid = Int(getpid())
            Self.helperQueue.async {
                let room = Self.swayPlace(pid: pid, from: from, to: to)
                DispatchQueue.main.async { [self] in
                    guard let room, room != swayRoom, states.isDisjoint(with: Self.heldStates) else { return }
                    swayRoom = room
                    fitWindow()
                    if configured, !fullscreen { applySize() } // the grid's size too
                }
            }
        }
    }

    // swaymsg and dbus-send run here, off the main queue and one at a time
    private static let helperQueue = DispatchQueue(label: "compositor-helpers")

    // moves the window of pid in sway's tree; returns the room for content in its workspace
    private static func swayPlace(pid: Int, from old: CGSize, to new: CGSize) -> CGSize? {
        guard let tree = swaymsg("-t", "get_tree") as? [String: Any],
              let found = swayFind(pid: pid, in: tree, workspace: nil),
              found.node["type"] as? String == "floating_con", (found.node["fullscreen_mode"] as? Int ?? 0) == 0,
              let id = found.node["id"] as? Int,
              let below = swayRect(found.node["rect"]), let content = swayRect(found.node["window_rect"])
        else { return nil }
        // like i3, sway's rect leaves out the title bar, which deco_rect describes
        let title = swayRect(found.node["deco_rect"])?.height ?? 0
        let frame = CGRect(x: below.minX, y: below.minY - title, width: below.width, height: below.height + title)
        let space = found.workspace
        // sway's title bar and borders; the top-left corner is still where it was before the resize
        let deco = CGSize(width: frame.width - content.width, height: frame.height - content.height)
        let outer = CGSize(width: new.width + deco.width, height: new.height + deco.height)
        let cx = frame.minX + (old.width + deco.width) / 2, cy = frame.minY + (old.height + deco.height) / 2
        let x = Int(max(space.minX, min(cx - outer.width / 2, space.maxX - outer.width)))
        let y = Int(max(space.minY, min(cy - outer.height / 2, space.maxY - outer.height)))
        if x != Int(frame.minX) || y != Int(frame.minY) {
            _ = swaymsg("[con_id=\(id)] move absolute position \(x) \(y)")
        }
        return CGSize(width: space.width - deco.width, height: space.height - deco.height)
    }

    private static func swayFind(pid: Int, in node: [String: Any],
                                 workspace: CGRect?) -> (node: [String: Any], workspace: CGRect)? {
        let isWorkspace = node["type"] as? String == "workspace"
        // hidden scratchpad windows sit on a stand-in workspace that spans every output
        if isWorkspace, (node["name"] as? String)?.hasPrefix("__i3") == true { return nil }
        let workspace = isWorkspace ? swayRect(node["rect"]) : workspace
        if node["pid"] as? Int == pid, let workspace { return (node, workspace) }
        let children = (node["nodes"] as? [[String: Any]] ?? []) + (node["floating_nodes"] as? [[String: Any]] ?? [])
        for child in children {
            if let found = swayFind(pid: pid, in: child, workspace: workspace) { return found }
        }
        return nil
    }

    private static func swayRect(_ value: Any?) -> CGRect? {
        guard let r = value as? [String: Any], let x = r["x"] as? Int, let y = r["y"] as? Int,
              let w = r["width"] as? Int, let h = r["height"] as? Int else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // sway's own client speaks its IPC, at the socket SWAYSOCK names
    private static func swaymsg(_ args: String...) -> Any? {
        output(of: ["swaymsg", "-r"] + args).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    // a helper program's output; nil when it does not start or exits with an error
    private static func output(of arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: - KWin

    // KWin lets a window that resizes itself grow past the work area. On KDE a KWin script,
    // loaded once over D-Bus, watches this process's window from inside KWin and moves it back
    // in when a resize pushes it past an edge, as mutter does on GNOME. Nothing goes over D-Bus
    // per image, and the script unloads itself when the window goes.
    private static func loadKWinHelper() {
        let env = ProcessInfo.processInfo.environment
        guard env["XDG_CURRENT_DESKTOP"]?.split(separator: ":").contains("KDE") == true,
              let runtime = env["XDG_RUNTIME_DIR"] else { return }
        let pid = getpid(), plugin = "nsxiv-mac-\(pid)", path = "\(runtime)/\(plugin).js"
        helperQueue.async {
            // an earlier process with this pid may have left its script behind
            unlink(path)
            _ = kwin("/Scripting", "org.kde.kwin.Scripting.unloadScript", "string:\(plugin)")
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return }
            defer { unlink(path) } // run replies once KWin has read the file
            let source = Array(kwinHelper(pid: pid, plugin: plugin).utf8)
            let written = source.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard written == source.count,
                  let reply = kwin("/Scripting", "org.kde.kwin.Scripting.loadScript", "string:\(path)", "string:\(plugin)"),
                  let id = String(decoding: reply, as: UTF8.self).split(whereSeparator: \.isWhitespace).last
                    .flatMap({ Int($0) }), id >= 0 else { return }
            // Plasma 6 puts the script at /Scripting/Script<id>, Plasma 5 at /<id>
            if kwin("/Scripting/Script\(id)", "org.kde.kwin.Script.run") == nil,
               kwin("/\(id)", "org.kde.kwin.Script.run") == nil {
                _ = kwin("/Scripting", "org.kde.kwin.Scripting.unloadScript", "string:\(plugin)")
            }
        }
    }

    private static func kwin(_ path: String, _ method: String, _ args: String...) -> Data? {
        output(of: ["dbus-send", "--session", "--print-reply", "--reply-timeout=5000", "--dest=org.kde.KWin",
                    path, method] + args)
    }

    // KWin reports a new frame before it applies a fullscreen, maximized or tiled state, so the
    // check waits for KWin's event loop; then a frame that grew past the work area of the screen
    // it was on moves back inside, unless the user had parked it across an edge
    private static func kwinHelper(pid: Int32, plugin: String) -> String {
        """
        // loaded by nsxiv-mac for the window of process \(pid); it unloads itself with the window
        const pid = \(pid), plugin = "\(plugin)";
        let tracked = null;

        function rect(r) { return { x: r.x, y: r.y, width: r.width, height: r.height }; }
        function inside(r, a) {
            return r.x >= a.x && r.y >= a.y && r.x + r.width <= a.x + a.width && r.y + r.height <= a.y + a.height;
        }
        function unload() {
            callDBus("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript", plugin);
        }
        // the work area of the screen the frame was on: an output on Plasma 6, a number on Plasma 5
        function areaAround(r, w) {
            const output = workspace.screenAt({ x: r.x + r.width / 2, y: r.y + r.height / 2 });
            const found = typeof output === "number" ? output >= 0 : !!output;
            return found ? workspace.clientArea(KWin.MaximizeArea, output, workspace.currentDesktop)
                         : workspace.clientArea(KWin.MaximizeArea, w);
        }

        // fullscreen, maximized or tiled: KWin, not the viewer, sizes the window
        function held(w, r) {
            if (w.fullScreen || w.tile) return true;
            if (w.maximizeMode !== undefined) return w.maximizeMode !== 0;
            const a = workspace.clientArea(KWin.MaximizeArea, w);
            return r.x === a.x && r.y === a.y && r.width === a.width && r.height === a.height;
        }

        // the viewer has one window; Plasma 5 gives resourceClass as bytes, so the pid alone picks it
        function track(w) {
            if (tracked !== null || w.pid !== pid) return;
            tracked = w;
            let last = rect(w.frameGeometry), before = null;
            const check = new QTimer();
            check.singleShot = true;
            check.interval = 0;
            w.frameGeometryChanged.connect(function () {
                if (before === null) before = last;
                check.start();
            });
            check.timeout.connect(function () {
                const old = before, now = rect(w.frameGeometry);
                before = null;
                // last keeps the frame from before KWin took over, so a restore compares with it
                if (w.deleted || held(w, now)) return;
                last = now;
                if (w.minimized || w.move || w.resize) return;
                if (now.width === old.width && now.height === old.height) return;
                const area = areaAround(old, w);
                if (!inside(old, area) || inside(now, area)) return;
                last = {
                    x: Math.max(area.x, Math.min(now.x, area.x + area.width - now.width)),
                    y: Math.max(area.y, Math.min(now.y, area.y + area.height - now.height)),
                    width: now.width,
                    height: now.height,
                };
                w.frameGeometry = last;
            });
        }

        (workspace.windowList ? workspace.windowList() : workspace.clientList()).forEach(track);
        (workspace.windowAdded || workspace.clientAdded).connect(track);
        (workspace.windowRemoved || workspace.clientRemoved).connect(function (w) {
            if (w === tracked) unload();
        });
        const giveUp = new QTimer(); // a viewer that never shows its window
        giveUp.singleShot = true;
        giveUp.interval = 60000;
        giveUp.timeout.connect(function () { if (tracked === null) unload(); });
        giveUp.start();
        """
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

    private static let decorationListener = make(zxdg_toplevel_decoration_v1_listener(
        configure: { data, _, mode in
            let ui = WaylandUI.ui(data)
            let csd = mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE.rawValue
            guard csd != ui.csd else { return }
            ui.csd = csd
            ui.fitWindow() // the title bar takes rows from the image
            ui.layoutChanged()
        }))

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
        l.leave = { data, _, _, _ in
            let ui = WaylandUI.ui(data)
            ui.dragging = false
            ui.pointerSerial = 0 // the cursor is the compositor's until the next enter
        }
        l.motion = { data, _, _, x, y in
            WaylandUI.ui(data).pointerMoved(to: CGPoint(x: wl_fixed_to_double(x), y: wl_fixed_to_double(y)))
        }
        l.button = { data, _, serial, time, button, state in
            WaylandUI.ui(data).button(button, pressed: state == WL_POINTER_BUTTON_STATE_PRESSED.rawValue,
                                      time: time, serial: serial)
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
