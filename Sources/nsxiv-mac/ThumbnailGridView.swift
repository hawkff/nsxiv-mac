import AppKit

final class ThumbnailGridView: NSView {
    var files: [FileEntry] = [] { didSet { reloadAll() } }
    var selection = 0
    var onOpen: ((Int) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onToggleMark: ((Int) -> Void)?
    var cache: ThumbnailCache?

    private var thumbs: [CGImage?] = []
    private var requested: Set<Int> = []
    private var sizeIndex = Config.thumbSizeIndex
    private var scrollY: CGFloat = 0

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    private var thumbSize: CGFloat { Config.thumbSizes[sizeIndex] }
    private var cellSize: CGFloat { thumbSize + Config.thumbPadding * 2 }

    private var columns: Int {
        max(1, Int(bounds.width / cellSize))
    }

    private var rows: Int {
        files.isEmpty ? 0 : (files.count + columns - 1) / columns
    }

    private var contentHeight: CGFloat {
        CGFloat(rows) * cellSize
    }

    // MARK: - selection

    func moveSelection(_ direction: Direction) {
        guard !files.isEmpty else { return }
        var s = selection
        switch direction {
        case .left: s -= 1
        case .right: s += 1
        case .up: s -= columns
        case .down: s += columns
        }
        selection = max(0, min(files.count - 1, s))
        scrollToSelection()
        needsDisplay = true
        onSelectionChange?()
    }

    func select(_ index: Int) {
        selection = max(0, min(files.count - 1, index))
        scrollToSelection()
        needsDisplay = true
    }

    func zoomThumbs(_ dir: Int) {
        let ni = sizeIndex + dir
        guard Config.thumbSizes.indices.contains(ni) else { return }
        sizeIndex = ni
        requested.removeAll()
        clampScroll()
        needsDisplay = true
    }

    func reloadAll() {
        thumbs = Array(repeating: nil, count: files.count)
        requested.removeAll()
        needsDisplay = true
    }

    func scrollPage(_ direction: Direction) {
        switch direction {
        case .up: scrollY -= bounds.height
        case .down: scrollY += bounds.height
        default: return
        }
        clampScroll()
        needsDisplay = true
    }

    private func scrollToSelection() {
        let r = cellRect(selection)
        if r.minY < scrollY {
            scrollY = r.minY
        } else if r.maxY > scrollY + bounds.height {
            scrollY = r.maxY - bounds.height
        }
        clampScroll()
    }

    private func clampScroll() {
        scrollY = max(0, min(scrollY, max(0, contentHeight - bounds.height)))
    }

    private func cellRect(_ index: Int) -> CGRect {
        let cols = columns
        let row = index / cols, col = index % cols
        let xInset = (bounds.width - CGFloat(cols) * cellSize) / 2
        return CGRect(x: xInset + CGFloat(col) * cellSize,
                      y: CGFloat(row) * cellSize,
                      width: cellSize, height: cellSize)
    }

    private func indexAt(point: CGPoint) -> Int? {
        let p = CGPoint(x: point.x, y: point.y + scrollY)
        let cols = columns
        let xInset = (bounds.width - CGFloat(cols) * cellSize) / 2
        guard p.x >= xInset, p.x < xInset + CGFloat(cols) * cellSize, p.y >= 0 else { return nil }
        let col = Int((p.x - xInset) / cellSize)
        let row = Int(p.y / cellSize)
        let i = row * cols + col
        return files.indices.contains(i) ? i : nil
    }

    // MARK: - drawing

    override func layout() {
        super.layout()
        clampScroll()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard !files.isEmpty else { return }

        let firstRow = max(0, Int(scrollY / cellSize))
        let lastRow = min(rows - 1, Int((scrollY + bounds.height) / cellSize) + 1)
        guard firstRow <= lastRow else { return }

        for row in firstRow...lastRow {
            for col in 0..<columns {
                let i = row * columns + col
                guard i < files.count else { break }
                drawCell(i)
            }
        }
    }

    private func drawCell(_ i: Int) {
        var rect = cellRect(i)
        rect.origin.y -= scrollY
        let inner = rect.insetBy(dx: Config.thumbPadding, dy: Config.thumbPadding)

        if let thumb = thumbs[i] {
            let tw = CGFloat(thumb.width), th = CGFloat(thumb.height)
            let scale = min(inner.width / tw, inner.height / th, 1)
            let dw = tw * scale, dh = th * scale
            let dr = CGRect(x: inner.midX - dw / 2, y: inner.midY - dh / 2, width: dw, height: dh)
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                // view is flipped; un-flip for CGImage drawing
                ctx.translateBy(x: 0, y: dr.midY * 2)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(thumb, in: dr)
                ctx.restoreGState()
            }
        } else {
            NSColor.quaternaryLabelColor.setFill()
            inner.insetBy(dx: inner.width * 0.25, dy: inner.height * 0.25).fill()
            request(i)
        }

        if i == selection {
            let path = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if files[i].marked {
            let d: CGFloat = 8
            let dot = NSBezierPath(ovalIn: CGRect(
                x: rect.maxX - d - 6, y: rect.minY + 6, width: d, height: d))
            Config.markColor.setFill()
            dot.fill()
        }
    }

    private func request(_ i: Int) {
        guard !requested.contains(i), let cache else { return }
        requested.insert(i)
        let entry = files[i]
        cache.thumbnail(for: entry) { [weak self] img in
            guard let self, self.files.indices.contains(i),
                  self.files[i].path == entry.path else { return }
            self.thumbs[i] = img
            self.needsDisplay = true
        }
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = indexAt(point: p) else { return }
        if event.clickCount >= 2 {
            onOpen?(i)
        } else {
            select(i)
            onSelectionChange?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = indexAt(point: p) else { return }
        select(i)
        onToggleMark?(i)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * cellSize / 3
        scrollY -= dy
        clampScroll()
        needsDisplay = true
    }
}
