#if os(Linux)
import CX11
import Foundation

// Draws the viewer with Imlib2 into an image the frontend shows: X11 puts it on the
// window, Wayland draws straight into a shared-memory buffer. The viewer works in
// logical units; `scale` turns them into the canvas's pixels.
final class ImlibRenderer {
    private let viewer: Viewer
    // a thumbnail arrived, so the frontend should draw again
    var onThumbnail: () -> Void = {}
    // false where the frontend shows the status bar itself, as the terminal does on its last line
    var drawsBar = true

    // the open file: its composed frames, and the current one rotated and flipped
    private var loadedPath: String?
    private var frames: [Imlib_Image] = []
    private var shown: Imlib_Image?
    private let colorModifier: Imlib_Color_Modifier

    private var thumbs: [String: Imlib_Image] = [:]
    private var failedThumbs: Set<String> = []
    private var thumbnailPending = false

    // the bar font fontconfig picks, loaded once for each pixel size
    private let font: (file: String, pixels: Double)?
    private var fonts: [Int: Imlib_Font] = [:]
    private(set) var barHeight = 0 // logical

    private typealias RGB = (r: Int32, g: Int32, b: Int32)
    private let background = ImlibRenderer.rgb(Config.background)
    private let foreground = ImlibRenderer.rgb(Config.foreground)
    private let barBackground = ImlibRenderer.rgb(Config.barBackground)
    private let selection = ImlibRenderer.rgb(Config.selectionColor)
    private let mark = ImlibRenderer.rgb(Config.markColor)

    init(viewer: Viewer) {
        self.viewer = viewer
        let memory = Int(clamping: ProcessInfo.processInfo.physicalMemory / 100) * Config.imageCachePercent
        imlib_set_cache_size(Int32(min(Config.imageCacheLimit, memory)))
        colorModifier = imlib_create_color_modifier()
        font = Self.matchFont(Config.barFont)
        if font == nil { warn("no font matches \(Config.barFont)") }
        if let face = loadFont(scale: 1) {
            imlib_context_set_font(face)
            barHeight = textSize("Ag").height + 8
        }
    }

    private static func rgb(_ hex: String) -> RGB {
        let v = Int32(hex.dropFirst(), radix: 16) ?? 0
        return (v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff)
    }

    // the file and pixel size fontconfig gives a pattern such as "monospace:pixelsize=13"
    private static func matchFont(_ pattern: String) -> (file: String, pixels: Double)? {
        guard FcInit() != 0, let wanted = FcNameParse(pattern) else { return nil }
        defer { FcPatternDestroy(wanted) }
        FcConfigSubstitute(nil, wanted, FcMatchPattern)
        FcDefaultSubstitute(wanted)
        var result = FcResultNoMatch
        guard let match = FcFontMatch(nil, wanted, &result) else { return nil }
        defer { FcPatternDestroy(match) }
        var file: UnsafeMutablePointer<FcChar8>?
        var index: Int32 = 0
        var pixels = 13.0
        guard FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch, let file else { return nil }
        FcPatternGetInteger(match, FC_INDEX, 0, &index)
        FcPatternGetDouble(match, FC_PIXEL_SIZE, 0, &pixels)
        let path = String(cString: UnsafeRawPointer(file).assumingMemoryBound(to: CChar.self))
        return (index > 0 ? "\(path):\(index)" : path, pixels) // Imlib2 reads "file[:face]/size"
    }

    private func loadFont(scale: Double) -> Imlib_Font? {
        guard let font else { return nil }
        let pixels = Int((font.pixels * scale).rounded())
        if let face = fonts[pixels] { return face }
        let face: Imlib_Font? = imlib_load_font("\(font.file)/\(pixels)")
        fonts[pixels] = face
        return face
    }

    // MARK: - images

    func loadImage(_ url: URL) -> ImageInfo? {
        // a reload reads the file again; another file leaves this one cached for a revisit
        freeImage(decache: url.path == loadedPath)
        loadedPath = url.path
        guard let first = imlib_load_image_frame(url.path, 1) else { return nil }
        imlib_context_set_image(first)
        imlib_image_set_changes_on_disk() // a revisit checks the file's time, as in nsxiv
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

    // another frame, rotation, flip, gamma or contrast
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
        setColors()
    }

    // the viewer's gamma and contrast, for what draws next
    private func setColors() {
        imlib_context_set_color_modifier(colorModifier)
        imlib_reset_color_modifier()
        if viewer.gamma != 0 { imlib_modify_color_modifier_gamma(viewer.gammaValue) }
        if viewer.contrast != 0 { imlib_modify_color_modifier_contrast(viewer.contrastValue) }
    }

    private func freeImage(decache: Bool) {
        if let shown, !frames.contains(shown) {
            imlib_context_set_image(shown)
            imlib_free_image()
        }
        shown = nil
        for frame in frames {
            imlib_context_set_image(frame)
            if decache { imlib_free_image_and_decache() } else { imlib_free_image() }
        }
        frames = []
    }

    // Imlib2 hands out raw frames; each one is drawn over what the previous one left
    private static func compose(_ path: String, _ first: Imlib_Frame_Info)
        -> (frames: [Imlib_Image], delays: [TimeInterval])? {
        let w = first.canvas_w, h = first.canvas_h
        guard w > 0, h > 0, let blank = imlib_create_image(w, h) else { return nil }
        // shortcut: every frame stays composed in memory, so an animation needing more than 1 GiB
        // shows its first frame on its canvas as a still; decode frames as they show, as
        // ImageLoader does on macOS, if such files matter
        let fits = Double(first.frame_count) * Double(w) * Double(h) * 4 <= Double(1 << 30)
        if !fits { warn("\(path): too large to animate, showing its first frame") }
        imlib_context_set_image(blank)
        clear(0, 0, w, h)
        imlib_context_set_anti_alias(0)
        imlib_context_set_color_modifier(nil)
        imlib_context_set_operation(IMLIB_OP_COPY)
        var frames: [Imlib_Image] = []
        var delays: [TimeInterval] = []
        var previous = Imlib_Frame_Info() // the last frame's disposal and area
        var undo: Imlib_Image? // the canvas before the last frame, kept when that frame asks to be undone
        for n in 1...(fits ? first.frame_count : 1) {
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
        // a file that promised more frames than it had stays the raw still
        guard frames.count > 1 || !fits, !frames.isEmpty else {
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

    // MARK: - thumbnails

    func invalidateThumbnails(_ entries: [FileEntry]) {
        // the files' decoded images go too: an edit that kept a future modification time would
        // pass Imlib2's check of the file's time
        // shortcut: drops every cached image; imlib_image_decache_file, from Imlib2 1.12, would
        // drop just these, once older Imlib2 versions need no support
        let cacheSize = imlib_get_cache_size()
        imlib_set_cache_size(0)
        imlib_set_cache_size(cacheSize)
        for entry in entries {
            failedThumbs.remove(entry.path)
            if let thumb = thumbs.removeValue(forKey: entry.path) {
                imlib_context_set_image(thumb)
                imlib_free_image()
            }
        }
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
            onThumbnail()
            scheduleThumbnail() // the next one, without waiting for a frame that may come later
        }
    }

    static func makeThumbnail(_ path: String) -> Imlib_Image? {
        guard let full = imlib_load_image_frame(path, 1) else { return nil }
        imlib_context_set_image(full)
        var info = Imlib_Frame_Info()
        imlib_image_get_frame_info(&info)
        let w = imlib_image_get_width(), h = imlib_image_get_height()
        // an animation's first frame may cover only part of its canvas, where image mode puts it
        let animated = info.frame_count > 1 && info.frame_flags & IMLIB_IMAGE_ANIMATED != 0
        let cw = animated && info.canvas_w > 0 ? info.canvas_w : w
        let ch = animated && info.canvas_h > 0 ? info.canvas_h : h
        // sharp up to the largest grid size on a 2x screen
        let s = min(1, CGFloat(Config.thumbMaxPixel) / CGFloat(max(cw, ch, 1)))
        let scaled = { (n: Int32) in max(1, Int32(CGFloat(n) * s)) }
        imlib_context_set_anti_alias(1)
        var thumb: Imlib_Image?
        if cw == w, ch == h {
            thumb = imlib_create_cropped_scaled_image(0, 0, w, h, scaled(w), scaled(h))
        } else if let canvas = imlib_create_image(scaled(cw), scaled(ch)) {
            imlib_context_set_image(canvas)
            clear(0, 0, scaled(cw), scaled(ch))
            imlib_context_set_color_modifier(nil)
            imlib_context_set_operation(IMLIB_OP_COPY)
            imlib_blend_image_onto_image(full, 1, 0, 0, w, h, Int32(CGFloat(info.frame_x) * s),
                                         Int32(CGFloat(info.frame_y) * s), scaled(w), scaled(h))
            thumb = canvas
            imlib_context_set_image(full)
        }
        imlib_free_image_and_decache()
        return thumb
    }

    // shortcut: past 1000 thumbnails (400 KB each at most) the ones out of view go;
    // an LRU would keep more when a huge grid is scrolled back and forth
    private func pruneThumbnails() {
        guard thumbs.count >= 1000 else { return }
        let keep = Set(viewer.grid.visible.map { viewer.files[$0].path })
        for (path, thumb) in thumbs where !keep.contains(path) {
            imlib_context_set_image(thumb)
            imlib_free_image()
        }
        thumbs = thumbs.filter { keep.contains($0.key) }
    }

    // MARK: - drawing

    // draws the whole window into canvas, which is width by height pixels
    func render(into canvas: Imlib_Image, width: Int, height: Int, scale: Double) {
        imlib_context_set_image(canvas)
        imlib_image_set_has_alpha(0)
        imlib_context_set_color_modifier(nil)
        imlib_context_set_operation(IMLIB_OP_COPY)
        fill(background, 0, 0, width, height)
        let barH = drawsBar && viewer.barVisible ? Int((Double(barHeight) * scale).rounded()) : 0
        let mainH = max(0, height - barH)
        if viewer.thumbnailMode {
            renderGrid(canvas, scale: scale)
        } else {
            renderImage(canvas, width: width, height: mainH, scale: scale)
        }
        if barH > 0 { renderBar(canvas, y: mainH, width: width, height: barH, scale: scale) }
    }

    private func fill(_ color: RGB, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        imlib_context_set_blend(0)
        imlib_context_set_color(color.r, color.g, color.b, 255)
        imlib_image_fill_rectangle(Int32(x), Int32(y), Int32(max(0, w)), Int32(max(0, h)))
    }

    private func renderImage(_ canvas: Imlib_Image, width: Int, height: Int, scale: Double) {
        drawImage(shown, view: viewer.viewport, errorText: viewer.errorText, into: canvas, width: width, height: height,
                  scale: scale)
    }

    // A still image other than the current one, as it will show once it is: the terminal draws
    // the next image while the viewer waits for a key. peek's image goes back with release, and
    // stays in Imlib2's cache for loadImage; an animation gives nil.
    func peek(_ url: URL) -> (image: Imlib_Image, size: CGSize)? {
        guard let image = imlib_load_image_frame(url.path, 1) else { return nil }
        imlib_context_set_image(image)
        imlib_image_set_changes_on_disk()
        var info = Imlib_Frame_Info()
        imlib_image_get_frame_info(&info)
        guard info.frame_count <= 1 || info.frame_flags & IMLIB_IMAGE_ANIMATED == 0 else {
            imlib_free_image()
            return nil
        }
        return (image, CGSize(width: Int(imlib_image_get_width()), height: Int(imlib_image_get_height())))
    }

    func release(_ image: Imlib_Image) {
        imlib_context_set_image(image)
        imlib_free_image()
    }

    // the image view of image, unturned, with the current gamma and contrast, which a change made
    // while the terminal showed a frame it kept never gave this renderer
    func drawStill(_ image: Imlib_Image, view: Viewport, into canvas: Imlib_Image, width: Int, height: Int,
                   scale: Double) {
        setColors()
        imlib_context_set_image(canvas)
        imlib_image_set_has_alpha(0)
        imlib_context_set_color_modifier(nil)
        imlib_context_set_operation(IMLIB_OP_COPY)
        fill(background, 0, 0, width, height)
        drawImage(image, view: view, errorText: nil, into: canvas, width: width, height: height, scale: scale)
    }

    private func drawImage(_ image: Imlib_Image?, view: Viewport, errorText: String?, into canvas: Imlib_Image,
                           width: Int, height: Int, scale: Double) {
        guard let shown = image else {
            if let text = errorText, let face = loadFont(scale: scale) {
                imlib_context_set_font(face)
                let size = textSize(text)
                drawText(text, x: (width - size.width) / 2, y: (height - size.height) / 2)
            }
            return
        }
        let r = view.imageRect
        let s = CGFloat(scale), w = CGFloat(width), h = CGFloat(height)
        let dx = r.minX * s, dy = h - r.maxY * s, z = view.zoom * s // the canvas counts y downward
        imlib_context_set_image(shown)
        let alpha = imlib_image_has_alpha() != 0
        let iw = CGFloat(imlib_image_get_width()), ih = CGFloat(imlib_image_get_height())
        // only the source pixels that land in the window, in whole pixels so zoom stays steady
        let sx0 = max(0, (-dx / z).rounded(.down)), sy0 = max(0, (-dy / z).rounded(.down))
        let sx1 = min(iw, ((w - dx) / z).rounded(.up)), sy1 = min(ih, ((h - dy) / z).rounded(.up))
        guard sx1 > sx0, sy1 > sy0 else { return }
        let x = Int32((dx + sx0 * z).rounded()), y = Int32((dy + sy0 * z).rounded())
        let dw = Int32(max(1, ((sx1 - sx0) * z).rounded())), dh = Int32(max(1, ((sy1 - sy0) * z).rounded()))
        imlib_context_set_image(canvas)
        if alpha, view.alphaLayer {
            checkerboard(x: Int(x), y: Int(y), w: Int(dw), h: Int(dh), limit: (width, height), cell: Int(12 * s))
        }
        imlib_context_set_anti_alias(view.antialias ? 1 : 0)
        imlib_context_set_color_modifier(colorModifier)
        imlib_context_set_blend(alpha ? 1 : 0)
        imlib_blend_image_onto_image(shown, 0, Int32(sx0), Int32(sy0), Int32(sx1 - sx0), Int32(sy1 - sy0),
                                     x, y, dw, dh)
        imlib_context_set_color_modifier(nil)
    }

    // the 12 pt white and gray squares the macOS side draws under transparent pixels
    private func checkerboard(x: Int, y: Int, w: Int, h: Int, limit: (width: Int, height: Int), cell: Int) {
        guard let data = imlib_image_get_data() else { return }
        let stride = Int(imlib_image_get_width())
        let cell = max(1, cell)
        for row in max(0, y)..<min(limit.height, y + h) {
            for col in max(0, x)..<min(limit.width, x + w) {
                data[row * stride + col] = ((col - x) / cell + (row - y) / cell) & 1 == 0 ? 0xFFFF_FFFF : 0xFFBF_BFBF
            }
        }
        imlib_image_put_back_data(data)
    }

    private func renderGrid(_ canvas: Imlib_Image, scale: Double) {
        let grid = viewer.grid
        let s = CGFloat(scale)
        var missing = false
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
        }
        for i in grid.visible {
            let entry = viewer.files[i]
            let cell = pixels(grid.cellRect(i))
            let inner = cell.insetBy(dx: Config.thumbPadding * s, dy: Config.thumbPadding * s)
            if let thumb = thumbs[entry.path] {
                imlib_context_set_image(thumb)
                let tw = CGFloat(imlib_image_get_width()), th = CGFloat(imlib_image_get_height())
                let fit = min(inner.width / tw, inner.height / th, 1)
                let dw = tw * fit, dh = th * fit
                imlib_context_set_image(canvas)
                imlib_context_set_anti_alias(1)
                imlib_context_set_blend(1)
                imlib_blend_image_onto_image(thumb, 0, 0, 0, Int32(tw), Int32(th), Int32(inner.midX - dw / 2),
                                             Int32(inner.midY - dh / 2), Int32(dw), Int32(dh))
            } else {
                let p = inner.insetBy(dx: inner.width * 0.25, dy: inner.height * 0.25)
                fill(barBackground, Int(p.minX), Int(p.minY), Int(p.width), Int(p.height))
                if !failedThumbs.contains(entry.path) { missing = true }
            }
            if i == viewer.current {
                let b = cell.insetBy(dx: 2 * s, dy: 2 * s), t = max(1, Int((3 * s).rounded()))
                let (x, y, w, h) = (Int(b.minX), Int(b.minY), Int(b.width), Int(b.height))
                fill(selection, x, y, w, t)
                fill(selection, x, y + h - t, w, t)
                fill(selection, x, y, t, h)
                fill(selection, x + w - t, y, t, h)
            }
            if entry.marked {
                let d = 8 * s
                imlib_context_set_blend(1)
                imlib_context_set_color(mark.r, mark.g, mark.b, 255)
                imlib_image_fill_ellipse(Int32(cell.maxX - 6 * s - d / 2), Int32(cell.minY + 6 * s + d / 2),
                                         Int32(d / 2), Int32(d / 2))
            }
        }
        if missing { scheduleThumbnail() }
    }

    private func renderBar(_ canvas: Imlib_Image, y: Int, width: Int, height: Int, scale: Double) {
        imlib_context_set_image(canvas) // renderImage may return with the image still selected
        fill(barBackground, 0, y, width, height)
        guard let face = loadFont(scale: scale) else { return }
        imlib_context_set_font(face)
        let pad = Int((8 * scale).rounded())
        let status = viewer.statusText
        let fitted = Viewer.fittedStatus(status.right, room: CGFloat(width - pad * 2)) { CGFloat(textSize($0).width) }
        let right = textSize(fitted)
        let top = y + (height - right.height) / 2
        drawText(fitted, x: width - right.width - pad, y: top)
        let left = Self.truncatedHead(status.left, width: width - right.width - pad * 3) { textSize($0).width }
        drawText(left, x: pad, y: top)
    }

    // the title bar of a window the compositor leaves undecorated, in the status bar's
    // colors: the title, and a close button in the square at the right end
    func renderTitle(_ title: String, into canvas: Imlib_Image, width: Int, height: Int, scale: Double) {
        imlib_context_set_image(canvas)
        imlib_image_set_has_alpha(0)
        imlib_context_set_color_modifier(nil)
        fill(barBackground, 0, 0, width, height)
        guard let face = loadFont(scale: scale) else { return }
        imlib_context_set_font(face)
        let close = textSize("×")
        drawText("×", x: width - (height + close.width) / 2, y: (height - close.height) / 2)
        let pad = Int((8 * scale).rounded())
        let name = Self.truncatedHead(title, width: width - height - pad * 2) { textSize($0).width }
        drawText(name, x: pad, y: (height - textSize(name).height) / 2)
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

    // with the context font
    private func textSize(_ s: String) -> (width: Int, height: Int) {
        guard !s.isEmpty else { return (0, 0) }
        var w: Int32 = 0, h: Int32 = 0
        imlib_get_text_size(s, &w, &h)
        return (Int(w), Int(h))
    }

    private func drawText(_ s: String, x: Int, y: Int) {
        guard !s.isEmpty else { return }
        imlib_context_set_blend(1)
        imlib_context_set_color(foreground.r, foreground.g, foreground.b, 255)
        imlib_text_draw(Int32(x), Int32(y), s)
    }
}
#endif
