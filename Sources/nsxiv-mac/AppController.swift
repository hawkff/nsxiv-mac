#if os(macOS)
import AppKit

// The AppKit side of the viewer: window, views, decoding through ImageIO, edit mode.
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, ViewerUI {
    let viewer: Viewer

    private var window: NSWindow!
    private var canvas: ImageCanvasView!
    private var grid: ThumbnailGridView!
    private var bar: StatusBarView!
    private var image: LoadedImage?
    private var editor: EditController?

    init(options: Options, files: [FileEntry]) {
        viewer = Viewer(options: options, files: files)
        super.init()
        viewer.ui = self
    }

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        viewer.start()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.editor?.keyUp(event)
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        viewer.printMarkedIfNeeded()
    }

    private func buildWindow() {
        let size = viewer.options.geometry ?? CGSize(width: Config.winWidth, height: Config.winHeight)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.delegate = self
        window.title = Config.appName
        window.tabbingMode = .disallowed
        window.center()

        let contentStack = NSView()
        canvas = ImageCanvasView()
        grid = ThumbnailGridView()
        bar = StatusBarView()
        for v in [canvas!, grid!, bar!] {
            v.translatesAutoresizingMaskIntoConstraints = true
            contentStack.addSubview(v)
        }
        canvas.viewer = viewer
        grid.viewer = viewer
        grid.cache = ThumbnailCache(privateMode: viewer.options.privateMode)

        window.contentView = contentStack
        TitleBar.install(in: window)
        if let geometry = viewer.options.geometry {
            window.setFrame(NSRect(origin: window.frame.origin, size: geometry), display: false)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(Config.appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(Config.appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = main
    }

    // MARK: - layout

    func windowDidResize(_ notification: Notification) {
        updateLayout()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fitWindow()
    }

    private func updateLayout() {
        guard let content = window.contentView else { return }
        let b = content.bounds
        let barH = viewer.barVisible ? Config.barHeight : 0
        bar.isHidden = !viewer.barVisible
        bar.frame = CGRect(x: 0, y: 0, width: b.width, height: barH)
        let mainRect = CGRect(x: 0, y: barH, width: b.width, height: b.height - barH)
        canvas.frame = mainRect
        grid.frame = mainRect
        editor?.canvas.frame = mainRect
        viewer.resizeCanvas(mainRect.size)
        viewer.resizeGrid(mainRect.size)
        let editing = editor != nil
        canvas.isHidden = viewer.thumbnailMode || editing
        grid.isHidden = !viewer.thumbnailMode || editing
        canvas.needsDisplay = true
        grid.needsDisplay = true
        barChanged()
    }

    // MARK: - window fitting (mpv's auto-window-resize and keepaspect-window)

    // the image the window fits and keeps the aspect of, in points; nil in the grid,
    // with -g, and in fullscreen
    private var fittedImageSize: CGSize? {
        window.styleMask.contains(.fullScreen) ? nil : viewer.fittedSize
    }

    // the content view fills the frame (fullSizeContentView), so frame math is content math
    func fitWindow() {
        guard let size = fittedImageSize, let screen = window.screen else { return }
        let barH = viewer.barVisible ? Config.barHeight : 0
        let avail = screen.visibleFrame
        let scale = min(1, avail.width / size.width, (avail.height - barH) / size.height)
        resize(to: CGSize(width: size.width * scale, height: size.height * scale + barH), on: screen)
    }

    func resetWindowSize() {
        guard !window.styleMask.contains(.fullScreen), viewer.options.geometry == nil,
              let screen = window.screen else { return }
        resize(to: CGSize(width: Config.winWidth, height: Config.winHeight), on: screen)
    }

    // keeps the window's center
    private func resize(to size: CGSize, on screen: NSScreen) {
        let old = window.frame
        let frame = CGRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                           width: size.width, height: size.height)
        window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let size = fittedImageSize else { return frameSize }
        let barH = viewer.barVisible ? Config.barHeight : 0
        let old = window.frame.size
        // an edge drag changes one dimension, which drives the other; corner drags and
        // zoom change both, and then the largest frame inside the proposal wins
        let byHeight = (frameSize.height - barH) * size.width / size.height
        let width = frameSize.width == old.width ? byHeight
            : frameSize.height == old.height ? frameSize.width
            : min(frameSize.width, byHeight)
        return NSSize(width: width, height: width * size.height / size.width + barH)
    }

    // MARK: - ViewerUI

    func loadImage(_ url: URL) -> ImageInfo? {
        image = LoadedImage(url: url)
        return image.map { ImageInfo(size: $0.size, delays: $0.delays) }
    }

    func imageChanged() {
        canvas.image = viewer.image == nil ? nil : processedFrame()
        canvas.errorText = viewer.errorText
        canvas.needsDisplay = true
        if let entry = viewer.currentEntry, window.representedURL != entry.url { // not on every frame
            window.title = entry.url.lastPathComponent
            window.representedURL = entry.url
        }
    }

    func viewChanged() { canvas.needsDisplay = true }
    func gridChanged() { grid.needsDisplay = true }
    func layoutChanged() { updateLayout() }
    func invalidateThumbnails(_ entries: [FileEntry]) { grid.invalidate(entries) }
    func toggleFullscreen() { window.toggleFullScreen(nil) }
    func beep() { NSSound.beep() }

    func barChanged() {
        guard bar != nil else { return }
        if let ed = editor {
            bar.leftText = ed.flashText ?? ed.statusText
            bar.rightText = viewer.currentEntry?.url.lastPathComponent ?? ""
        } else {
            let status = viewer.statusText
            bar.leftText = status.left
            bar.rightText = status.right
        }
    }

    // MARK: - frame processing (rotate/flip/gamma/contrast)

    private func processedFrame() -> CGImage? {
        guard let raw = image?.frame(viewer.frameIndex) else { return nil }
        var img = raw
        if let adjusted = applyColorCorrection(img) { img = adjusted }
        if viewer.rotation != 0 || viewer.flipH || viewer.flipV {
            img = Self.transform(img, rotation: viewer.rotation, flipH: viewer.flipH, flipV: viewer.flipV)
        }
        return img
    }

    private func applyColorCorrection(_ img: CGImage) -> CGImage? {
        guard viewer.gamma != 0 || viewer.contrast != 0 else { return nil }
        var out = CIImage(cgImage: img)
        if viewer.gamma != 0, let f = CIFilter(name: "CIGammaAdjust") {
            f.setValue(out, forKey: kCIInputImageKey)
            f.setValue(1 / viewer.gammaValue, forKey: "inputPower")
            out = f.outputImage ?? out
        }
        if viewer.contrast != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(out, forKey: kCIInputImageKey)
            f.setValue(viewer.contrastValue, forKey: kCIInputContrastKey)
            out = f.outputImage ?? out
        }
        return CIContext.shared.createCGImage(out, from: CGRect(x: 0, y: 0,
                                                                width: img.width, height: img.height))
    }

    // rotates clockwise, then flips the rotated image as it appears on screen
    static func transform(_ img: CGImage, rotation: Int, flipH: Bool, flipV: Bool) -> CGImage {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let swapped = rotation % 180 != 0
        let outW = swapped ? h : w, outH = swapped ? w : h
        guard let ctx = CGContext.rgba(width: Int(outW), height: Int(outH)) else { return img }
        ctx.translateBy(x: outW / 2, y: outH / 2)
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        // CG's y-axis points up, so a clockwise turn is a negative angle
        ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    // MARK: - edit mode

    func enterEditMode() -> Bool {
        guard editor == nil, let entry = viewer.currentEntry, let frame = processedFrame() else { return false }
        let ed = EditController(base: frame, sourceURL: entry.url) { [weak self] in
            self?.barChanged()
        }
        editor = ed
        // below the title bar overlay, above the image canvas
        window.contentView?.addSubview(ed.canvas, positioned: .above, relativeTo: canvas)
        updateLayout()
        return true
    }

    private func exitEditMode(save: Bool) {
        guard let ed = editor else { return }
        ed.endTextEdit(commit: true)
        var savedURL: URL?
        if save {
            savedURL = ed.save()
            if savedURL == nil {
                NSSound.beep()
                return // stay in edit mode rather than lose work
            }
        }
        ed.canvas.removeFromSuperview()
        editor = nil
        if let savedURL { viewer.insertAfterCurrent(savedURL.path) }
        updateLayout()
    }

    // MARK: - key handling

    private func handleKey(_ event: NSEvent) -> Bool {
        if let ed = editor {
            if ed.isEditingText {
                if event.keyCode == 53 { // escape commits the text
                    _ = ed.handleKey(event)
                    return true
                }
                return false // let the text field receive keystrokes
            }
            if event.modifierFlags.contains(.command),
               !["z", "s", "c"].contains(event.charactersIgnoringModifiers?.lowercased()) {
                return false // let menu shortcuts (cmd-q etc.) through
            }
            if let exit = ed.handleKey(event) {
                exitEditMode(save: exit == .save)
            }
            return true
        }
        // cmd shortcuts pass through to the menu (cmd-q etc.)
        guard !event.modifierFlags.contains(.command), let key = Self.keyName(event) else { return false }
        // a held key outruns large decodes; a repeat that waited in the queue is dropped
        if event.isARepeat, ProcessInfo.processInfo.systemUptime - event.timestamp > 0.1 { return true }
        return viewer.handle(Keystroke(key: key, ctrl: event.modifierFlags.contains(.control)))
    }

    // the typed text, or nsxiv's name for a key without one
    private static func keyName(_ event: NSEvent) -> String? {
        if event.keyCode == 53 { return "Escape" }
        switch event.specialKey {
        case .carriageReturn?: return "Return"
        case .leftArrow?: return "Left"
        case .rightArrow?: return "Right"
        case .upArrow?: return "Up"
        case .downArrow?: return "Down"
        case .backspace?, .delete?: return "BackSpace"
        case nil:
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            return chars
        default: return nil
        }
    }
}
#endif
