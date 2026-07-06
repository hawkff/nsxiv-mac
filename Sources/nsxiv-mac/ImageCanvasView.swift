import AppKit

final class ImageCanvasView: NSView {
    var onNavigate: ((Int) -> Void)?
    var onSwitchMode: (() -> Void)?
    var onViewChange: (() -> Void)?

    private(set) var zoom: CGFloat = 1
    private(set) var scaleMode: ScaleMode = .down
    private var pan = CGPoint.zero
    private var image: CGImage?
    var errorText: String?

    var antialias = true { didSet { needsDisplay = true } }
    var alphaLayer = false { didSet { needsDisplay = true } }

    private var downPoint = CGPoint.zero
    private var dragged = false

    override var acceptsFirstResponder: Bool { false }

    private var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    private var displaySize: CGSize {
        CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
    }

    // MARK: - state

    func setImage(_ img: CGImage?, resetView: Bool) {
        image = img
        if resetView {
            applyScaleMode()
        } else {
            clampPan()
        }
        needsDisplay = true
    }

    func setScaleMode(_ mode: ScaleMode) {
        scaleMode = mode
        applyScaleMode()
        needsDisplay = true
        onViewChange?()
    }

    func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        guard image != nil else { return }
        let minZ = Config.zoomLevels.first!, maxZ = Config.zoomLevels.last!
        let new = max(minZ, min(maxZ, z))
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let ratio = new / zoom
        pan.x = a.x - (a.x - pan.x) * ratio
        pan.y = a.y - (a.y - pan.y) * ratio
        zoom = new
        scaleMode = .manual
        clampPan()
        needsDisplay = true
        onViewChange?()
    }

    func zoomStep(_ dir: Int) {
        let levels = Config.zoomLevels
        if dir > 0 {
            if let next = levels.first(where: { $0 > zoom + 0.001 }) { setZoom(next) }
        } else {
            if let prev = levels.last(where: { $0 < zoom - 0.001 }) { setZoom(prev) }
        }
    }

    func applyScaleMode() {
        guard image != nil, imageSize.width > 0, imageSize.height > 0 else { return }
        let vw = bounds.width, vh = bounds.height
        let zw = vw / imageSize.width, zh = vh / imageSize.height
        switch scaleMode {
        case .fit: zoom = min(zw, zh)
        case .down: zoom = min(1, min(zw, zh))
        case .width: zoom = zw
        case .height: zoom = zh
        case .fill: zoom = max(zw, zh)
        case .manual: break
        }
        zoom = max(Config.zoomLevels.first! / 4, min(Config.zoomLevels.last!, zoom))
        centerImage()
    }

    func centerImage() {
        pan = CGPoint(x: (bounds.width - displaySize.width) / 2,
                      y: (bounds.height - displaySize.height) / 2)
        clampPan()
        needsDisplay = true
    }

    // MARK: - panning

    func scroll(dx: CGFloat, dy: CGFloat) {
        pan.x += dx
        pan.y += dy
        clampPan()
        needsDisplay = true
    }

    func scrollStep(_ direction: Direction, screenful: Bool) {
        let sx = screenful ? bounds.width : bounds.width / Config.panFraction
        let sy = screenful ? bounds.height : bounds.height / Config.panFraction
        switch direction {
        case .left: scroll(dx: sx, dy: 0)
        case .right: scroll(dx: -sx, dy: 0)
        case .up: scroll(dx: 0, dy: -sy)
        case .down: scroll(dx: 0, dy: sy)
        }
    }

    func scrollToEdge(_ direction: Direction) {
        switch direction {
        case .left: pan.x = 0
        case .right: pan.x = bounds.width - displaySize.width
        case .up: pan.y = bounds.height - displaySize.height
        case .down: pan.y = 0
        }
        clampPan()
        needsDisplay = true
    }

    private func clampPan() {
        let ds = displaySize
        if ds.width <= bounds.width {
            pan.x = (bounds.width - ds.width) / 2
        } else {
            pan.x = min(0, max(bounds.width - ds.width, pan.x))
        }
        if ds.height <= bounds.height {
            pan.y = (bounds.height - ds.height) / 2
        } else {
            pan.y = min(0, max(bounds.height - ds.height, pan.y))
        }
    }

    override func layout() {
        super.layout()
        if scaleMode == .manual {
            clampPan()
        } else {
            applyScaleMode()
        }
        onViewChange?()
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        guard let image else {
            if let errorText {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Config.barFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let s = NSAttributedString(string: errorText, attributes: attrs)
                let sz = s.size()
                s.draw(at: CGPoint(x: (bounds.width - sz.width) / 2,
                                   y: (bounds.height - sz.height) / 2))
            }
            return
        }

        let rect = CGRect(origin: pan, size: displaySize)
        if alphaLayer {
            drawCheckerboard(ctx, in: rect.intersection(bounds))
        }
        ctx.saveGState()
        ctx.interpolationQuality = antialias ? .high : .none
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private func drawCheckerboard(_ ctx: CGContext, in rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        let cell: CGFloat = 12
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        ctx.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
        var y = rect.minY - rect.minY.truncatingRemainder(dividingBy: cell * 2)
        while y < rect.maxY {
            var x = rect.minX - rect.minX.truncatingRemainder(dividingBy: cell * 2)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                ctx.fill(CGRect(x: x + cell, y: y + cell, width: cell, height: cell))
                x += cell * 2
            }
            y += cell * 2
        }
        ctx.restoreGState()
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        scroll(dx: event.deltaX, dy: -event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        let navW = bounds.width * Config.navWidthFraction
        if p.x < navW {
            onNavigate?(-1)
        } else if p.x > bounds.width - navW {
            onNavigate?(1)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSwitchMode?()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
            let p = convert(event.locationInWindow, from: nil)
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            setZoom(zoom * max(0.2, factor), anchor: p)
        } else if event.hasPreciseScrollingDeltas {
            scroll(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
        } else {
            // line-based wheel zooms, like nsxiv buttons 4/5
            zoomStep(event.scrollingDeltaY > 0 ? 1 : -1)
        }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification), anchor: p)
    }
}

enum Direction {
    case left, right, up, down
}
