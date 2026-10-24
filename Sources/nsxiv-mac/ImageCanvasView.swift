#if os(macOS)
import AppKit

// Draws the processed frame where the viewer's viewport puts it; mouse input goes to the viewer.
final class ImageCanvasView: NSView {
    weak var viewer: Viewer?
    var image: CGImage?
    var errorText: String?

    private var dragged = false

    override var acceptsFirstResponder: Bool { false }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let viewer else { return }
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

        let view = viewer.viewport
        let rect = view.imageRect
        if view.alphaLayer {
            Self.checkerboard.setFill()
            rect.intersection(bounds).fill()
        }
        ctx.saveGState()
        ctx.interpolationQuality = view.antialias ? .high : .none
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private static let checkerboard: NSColor = {
        let cell: CGFloat = 12
        let tile = NSImage(size: CGSize(width: cell * 2, height: cell * 2), flipped: false) { r in
            NSColor.white.setFill()
            r.fill()
            NSColor(white: 0.75, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: cell, height: cell).fill()
            CGRect(x: cell, y: cell, width: cell, height: cell).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        viewer?.pan(dx: event.deltaX, dy: -event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        let navW = bounds.width * Config.navWidthFraction
        if p.x < navW {
            viewer?.navigate(-1)
        } else if p.x > bounds.width - navW {
            viewer?.navigate(1)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        viewer?.switchMode()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewer else { return }
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
            let p = convert(event.locationInWindow, from: nil)
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            viewer.zoom(to: viewer.viewport.zoom * max(0.2, factor), anchor: p)
        } else if event.hasPreciseScrollingDeltas {
            viewer.pan(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
        } else {
            // line-based wheel zooms, like nsxiv buttons 4/5
            viewer.zoomStep(event.scrollingDeltaY > 0 ? 1 : -1)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let viewer else { return }
        let p = convert(event.locationInWindow, from: nil)
        viewer.zoom(to: viewer.viewport.zoom * (1 + event.magnification), anchor: p)
    }
}
#endif
