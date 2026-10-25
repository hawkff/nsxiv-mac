import Foundation

// A key as the bindings see it: the typed text ("j", "G", "?"), or nsxiv's X keysym
// name for a key without text ("Return", "Left", "BackSpace").
struct Keystroke {
    var key: String
    var ctrl = false
}

struct ImageInfo {
    let size: CGSize // oriented pixel size of the first frame
    let delays: [TimeInterval] // one per frame
    var frameCount: Int { delays.count }
    var isAnimated: Bool { delays.count > 1 }
}

// What the viewer asks of a windowing system. AppController (AppKit) and X11UI implement it.
protocol ViewerUI: AnyObject {
    // decodes the file and keeps its frames; nil when it cannot be read
    func loadImage(_ url: URL) -> ImageInfo?
    // a new image or error, or another frame, rotation, flip, gamma or contrast
    func imageChanged()
    // zoom, pan, antialiasing or the alpha layer
    func viewChanged()
    // files, marks, the selection or the grid layout
    func gridChanged()
    func barChanged()
    // the mode or the visibility of the bar
    func layoutChanged()
    func invalidateThumbnails(_ entries: [FileEntry])
    // sizes the window to viewer.fittedSize, unless it is fullscreen
    func fitWindow()
    // the starting window size for the grid, unless -g fixed it or the window is fullscreen
    func resetWindowSize()
    func toggleFullscreen()
    func beep()
    // false where edit mode does not exist
    func enterEditMode() -> Bool
}

// The image list, marks, modes and key bindings, shared by both windowing systems.
final class Viewer {
    let options: Options
    weak var ui: ViewerUI?

    private(set) var files: [FileEntry]
    private(set) var current = 0
    private var alternate = 0
    // anchor of M: the image marked or unmarked last, as in nsxiv
    private var lastMarked = 0
    // counted when marks change, not on every animation frame
    private(set) var markCount = 0
    private(set) var thumbnailMode: Bool
    private(set) var barVisible: Bool

    private(set) var image: ImageInfo?
    private(set) var errorText: String?
    private(set) var frameIndex = 0
    private(set) var animationPlaying = false
    private(set) var rotation = 0 // degrees clockwise, multiples of 90
    private(set) var flipH = false
    private(set) var flipV = false
    private(set) var gamma = 0
    private(set) var contrast = 0

    private(set) var viewport = Viewport()
    private(set) var grid = GridLayout()

    private var animationTimer: DispatchWorkItem?
    private var slideshowTimer: DispatchSourceTimer?
    private var slideshowDelay: TimeInterval
    private var prefixExternal = false
    private var watcher: FileWatcher?
    private var pendingReload: DispatchWorkItem?
    private var markedPrinted = false

    init(options: Options, files: [FileEntry]) {
        self.options = options
        self.files = files
        slideshowDelay = options.slideshow ?? Config.slideshowDelay
        current = max(0, min(files.count - 1, options.startAt - 1))
        alternate = current
        thumbnailMode = options.thumbnailMode
        barVisible = !options.noBar
        grid.count = files.count
        if let mode = options.scaleMode { viewport.setScaleMode(mode) }
    }

    // once the window exists
    func start() {
        ui?.layoutChanged()
        if thumbnailMode {
            grid.reveal(current)
            ui?.gridChanged()
        } else {
            loadCurrent()
        }
        if options.fullscreen { ui?.toggleFullscreen() }
        if let z = options.zoom { changeView { $0.setZoom(z) } }
        if options.slideshow != nil, !thumbnailMode { startSlideshow() }
        ui?.barChanged()
    }

    // MARK: - state the windowing systems draw

    var currentEntry: FileEntry? { files.indices.contains(current) ? files[current] : nil }

    // the image's pixels as shown, rotation applied
    var displaySize: CGSize? {
        guard let s = image?.size else { return nil }
        return rotation % 180 == 0 ? s : CGSize(width: s.height, height: s.width)
    }

    // the image the window follows, keeping its aspect; nil in the grid or when -g fixed the size
    var fittedSize: CGSize? { options.geometry == nil && !thumbnailMode ? displaySize : nil }

    // 1 is neutral; the top step reaches Config.gammaMax or Config.contrastMax
    var gammaValue: Double { Self.colorValue(gamma, max: Config.gammaMax) }
    var contrastValue: Double { Self.colorValue(contrast, max: Config.contrastMax) }

    private static func colorValue(_ step: Int, max: Double) -> Double {
        let steps = Double(Config.ccSteps)
        return step <= 0 ? (steps + Double(step)) / steps : 1 + Double(step) * (max - 1) / steps
    }

    var statusText: (left: String, right: String) {
        guard let entry = currentEntry else { return ("", "0/0") }
        var right = ""
        if slideshowTimer != nil { right += String(format: "%gs | ", slideshowDelay) }
        if gamma != 0 { right += "G\(gamma > 0 ? "+" : "")\(gamma) | " }
        if contrast != 0 { right += "C\(contrast > 0 ? "+" : "")\(contrast) | " }
        if markCount > 0 { right += "*\(markCount) | " }
        if entry.marked { right += "* | " }
        if !thumbnailMode, let image {
            if image.isAnimated {
                right += "\(animationPlaying ? "▶" : "⏸")[\(frameIndex + 1)/\(image.frameCount)] | "
            }
            right += "\(Int(image.size.width))x\(Int(image.size.height)) | "
            right += "\(Int((viewport.zoom * 100).rounded()))% | "
        }
        right += "\(current + 1)/\(files.count)"
        return (entry.url.lastPathComponent, right)
    }

    // How far a window with edges at 0 and extent may grow inside the room lo...hi around it,
    // where it cannot move itself. A window whose compositor keeps its top-left corner needs
    // the room after it; one that keeps its center, half the growth on each side; where that is
    // unknown, growth must suit both. A window already reaching outside the room, as a user may
    // park it, grows freely on that axis.
    static func grownLimit(_ extent: Int, room lo: CGFloat, _ hi: CGFloat, keepsTopLeft: Bool) -> Int {
        guard lo <= 0, hi >= CGFloat(extent) else { return .max }
        let after = hi - CGFloat(extent), before = -lo
        let growth = keepsTopLeft ? after : min(after, 2 * before)
        return extent + Int(growth.rounded(.down))
    }

    // the status bar's right part in a bar too narrow for it: whole " | " fields drop from the
    // front, so the index, rightmost, stays longest
    static func fittedStatus(_ right: String, room: CGFloat, width: (String) -> CGFloat) -> String {
        var fields = Substring(right)
        while width(String(fields)) > room, let cut = fields.range(of: " | ") {
            fields = fields[cut.upperBound...]
        }
        return String(fields)
    }

    // MARK: - window and mouse events

    func resizeCanvas(_ size: CGSize) {
        viewport.viewSize = size
        ui?.barChanged() // the zoom of a fit mode changes with the window
    }

    func resizeGrid(_ size: CGSize) {
        grid.viewSize = size
        grid.reveal(current) // the column count changes with the width
    }

    func pan(dx: CGFloat, dy: CGFloat) { changeView { $0.scroll(dx: dx, dy: dy) } }
    func zoom(to z: CGFloat, anchor: CGPoint) { changeView { $0.setZoom(z, anchor: anchor) } }
    func zoomStep(_ dir: Int) { changeView { $0.zoomStep(dir) } }

    func scrollGrid(by dy: CGFloat) {
        grid.scroll(by: dy)
        ui?.gridChanged()
    }

    // a click in the grid
    func select(_ index: Int) {
        guard files.indices.contains(index) else { return }
        current = index
        grid.reveal(current)
        ui?.gridChanged()
        ui?.barChanged()
    }

    // a double click in the grid
    func open(_ index: Int) {
        setCurrent(index)
        switchMode()
    }

    // a saved edit: the copy goes right after the image it came from
    func insertAfterCurrent(_ path: String) {
        let at = min(current + 1, files.count)
        files.insert(FileEntry(path: path), at: at)
        if lastMarked >= at { lastMarked += 1 }
        grid.count = files.count
        setCurrent(at)
    }

    // -o: marked files go to stdout once, whichever way the viewer exits
    func printMarkedIfNeeded() {
        guard options.outputMarked, !markedPrinted else { return }
        markedPrinted = true
        for f in files where f.marked {
            print(f.path)
        }
    }

    func quit() -> Never {
        printMarkedIfNeeded()
        exit(0)
    }

    // MARK: - image loading

    private func setCurrent(_ index: Int) {
        guard files.indices.contains(index) else { return }
        if index != current { alternate = current }
        current = index
        grid.reveal(current)
        if thumbnailMode {
            ui?.gridChanged()
            ui?.barChanged()
        } else {
            loadCurrent()
        }
    }

    private func loadCurrent() {
        stopAnimation()
        rotation = 0
        flipH = false
        flipV = false
        frameIndex = 0
        if let entry = currentEntry {
            image = ui?.loadImage(entry.url)
            errorText = image == nil ? "could not load: \(entry.url.lastPathComponent)" : nil
            watchCurrent()
        } else {
            image = nil
            errorText = "no images"
        }
        ui?.fitWindow()
        viewport.setImageSize(displaySize ?? .zero, resetView: true)
        ui?.imageChanged()
        ui?.viewChanged()
        if image?.isAnimated == true { startAnimation() }
        ui?.barChanged()
    }

    // r, a changed file, the key-handler: a fresh thumbnail, and in image mode a fresh image
    func reloadCurrent() {
        guard let entry = currentEntry else { return }
        ui?.invalidateThumbnails([entry])
        guard !thumbnailMode else { return }
        stopAnimation()
        let oldSize = viewport.imageSize
        image = ui?.loadImage(entry.url)
        frameIndex = 0
        errorText = image == nil ? "could not load: \(entry.url.lastPathComponent)" : nil
        // a fit mode fits a file whose size changed, say one a key-handler turned
        let size = displaySize ?? .zero
        viewport.setImageSize(size, resetView: size != oldSize && viewport.scaleMode != .manual)
        ui?.imageChanged()
        ui?.viewChanged()
        ui?.fitWindow()
        if image?.isAnimated == true { startAnimation() }
        ui?.barChanged()
    }

    // after another frame, flip, gamma or contrast
    private func showFrame() {
        viewport.setImageSize(displaySize ?? .zero, resetView: false)
        ui?.imageChanged()
        ui?.viewChanged()
    }

    private func changeView(_ change: (inout Viewport) -> Void) {
        change(&viewport)
        ui?.viewChanged()
        ui?.barChanged()
    }

    private func colorChanged() {
        showFrame()
        ui?.barChanged()
    }

    private func rotate(_ degrees: Int) {
        guard let size = image?.size else { return }
        // under one flip a clockwise turn on screen is counterclockwise before the flip;
        // two flips make a half turn and keep the direction
        rotation = (rotation + (flipH == flipV ? degrees : 360 - degrees)) % 360
        // a fit mode fits the turned image again, as nsxiv does
        let turned = rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        viewport.setImageSize(turned, resetView: viewport.scaleMode != .manual)
        ui?.imageChanged()
        ui?.viewChanged()
        ui?.fitWindow()
        ui?.barChanged()
    }

    // MARK: - animation

    private func startAnimation() {
        guard image?.isAnimated == true else { return }
        animationPlaying = true
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        guard animationPlaying, let image else { return }
        let next = DispatchWorkItem { [weak self] in
            guard let self, let image = self.image else { return }
            self.frameIndex = (self.frameIndex + 1) % image.frameCount
            self.showFrame()
            self.ui?.barChanged()
            self.scheduleNextFrame()
        }
        animationTimer = next
        DispatchQueue.main.asyncAfter(deadline: .now() + image.delays[frameIndex % image.frameCount],
                                      execute: next)
    }

    private func stopAnimation() {
        animationPlaying = false
        animationTimer?.cancel()
        animationTimer = nil
    }

    private func toggleAnimation() {
        if animationPlaying {
            stopAnimation()
        } else {
            startAnimation()
        }
        ui?.barChanged()
    }

    private func navigateFrame(_ d: Int) {
        guard let image, image.frameCount > 1 else { return }
        stopAnimation()
        frameIndex = (frameIndex + d + image.frameCount) % image.frameCount
        showFrame()
        ui?.barChanged()
    }

    // MARK: - slideshow

    private func startSlideshow() {
        slideshowTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + slideshowDelay, repeating: slideshowDelay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.setCurrent(self.current + 1 < self.files.count ? self.current + 1 : 0) // wraps, like nsxiv
        }
        timer.resume()
        slideshowTimer = timer
        ui?.barChanged()
    }

    private func stopSlideshow() {
        slideshowTimer?.cancel()
        slideshowTimer = nil
        ui?.barChanged()
    }

    private func toggleSlideshow() {
        if slideshowTimer == nil { startSlideshow() } else { stopSlideshow() }
    }

    private func adjustSlideshowDelay(_ d: TimeInterval) {
        slideshowDelay = max(1, min(600, slideshowDelay + d))
        if slideshowTimer != nil { startSlideshow() }
        ui?.barChanged()
    }

    // MARK: - auto-reload

    private func watchCurrent() {
        pendingReload?.cancel()
        watcher = nil
        guard let path = currentEntry?.path else { return }
        watcher = FileWatcher(path: path) { [weak self] in self?.scheduleReload(of: path, attempts: 10) }
    }

    // editors write in chunks, or save a temp file and rename it over the original:
    // reload once the file has been quiet for 0.2 s, then watch the new inode
    private func scheduleReload(of path: String, attempts: Int) {
        pendingReload?.cancel()
        let reload = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: path) else {
                // a save that deletes before it writes leaves the path empty for a while
                if attempts > 1 { self.scheduleReload(of: path, attempts: attempts - 1) }
                return
            }
            self.ui?.invalidateThumbnails([FileEntry(path: path)])
            // the grid selection may have moved on since this file was opened
            guard self.currentEntry?.path == path else { return }
            self.reloadCurrent()
            self.watchCurrent()
        }
        pendingReload = reload
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: reload)
    }

    // MARK: - navigation

    func navigate(_ d: Int) {
        guard files.indices.contains(current + d) else {
            ui?.beep()
            return
        }
        setCurrent(current + d)
    }

    private func navigateMarked(_ d: Int) {
        var i = current + d
        while files.indices.contains(i) {
            if files[i].marked {
                setCurrent(i)
                return
            }
            i += d
        }
        ui?.beep()
    }

    func switchMode() {
        thumbnailMode.toggle()
        if thumbnailMode {
            stopSlideshow()
            stopAnimation()
            grid.reveal(current)
            ui?.gridChanged()
        } else {
            loadCurrent()
        }
        ui?.layoutChanged()
        // a window fitted to a small image would leave the grid one clipped column
        if thumbnailMode { ui?.resetWindowSize() }
    }

    private func moveSelection(_ d: Direction) {
        guard !files.isEmpty else { return }
        select(grid.neighbor(of: current, d))
    }

    // MARK: - marks

    func toggleMark(at index: Int) {
        guard files.indices.contains(index) else { return }
        files[index].marked.toggle()
        lastMarked = index
        syncMarks()
    }

    private func markRange() {
        guard files.indices.contains(lastMarked), files.indices.contains(current) else { return }
        let state = files[lastMarked].marked
        for i in min(lastMarked, current)...max(lastMarked, current) {
            files[i].marked = state
        }
        lastMarked = current
        syncMarks()
    }

    private func setAllMarks(_ mark: (Bool) -> Bool) {
        for i in files.indices {
            files[i].marked = mark(files[i].marked)
        }
        syncMarks()
    }

    private func syncMarks() {
        markCount = files.reduce(0) { $1.marked ? $0 + 1 : $0 }
        ui?.gridChanged()
        ui?.barChanged()
    }

    // MARK: - file removal

    // where index i lands once only the indices in `kept` stay: on its own file,
    // or on the next one that stays when its file went
    static func remap(_ i: Int, kept: [Int]) -> Int {
        kept.firstIndex { $0 >= i } ?? kept.count - 1
    }

    private func removeFiles(at removed: Set<Int>) {
        let kept = files.indices.filter { !removed.contains($0) }
        guard kept.count < files.count else { return }
        if kept.isEmpty {
            files.removeAll() // -o must not print what was just removed
            quit()
        }
        let currentRemoved = removed.contains(current)
        current = Self.remap(current, kept: kept)
        alternate = Self.remap(alternate, kept: kept)
        lastMarked = Self.remap(lastMarked, kept: kept)
        files = kept.map { files[$0] }
        grid.count = files.count
        grid.reveal(current)
        syncMarks()
        if currentRemoved, !thumbnailMode { loadCurrent() }
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
        let marked = files.indices.filter { files[$0].marked }
        let targets = marked.isEmpty ? (files.indices.contains(current) ? [current] : []) : marked
        guard !targets.isEmpty else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: handler)
        proc.arguments = [key]
        let pipe = Pipe()
        proc.standardInput = pipe
        // blocks like nsxiv; waitUntilExit would spin a nested run loop, and with it the
        // timers and X events queued on main
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do {
            try proc.run()
        } catch {
            warn("key-handler failed: \(error.localizedDescription)")
            return
        }
        // a handler may stop reading early; with SIGPIPE ignored the write fails instead
        try? pipe.fileHandleForWriting.write(contentsOf: Data(targets.map { files[$0].path + "\n" }.joined().utf8))
        try? pipe.fileHandleForWriting.close()
        exited.wait()
        // the handler may have edited, moved or deleted its files
        ui?.invalidateThumbnails(targets.map { files[$0] })
        let gone = targets.filter { !FileManager.default.fileExists(atPath: files[$0].path) }
        let currentGone = gone.contains(current)
        removeFiles(at: Set(gone))
        if !currentGone { reloadCurrent() }
    }

    private func enterEditMode() {
        guard !thumbnailMode, image != nil, ui?.enterEditMode() == true else {
            ui?.beep()
            return
        }
        stopSlideshow()
        stopAnimation()
    }

    // MARK: - key bindings

    // a key the viewer does not get, a menu shortcut or one without a name, still ends a C-x
    // prefix, without running the handler
    func endPrefix() { prefixExternal = false }

    // true when a binding took the key
    func handle(_ k: Keystroke) -> Bool {
        if prefixExternal {
            prefixExternal = false
            if k.key != "Escape" { runKeyHandler(key: (k.ctrl ? "C-" : "") + k.key) } // Escape aborts, as in nsxiv
            return true
        }
        if k.ctrl {
            switch k.key {
            case "x": prefixExternal = true
            case "h", "Left": scrollScreenOrPage(.left)
            case "j", "Down": scrollScreenOrPage(.down)
            case "k", "Up": scrollScreenOrPage(.up)
            case "l", "Right": scrollScreenOrPage(.right)
            case "m": setAllMarks { !$0 }
            case "u": setAllMarks { _ in false }
            case "g": gamma = 0; colorChanged()
            case "n": navigateFrame(+1)
            case "p": navigateFrame(-1)
            case "a", " ": toggleAnimation()
            case "6": setCurrent(alternate)
            case "]": contrast = min(Config.ccSteps, contrast + 1); colorChanged()
            case "[": contrast = max(-Config.ccSteps + 1, contrast - 1); colorChanged()
            default: return false
            }
            return true
        }

        switch k.key {
        case "Return": switchMode()
        case "Left": directional(.left)
        case "Right": directional(.right)
        case "Up": directional(.up)
        case "Down": directional(.down)
        case "BackSpace": if !thumbnailMode { navigate(-1) }
        case "q": quit()
        case "Q":
            // pick-quit: print the current file and exit (nsxiv g_pick_quit)
            if let entry = currentEntry { print(entry.path) }
            markedPrinted = true
            exit(0)
        case "f": ui?.toggleFullscreen()
        case "b":
            barVisible.toggle()
            ui?.layoutChanged()
            ui?.fitWindow()
        case "g": setCurrent(0)
        case "G": setCurrent(files.count - 1)
        case "r": reloadCurrent()
        case "R": if thumbnailMode { ui?.invalidateThumbnails(files) }
        case "D": removeFiles(at: [current])
        case "m":
            toggleMark(at: current)
            if !thumbnailMode { navigate(1) }
        case "M": markRange()
        case "N": navigateMarked(+1)
        case "P": navigateMarked(-1)
        case "{": gamma = max(-Config.ccSteps + 1, gamma - 1); colorChanged()
        case "}": gamma = min(Config.ccSteps, gamma + 1); colorChanged()
        case "(": contrast = max(-Config.ccSteps + 1, contrast - 1); colorChanged()
        case ")": contrast = min(Config.ccSteps, contrast + 1); colorChanged()
        case "+": zoomKey(+1)
        case "-": zoomKey(-1)
        default: return thumbnailMode ? handleGridKey(k.key) : handleImageKey(k.key)
        }
        return true
    }

    private func handleGridKey(_ key: String) -> Bool {
        switch key {
        case "h": moveSelection(.left)
        case "j": moveSelection(.down)
        case "k": moveSelection(.up)
        case "l": moveSelection(.right)
        case " ": switchMode()
        default: return false
        }
        return true
    }

    private func handleImageKey(_ key: String) -> Bool {
        switch key {
        case "j": navigate(+1)
        case "k": navigate(-1)
        case " ": break // disabled
        case "]": navigate(+10)
        case "[": navigate(-10)
        case "h": changeView { $0.scrollStep(.left, screenful: false) }
        case "l": changeView { $0.scrollStep(.right, screenful: false) }
        case "u": changeView { $0.scrollStep(.up, screenful: false) }
        case "d": changeView { $0.scrollStep(.down, screenful: false) }
        case "H": changeView { $0.scrollToEdge(.left) }
        case "J": changeView { $0.scrollToEdge(.down) }
        case "K": changeView { $0.scrollToEdge(.up) }
        case "L": changeView { $0.scrollToEdge(.right) }
        case "z": changeView { $0.centerImage() }
        case "=": changeView { $0.setZoom(1) }
        case "w": changeView { $0.setScaleMode(.down) }
        case "W": changeView { $0.setScaleMode(.fit) }
        case "F": changeView { $0.setScaleMode(.fill) }
        case "e": changeView { $0.setScaleMode(.width) }
        case "E": changeView { $0.setScaleMode(.height) }
        case "<": rotate(270)
        case ">": rotate(90)
        case "?": rotate(180)
        case "|": flipH.toggle(); showFrame()
        case "_": flipV.toggle(); showFrame()
        case "a": changeView { $0.antialias.toggle() }
        case "A": changeView { $0.alphaLayer.toggle() }
        case "x": enterEditMode()
        case "s": toggleSlideshow()
        case "S": adjustSlideshowDelay(+1)
        default: return false
        }
        return true
    }

    private func zoomKey(_ dir: Int) {
        if !thumbnailMode {
            changeView { $0.zoomStep(dir) }
        } else if grid.zoom(dir) {
            grid.reveal(current)
            ui?.gridChanged()
        }
    }

    private func scrollScreenOrPage(_ d: Direction) {
        if thumbnailMode {
            grid.scrollPage(d)
            ui?.gridChanged()
        } else {
            changeView { $0.scrollStep(d, screenful: true) }
        }
    }

    private func directional(_ d: Direction) {
        if thumbnailMode {
            moveSelection(d)
        } else {
            changeView { $0.scrollStep(d, screenful: false) }
        }
    }
}
