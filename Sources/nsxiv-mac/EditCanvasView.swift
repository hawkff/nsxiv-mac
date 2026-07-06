import AppKit

final class EditSession {
    var base: CGImage
    let sourceURL: URL
    var annotations: [Annotation] = []
    var redoStack: [Annotation] = []
    var tool: EditTool = .arrow
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fillMode: FillMode = .stroke
    var censorMode: CensorMode = .pixelate
    var emoji = "✅"
    var fontSize: CGFloat = 28
    var badgeCounter = 1
    var selection: UUID?

    init(base: CGImage, sourceURL: URL) {
        self.base = base
        self.sourceURL = sourceURL
    }

    var imageSize: CGSize { CGSize(width: base.width, height: base.height) }

    func undo() {
        guard let last = annotations.popLast() else { return }
        if last.tool == .badge { badgeCounter = max(1, badgeCounter - 1) }
        redoStack.append(last)
        selection = nil
    }

    func redo() {
        guard let a = redoStack.popLast() else { return }
        if a.tool == .badge { badgeCounter += 1 }
        annotations.append(a)
    }

    func deleteSelected() {
        guard let sel = selection else { return }
        if let idx = annotations.firstIndex(where: { $0.id == sel }),
           annotations[idx].tool == .badge {
            badgeCounter = max(1, badgeCounter - 1)
        }
        annotations.removeAll { $0.id == sel }
        redoStack.removeAll()
        selection = nil
    }

    func selectedIndex() -> Int? {
        guard let sel = selection else { return nil }
        return annotations.firstIndex { $0.id == sel }
    }

    func flattened() -> CGImage? {
        AnnotationRenderer.flatten(base: base, annotations: annotations)
    }
}

final class EditCanvasView: NSView {
    var session: EditSession? {
        didSet { needsDisplay = true }
    }
    var onStatusUpdate: (() -> Void)?
    var onEditText: ((Int) -> Void)? // request text editing for annotation at index
    var spaceDown = false

    private var drawing: Annotation?
    private var dragStartImage = CGPoint.zero
    private var moveOrigin: Annotation?
    private var activeHandle: Int? // index into handlePoints
    private var lastDragImage = CGPoint.zero

    override var acceptsFirstResponder: Bool { false }

    // MARK: - transform

    var fitScale: CGFloat {
        guard let s = session else { return 1 }
        let sz = s.imageSize
        guard sz.width > 0, sz.height > 0 else { return 1 }
        return min(bounds.width / sz.width, bounds.height / sz.height, 1)
    }

    private var imageOrigin: CGPoint {
        guard let s = session else { return .zero }
        let sz = s.imageSize, k = fitScale
        return CGPoint(x: (bounds.width - sz.width * k) / 2,
                       y: (bounds.height - sz.height * k) / 2)
    }

    func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        let o = imageOrigin, k = fitScale
        return CGPoint(x: (viewPoint.x - o.x) / k, y: (viewPoint.y - o.y) / k)
    }

    func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        let o = imageOrigin, k = fitScale
        return CGPoint(x: imagePoint.x * k + o.x, y: imagePoint.y * k + o.y)
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let s = session else {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        ctx.saveGState()
        ctx.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        ctx.scaleBy(x: fitScale, y: fitScale)
        ctx.interpolationQuality = .high
        ctx.draw(s.base, in: CGRect(origin: .zero, size: s.imageSize))

        var all = s.annotations
        if let d = drawing { all.append(d) }
        AnnotationRenderer.drawAll(all, base: s.base, ctx: ctx, imageSize: s.imageSize,
                                   selection: s.selection, handleScale: 1 / fitScale)
        ctx.restoreGState()
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        guard let s = session else { return }
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        dragStartImage = p
        lastDragImage = p

        if s.tool == .select {
            // handle drag on selected annotation first
            if let idx = s.selectedIndex() {
                let handles = AnnotationRenderer.handlePoints(s.annotations[idx])
                let slop = 12 / fitScale
                for (i, h) in handles.enumerated()
                where hypot(h.x - p.x, h.y - p.y) < slop {
                    activeHandle = i
                    moveOrigin = s.annotations[idx]
                    return
                }
            }
            // then hit test top-down
            if let idx = s.annotations.lastIndex(where: { $0.hit(p) }) {
                s.selection = s.annotations[idx].id
                moveOrigin = s.annotations[idx]
                if event.clickCount >= 2,
                   s.annotations[idx].tool == .text || s.annotations[idx].tool == .stamp {
                    onEditText?(idx)
                }
            } else {
                s.selection = nil
                moveOrigin = nil
            }
            activeHandle = nil
            needsDisplay = true
            onStatusUpdate?()
            return
        }

        var a = Annotation(tool: s.tool)
        a.start = p
        a.end = p
        a.color = s.color
        a.lineWidth = s.lineWidth
        a.fillMode = s.fillMode
        a.censorMode = s.censorMode
        a.fontSize = s.fontSize
        switch s.tool {
        case .pencil, .marker:
            a.points = [p]
        case .badge:
            a.number = s.badgeCounter
        case .stamp:
            a.text = s.emoji
        default:
            break
        }
        drawing = a
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = session else { return }
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        defer {
            lastDragImage = p
            needsDisplay = true
        }

        if s.tool == .select {
            guard let idx = s.selectedIndex(), let origin = moveOrigin else { return }
            if let h = activeHandle {
                s.annotations[idx] = resized(origin, handle: h, to: p)
            } else {
                let d = CGPoint(x: p.x - dragStartImage.x, y: p.y - dragStartImage.y)
                s.annotations[idx] = origin.moved(by: d)
            }
            return
        }

        guard var d = drawing else { return }
        if spaceDown, d.tool != .pencil, d.tool != .marker {
            // hold space: reposition the in-progress shape without resizing
            let delta = CGPoint(x: p.x - lastDragImage.x, y: p.y - lastDragImage.y)
            d = d.moved(by: delta)
        } else {
            switch d.tool {
            case .pencil, .marker:
                d.points.append(p)
            default:
                d.end = p
            }
        }
        drawing = d
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = session else { return }
        if s.tool == .select {
            moveOrigin = nil
            activeHandle = nil
            return
        }
        guard var d = drawing else { return }
        drawing = nil

        let p = imagePoint(convert(event.locationInWindow, from: nil))
        let moved = hypot(p.x - dragStartImage.x, p.y - dragStartImage.y) > 3

        switch d.tool {
        case .badge:
            s.badgeCounter += 1
        case .stamp:
            break
        case .text:
            // click places a text box; editing handled by the controller
            s.annotations.append(d)
            s.redoStack.removeAll()
            needsDisplay = true
            onEditText?(s.annotations.count - 1)
            return
        case .pencil, .marker:
            guard d.points.count > 1 else { return }
        default:
            guard moved else { return } // ignore stray clicks
            d.end = clampToImage(d.end)
        }
        s.annotations.append(d)
        s.redoStack.removeAll()
        s.selection = nil
        needsDisplay = true
        onStatusUpdate?()
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        guard let s = session else { return p }
        return CGPoint(x: max(0, min(s.imageSize.width, p.x)),
                       y: max(0, min(s.imageSize.height, p.y)))
    }

    private func resized(_ a: Annotation, handle: Int, to p: CGPoint) -> Annotation {
        var out = a
        switch a.tool {
        case .arrow:
            if handle == 0 { out.start = p } else { out.end = p }
        case .rect, .ellipse, .censor, .spotlight:
            // handles: (minX,minY) (maxX,minY) (minX,maxY) (maxX,maxY)
            let r = a.rect
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            switch handle {
            case 0: minX = p.x; minY = p.y
            case 1: maxX = p.x; minY = p.y
            case 2: minX = p.x; maxY = p.y
            default: maxX = p.x; maxY = p.y
            }
            out.start = CGPoint(x: minX, y: minY)
            out.end = CGPoint(x: maxX, y: maxY)
        default:
            break
        }
        return out
    }
}
