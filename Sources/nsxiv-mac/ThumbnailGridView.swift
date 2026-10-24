#if os(macOS)
import AppKit

// Draws the viewer's grid from ThumbnailCache; mouse input goes to the viewer.
final class ThumbnailGridView: NSView {
    weak var viewer: Viewer?
    var cache: ThumbnailCache?

    // paths asked for and not cached yet; a failed one stays, so it is not asked for again
    private var requested: Set<String> = []

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    // r, R and the key-handler: forget these thumbnails so the next draw generates them
    func invalidate(_ entries: [FileEntry]) {
        for entry in entries {
            cache?.invalidate(entry)
            requested.remove(entry.path)
        }
        needsDisplay = true
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let viewer else { return }
        for i in viewer.grid.visible {
            drawCell(i, of: viewer)
        }
    }

    private func drawCell(_ i: Int, of viewer: Viewer) {
        let entry = viewer.files[i]
        let rect = viewer.grid.cellRect(i)
        let inner = rect.insetBy(dx: Config.thumbPadding, dy: Config.thumbPadding)

        if let thumb = cache?.cached(entry) {
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
            request(entry)
        }

        if i == viewer.current {
            let path = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if entry.marked {
            let d: CGFloat = 8
            let dot = NSBezierPath(ovalIn: CGRect(
                x: rect.maxX - d - 6, y: rect.minY + 6, width: d, height: d))
            Config.markColor.setFill()
            dot.fill()
        }
    }

    private func request(_ entry: FileEntry) {
        guard let cache, requested.insert(entry.path).inserted else { return }
        cache.thumbnail(for: entry) { [weak self] img in
            guard let self else { return }
            if img != nil { self.requested.remove(entry.path) }
            self.needsDisplay = true
        }
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let viewer, let i = viewer.grid.index(at: p) else { return }
        if event.clickCount >= 2 {
            viewer.open(i)
        } else {
            viewer.select(i)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let viewer, let i = viewer.grid.index(at: p) else { return }
        viewer.toggleMark(at: i) // marks without moving the selection, like nsxiv
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewer else { return }
        let dy = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * viewer.grid.cellSize / 3
        viewer.scrollGrid(by: -dy)
    }
}
#endif
