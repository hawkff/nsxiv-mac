import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: Options
    private var files: [FileEntry]
    private var current = 0
    private var alternate = 0

    private var window: NSWindow!
    private var canvas: ImageCanvasView!
    private var grid: ThumbnailGridView!
    private var bar: StatusBarView!
    private var contentStack: NSView!
    private var thumbnailMode = false
    private var barVisible = true

    private var image: LoadedImage?
    private var frameIndex = 0
    private var animationTimer: Timer?
    private var animationPlaying = false

    private var slideshowTimer: Timer?
    private var slideshowDelay: TimeInterval

    private var rotation = 0 // degrees, multiples of 90
    private var flipH = false
    private var flipV = false
    private var gamma = 0
    private var contrast = 0

    private var fileWatcher: DispatchSourceFileSystemObject?
    private let thumbCache: ThumbnailCache
    private var prefixExternal = false
    private var editor: EditController?

    init(options: Options, files: [FileEntry]) {
        self.options = options
        self.files = files
        self.slideshowDelay = options.slideshow ?? Config.slideshowDelay
        self.thumbCache = ThumbnailCache(privateMode: options.privateMode)
        self.current = max(0, min(files.count - 1, options.startAt - 1))
        self.alternate = current
        super.init()
    }

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        thumbnailMode = options.thumbnailMode
        barVisible = !options.noBar
        if let mode = options.scaleMode { canvas.setScaleMode(mode) }

        updateLayout()
        if thumbnailMode {
            grid.select(current)
        } else {
            loadCurrent()
        }
        if options.fullscreen {
            window.toggleFullScreen(nil)
        }
        if let z = options.zoom {
            canvas.setZoom(z)
        }
        if options.slideshow != nil, !thumbnailMode {
            startSlideshow()
        }

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
        printMarkedIfNeeded()
    }

    private func quit(_ code: Int32 = 0) {
        printMarkedIfNeeded()
        exit(code)
    }

    private var markedPrinted = false
    private func printMarkedIfNeeded() {
        guard options.outputMarked, !markedPrinted else { return }
        markedPrinted = true
        for f in files where f.marked {
            print(f.path)
        }
    }

    private func buildWindow() {
        let size = options.geometry ?? CGSize(width: Config.winWidth, height: Config.winHeight)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.delegate = self
        window.title = Config.appName
        window.tabbingMode = .disallowed
        window.center()

        contentStack = NSView()
        canvas = ImageCanvasView()
        grid = ThumbnailGridView()
        bar = StatusBarView()
        for v in [canvas!, grid!, bar!] {
            v.translatesAutoresizingMaskIntoConstraints = true
            contentStack.addSubview(v)
        }
        grid.cache = thumbCache
        grid.files = files

        canvas.onNavigate = { [weak self] d in self?.navigate(d) }
        canvas.onSwitchMode = { [weak self] in self?.switchMode() }
        canvas.onViewChange = { [weak self] in self?.updateBar() }
        grid.onOpen = { [weak self] i in
            guard let self else { return }
            self.setCurrent(i)
            self.switchMode()
        }
        grid.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.current = self.grid.selection
            self.updateBar()
        }
        grid.onToggleMark = { [weak self] i in self?.toggleMark(at: i) }

        window.contentView = contentStack
        TitleBar.install(in: window)
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

    private func updateLayout() {
        guard let content = window.contentView else { return }
        let b = content.bounds
        let barH = barVisible ? Config.barHeight : 0
        bar.isHidden = !barVisible
        bar.frame = CGRect(x: 0, y: 0, width: b.width, height: barH)
        let mainRect = CGRect(x: 0, y: barH, width: b.width, height: b.height - barH)
        canvas.frame = mainRect
        grid.frame = mainRect
        editor?.canvas.frame = mainRect
        let editing = editor != nil
        canvas.isHidden = thumbnailMode || editing
        grid.isHidden = !thumbnailMode || editing
        updateBar()
    }

    // MARK: - image loading

    private func setCurrent(_ index: Int) {
        guard files.indices.contains(index) else { return }
        if index != current { alternate = current }
        current = index
        if thumbnailMode { updateBar() } else { loadCurrent() }
        grid.select(current)
    }

    private func loadCurrent() {
        stopAnimation()
        rotation = 0
        flipH = false
        flipV = false
        guard files.indices.contains(current) else {
            canvas.errorText = "no images"
            canvas.setImage(nil, resetView: true)
            updateBar()
            return
        }
        let entry = files[current]
        image = LoadedImage(url: entry.url)
        frameIndex = 0
        if let image {
            canvas.errorText = nil
            canvas.setImage(processedFrame(), resetView: true)
            if image.isAnimated { startAnimation() }
        } else {
            canvas.errorText = "could not load: \(entry.url.lastPathComponent)"
            canvas.setImage(nil, resetView: true)
        }
        watchCurrent()
        window.title = entry.url.lastPathComponent
        window.representedURL = entry.url
        updateBar()
    }

    private func reloadCurrent(keepView: Bool = true) {
        stopAnimation()
        guard files.indices.contains(current) else { return }
        image = LoadedImage(url: files[current].url)
        frameIndex = 0
        canvas.errorText = image == nil
            ? "could not load: \(files[current].url.lastPathComponent)" : nil
        canvas.setImage(processedFrame(), resetView: !keepView)
        if image?.isAnimated == true { startAnimation() }
        thumbCache.invalidate(files[current])
        updateBar()
    }

    // MARK: - frame processing (rotate/flip/gamma/contrast)

    private func processedFrame() -> CGImage? {
        guard let raw = image?.frame(frameIndex) else { return nil }
        var img = raw
        if let adjusted = applyColorCorrection(img) { img = adjusted }
        if rotation != 0 || flipH || flipV {
            img = applyTransform(img)
        }
        return img
    }

    private func applyColorCorrection(_ img: CGImage) -> CGImage? {
        guard gamma != 0 || contrast != 0 else { return nil }
        let ci = CIImage(cgImage: img)
        var out = ci
        if gamma != 0 {
            let g = gammaValue()
            if let f = CIFilter(name: "CIGammaAdjust") {
                f.setValue(out, forKey: kCIInputImageKey)
                f.setValue(1 / g, forKey: "inputPower")
                out = f.outputImage ?? out
            }
        }
        if contrast != 0 {
            let c = contrastValue()
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(out, forKey: kCIInputImageKey)
                f.setValue(c, forKey: kCIInputContrastKey)
                out = f.outputImage ?? out
            }
        }
        let ctx = CIContext()
        return ctx.createCGImage(out, from: CGRect(x: 0, y: 0,
                                                   width: img.width, height: img.height))
    }

    private func gammaValue() -> Double {
        let steps = Double(Config.ccSteps)
        return gamma <= 0
            ? (steps + Double(gamma)) / steps
            : 1 + Double(gamma) * (Config.gammaMax - 1) / steps
    }

    private func contrastValue() -> Double {
        let steps = Double(Config.ccSteps)
        return contrast <= 0
            ? (steps + Double(contrast)) / steps
            : 1 + Double(contrast) * (Config.contrastMax - 1) / steps
    }

    private func applyTransform(_ img: CGImage) -> CGImage {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let swapped = rotation % 180 != 0
        let outW = swapped ? h : w, outH = swapped ? w : h
        guard let ctx = CGContext.rgba(width: Int(outW), height: Int(outH)) else { return img }
        ctx.translateBy(x: outW / 2, y: outH / 2)
        // screen-space rotation: CG y-axis points up, so negate for clockwise
        ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    private func redrawFrame(keepView: Bool = true) {
        canvas.setImage(processedFrame(), resetView: !keepView)
    }

    // MARK: - animation

    private func startAnimation() {
        guard let image, image.isAnimated else { return }
        animationPlaying = true
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        guard animationPlaying, let image else { return }
        let delay = image.delays[frameIndex % image.delays.count]
        animationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let img = self.image else { return }
            self.frameIndex = (self.frameIndex + 1) % img.frameCount
            self.redrawFrame()
            self.scheduleNextFrame()
        }
    }

    private func stopAnimation() {
        animationPlaying = false
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func toggleAnimation() {
        if animationPlaying {
            stopAnimation()
        } else {
            startAnimation()
        }
        updateBar()
    }

    private func navigateFrame(_ d: Int) {
        guard let image, image.frameCount > 1 else { return }
        stopAnimation()
        frameIndex = (frameIndex + d + image.frameCount) % image.frameCount
        redrawFrame()
        updateBar()
    }

    // MARK: - slideshow

    private var slideshowActive: Bool { slideshowTimer != nil }

    private func startSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: slideshowDelay,
                                              repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.current + 1 < self.files.count {
                self.setCurrent(self.current + 1)
            } else {
                self.setCurrent(0) // wrap like nsxiv
            }
        }
        updateBar()
    }

    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        updateBar()
    }

    private func toggleSlideshow() {
        slideshowActive ? stopSlideshow() : startSlideshow()
    }

    private func adjustSlideshowDelay(_ d: TimeInterval) {
        slideshowDelay = max(1, min(600, slideshowDelay + d))
        if slideshowActive { startSlideshow() }
        updateBar()
    }

    // MARK: - auto-reload (FSEvents-style watcher; macOS equivalent of inotify)

    private func watchCurrent() {
        fileWatcher?.cancel()
        fileWatcher = nil
        guard files.indices.contains(current) else { return }
        let fd = open(files[current].path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // wait for the file to reappear (atomic save), then reload
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.files.indices.contains(self.current) else { return }
                    if FileManager.default.fileExists(atPath: self.files[self.current].path) {
                        self.reloadCurrent()
                        self.watchCurrent()
                    }
                }
            } else {
                self.reloadCurrent()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }

    // MARK: - navigation

    private func navigate(_ d: Int) {
        guard !files.isEmpty else { return }
        let n = current + d
        guard files.indices.contains(n) else {
            NSSound.beep()
            return
        }
        setCurrent(n)
    }

    private func navigateMarked(_ d: Int) {
        guard !files.isEmpty else { return }
        var i = current + d
        while files.indices.contains(i) {
            if files[i].marked {
                setCurrent(i)
                return
            }
            i += d
        }
        NSSound.beep()
    }

    private func switchMode() {
        thumbnailMode.toggle()
        if thumbnailMode {
            stopSlideshow()
            stopAnimation()
            grid.files = files
            grid.select(current)
        } else {
            setCurrent(grid.selection)
            loadCurrent()
        }
        updateLayout()
    }

    // MARK: - marks

    private func toggleMark(at index: Int) {
        guard files.indices.contains(index) else { return }
        files[index].marked.toggle()
        syncMarks()
    }

    private var lastMarked = 0
    private func markRange() {
        guard files.indices.contains(lastMarked), files.indices.contains(current) else { return }
        let lo = min(lastMarked, current), hi = max(lastMarked, current)
        let state = files[lastMarked].marked
        for i in lo...hi {
            files[i].marked = state
        }
        syncMarks()
    }

    private func reverseMarks() {
        for i in files.indices {
            files[i].marked.toggle()
        }
        syncMarks()
    }

    private func unmarkAll() {
        for i in files.indices {
            files[i].marked = false
        }
        syncMarks()
    }

    private func syncMarks() {
        grid.files = files
        grid.select(current)
        updateBar()
    }

    // MARK: - file removal

    private func removeCurrentFromList() {
        guard files.indices.contains(current) else { return }
        files.remove(at: current)
        if files.isEmpty {
            quit()
        }
        current = min(current, files.count - 1)
        alternate = min(alternate, files.count - 1)
        lastMarked = min(lastMarked, files.count - 1)
        grid.files = files
        grid.select(current)
        if !thumbnailMode { loadCurrent() }
        updateBar()
    }

    // MARK: - external key-handler (like nsxiv's ~/.config/nsxiv/exec/key-handler)

    private var keyHandlerPath: String {
        let cfg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() + "/.config")
        return cfg + "/\(Config.appName)/exec/key-handler"
    }

    private func runKeyHandler(key: String) {
        let handler = keyHandlerPath
        guard FileManager.default.isExecutableFile(atPath: handler) else {
            warn("no executable key-handler at \(handler)")
            return
        }
        let targets = files.contains(where: { $0.marked })
            ? files.filter(\.marked).map(\.path)
            : (files.indices.contains(current) ? [files[current].path] : [])
        guard !targets.isEmpty else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: handler)
        proc.arguments = [key]
        let pipe = Pipe()
        proc.standardInput = pipe
        do {
            try proc.run()
        } catch {
            warn("key-handler failed: \(error.localizedDescription)")
            return
        }
        let data = Data((targets.joined(separator: "\n") + "\n").utf8)
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        reloadCurrent()
        updateBar()
    }

    // MARK: - edit mode

    private func enterEditMode() {
        guard editor == nil, !thumbnailMode,
              files.indices.contains(current),
              let frame = processedFrame() else {
            NSSound.beep()
            return
        }
        stopSlideshow()
        stopAnimation()
        let ed = EditController(base: frame, sourceURL: files[current].url) { [weak self] in
            self?.updateBar()
        }
        editor = ed
        // below the title bar overlay, above the image canvas
        window.contentView?.addSubview(ed.canvas, positioned: .above, relativeTo: canvas)
        updateLayout()
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
        if let savedURL {
            // insert the edited copy right after the current image
            let insertAt = min(current + 1, files.count)
            files.insert(FileEntry(path: savedURL.path), at: insertAt)
            grid.files = files
            setCurrent(insertAt)
        }
        updateLayout()
    }

    // MARK: - status bar

    private func updateBar() {
        guard bar != nil else { return }
        if let ed = editor {
            bar.leftText = ed.flashText ?? ed.statusText
            bar.rightText = files.indices.contains(current)
                ? files[current].url.lastPathComponent : ""
            return
        }
        guard files.indices.contains(current) else {
            bar.leftText = ""
            bar.rightText = "0/0"
            return
        }
        let entry = files[current]
        var right = ""
        if slideshowActive {
            right += String(format: "%gs | ", slideshowDelay)
        }
        if gamma != 0 { right += "G\(gamma > 0 ? "+" : "")\(gamma) | " }
        if contrast != 0 { right += "C\(contrast > 0 ? "+" : "")\(contrast) | " }
        let markCount = files.filter(\.marked).count
        if markCount > 0 { right += "*\(markCount) | " }
        if files[current].marked { right += "* | " }

        if thumbnailMode {
            right += "\(current + 1)/\(files.count)"
            bar.leftText = entry.url.lastPathComponent
        } else {
            if let image {
                if image.isAnimated {
                    right += "\(animationPlaying ? "▶" : "⏸")[\(frameIndex + 1)/\(image.frameCount)] | "
                }
                right += "\(Int(image.size.width))x\(Int(image.size.height)) | "
                right += "\(Int((canvas.zoom * 100).rounded()))% | "
            }
            right += "\(current + 1)/\(files.count)"
            bar.leftText = entry.url.lastPathComponent
        }
        bar.rightText = right
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
            let flags = event.modifierFlags.intersection([.command])
            if flags.contains(.command),
               !"zsc".contains(event.charactersIgnoringModifiers ?? "") {
                return false // let menu shortcuts (cmd-q etc.) through
            }
            if let exit = ed.handleKey(event) {
                exitEditMode(save: exit == .save)
            }
            return true
        }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = chars
        let ctrl = flags.contains(.control)
        let cmd = flags.contains(.command)
        let special = event.specialKey

        // cmd shortcuts pass through to the menu (cmd-q etc.)
        if cmd { return false }

        if prefixExternal {
            prefixExternal = false
            if special == nil || special == .carriageReturn {
                var name = key
                if ctrl { name = "C-" + name }
                runKeyHandler(key: name)
                return true
            }
            return true
        }

        // global mappings (both modes)
        if ctrl {
            switch key {
            case "x":
                prefixExternal = true
                return true
            case "h": scrollScreenOrPage(.left); return true
            case "j": scrollScreenOrPage(.down); return true
            case "k": scrollScreenOrPage(.up); return true
            case "l": scrollScreenOrPage(.right); return true
            case "m": reverseMarks(); return true
            case "u": unmarkAll(); return true
            case "g": gamma = 0; reloadColor(); return true
            case "n": navigateFrame(+1); return true
            case "p": navigateFrame(-1); return true
            case "a", " ": toggleAnimation(); return true
            case "6":
                let a = alternate
                setCurrent(a)
                return true
            case "]": contrast = min(Config.ccSteps, contrast + 1); reloadColor(); return true
            case "[": contrast = max(-Config.ccSteps + 1, contrast - 1); reloadColor(); return true
            default: break
            }
            if let special {
                switch special {
                case .leftArrow: scrollScreenOrPage(.left); return true
                case .rightArrow: scrollScreenOrPage(.right); return true
                case .upArrow: scrollScreenOrPage(.up); return true
                case .downArrow: scrollScreenOrPage(.down); return true
                default: break
                }
            }
            return false
        }

        if let special {
            switch special {
            case .carriageReturn: switchMode(); return true
            case .leftArrow: directional(.left); return true
            case .rightArrow: directional(.right); return true
            case .upArrow: directional(.up); return true
            case .downArrow: directional(.down); return true
            case .backspace, .delete: if !thumbnailMode { navigate(-1) }; return true
            default: break
            }
        }

        switch key {
        case "q": quit(); return true
        case "Q":
            // pick-quit: print current selection, exit 0 (nsxiv g_pick_quit)
            if files.indices.contains(current) { print(files[current].path) }
            markedPrinted = true
            exit(0)
        case "f": window.toggleFullScreen(nil); return true
        case "b": barVisible.toggle(); updateLayout(); return true
        case "g": setCurrent(0); return true
        case "G": setCurrent(files.count - 1); return true
        case "r": reloadCurrent(); return true
        case "R":
            if thumbnailMode {
                for f in files { thumbCache.invalidate(f) }
                grid.reloadAll()
            }
            return true
        case "D": removeCurrentFromList(); return true
        case "m":
            toggleMark(at: current)
            lastMarked = current
            if !thumbnailMode { navigate(1) }
            return true
        case "M": markRange(); return true
        case "N": navigateMarked(+1); return true
        case "P": navigateMarked(-1); return true
        case "{": gamma = max(-Config.ccSteps + 1, gamma - 1); reloadColor(); return true
        case "}": gamma = min(Config.ccSteps, gamma + 1); reloadColor(); return true
        case "(": contrast = max(-Config.ccSteps + 1, contrast - 1); reloadColor(); return true
        case ")": contrast = min(Config.ccSteps, contrast + 1); reloadColor(); return true
        case "+":
            thumbnailMode ? grid.zoomThumbs(+1) : canvas.zoomStep(+1)
            return true
        case "-":
            thumbnailMode ? grid.zoomThumbs(-1) : canvas.zoomStep(-1)
            return true
        default: break
        }

        if thumbnailMode {
            switch key {
            case "h": grid.moveSelection(.left); return true
            case "j": grid.moveSelection(.down); return true
            case "k": grid.moveSelection(.up); return true
            case "l": grid.moveSelection(.right); return true
            case " ", "\r": switchMode(); return true
            default: return false
            }
        }

        // image mode
        switch key {
        case "j": navigate(+1); return true
        case "k": navigate(-1); return true
        case " ": return true // disabled
        case "]": navigate(+10); return true
        case "[": navigate(-10); return true
        case "h": canvas.scrollStep(.left, screenful: false); return true
        case "l": canvas.scrollStep(.right, screenful: false); return true
        case "u": canvas.scrollStep(.up, screenful: false); return true
        case "d": canvas.scrollStep(.down, screenful: false); return true
        case "H": canvas.scrollToEdge(.left); return true
        case "J": canvas.scrollToEdge(.down); return true
        case "K": canvas.scrollToEdge(.up); return true
        case "L": canvas.scrollToEdge(.right); return true
        case "z": canvas.centerImage(); return true
        case "=": canvas.setZoom(1); return true
        case "w": canvas.setScaleMode(.down); return true
        case "W": canvas.setScaleMode(.fit); return true
        case "F": canvas.setScaleMode(.fill); return true
        case "e": canvas.setScaleMode(.width); return true
        case "E": canvas.setScaleMode(.height); return true
        case "<": rotation = (rotation + 270) % 360; redrawFrame(); return true
        case ">": rotation = (rotation + 90) % 360; redrawFrame(); return true
        case "?": rotation = (rotation + 180) % 360; redrawFrame(); return true
        case "|": flipH.toggle(); redrawFrame(); return true
        case "_": flipV.toggle(); redrawFrame(); return true
        case "a": canvas.antialias.toggle(); return true
        case "A": canvas.alphaLayer.toggle(); return true
        case "x": enterEditMode(); return true
        case "s": toggleSlideshow(); return true
        case "S": adjustSlideshowDelay(+1); return true
        default: return false
        }
    }

    private func reloadColor() {
        redrawFrame()
        updateBar()
    }

    private func scrollScreenOrPage(_ d: Direction) {
        if thumbnailMode {
            grid.scrollPage(d)
        } else {
            canvas.scrollStep(d, screenful: true)
        }
    }

    private func directional(_ d: Direction) {
        if thumbnailMode {
            grid.moveSelection(d)
        } else {
            canvas.scrollStep(d, screenful: false)
        }
    }
}
