import Foundation

enum Direction {
    case left, right, up, down
}

// Zoom and pan of the image in a view of viewSize, origin at the bottom left.
// Both windowing systems draw imageRect; X11 flips it to its top-left origin.
struct Viewport {
    private(set) var zoom: CGFloat = 1
    private(set) var scaleMode: ScaleMode = .down
    private(set) var pan = CGPoint.zero
    private(set) var imageSize = CGSize.zero // shown pixels, rotation applied; zero without an image
    var antialias = true
    var alphaLayer = false
    var viewSize = CGSize.zero {
        didSet {
            guard viewSize != oldValue else { return }
            if scaleMode == .manual { clampPan() } else { applyScaleMode() }
        }
    }

    // fit modes may go below the smallest zoom level, so pinch must too
    private static let zoomRange = Config.zoomLevels.first! / 4 ... Config.zoomLevels.last!

    var displaySize: CGSize {
        CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
    }

    var imageRect: CGRect { CGRect(origin: pan, size: displaySize) }

    mutating func setImageSize(_ size: CGSize, resetView: Bool) {
        imageSize = size
        if resetView { applyScaleMode() } else { clampPan() }
    }

    mutating func setScaleMode(_ mode: ScaleMode) {
        scaleMode = mode
        applyScaleMode()
    }

    mutating func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let new = max(Self.zoomRange.lowerBound, min(Self.zoomRange.upperBound, z))
        let a = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let ratio = new / zoom
        pan.x = a.x - (a.x - pan.x) * ratio
        pan.y = a.y - (a.y - pan.y) * ratio
        zoom = new
        scaleMode = .manual
        clampPan()
    }

    mutating func zoomStep(_ dir: Int) {
        let levels = Config.zoomLevels
        if dir > 0 {
            if let next = levels.first(where: { $0 > zoom + 0.001 }) { setZoom(next) }
        } else {
            if let prev = levels.last(where: { $0 < zoom - 0.001 }) { setZoom(prev) }
        }
    }

    mutating func centerImage() {
        pan = CGPoint(x: (viewSize.width - displaySize.width) / 2,
                      y: (viewSize.height - displaySize.height) / 2)
        clampPan()
    }

    mutating func scroll(dx: CGFloat, dy: CGFloat) {
        pan.x += dx
        pan.y += dy
        clampPan()
    }

    mutating func scrollStep(_ direction: Direction, screenful: Bool) {
        let sx = screenful ? viewSize.width : viewSize.width / Config.panFraction
        let sy = screenful ? viewSize.height : viewSize.height / Config.panFraction
        switch direction {
        case .left: scroll(dx: sx, dy: 0)
        case .right: scroll(dx: -sx, dy: 0)
        case .up: scroll(dx: 0, dy: -sy)
        case .down: scroll(dx: 0, dy: sy)
        }
    }

    mutating func scrollToEdge(_ direction: Direction) {
        switch direction {
        case .left: pan.x = 0
        case .right: pan.x = viewSize.width - displaySize.width
        case .up: pan.y = viewSize.height - displaySize.height
        case .down: pan.y = 0
        }
        clampPan()
    }

    private mutating func applyScaleMode() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let zw = viewSize.width / imageSize.width, zh = viewSize.height / imageSize.height
        switch scaleMode {
        case .fit: zoom = min(zw, zh)
        case .down: zoom = min(1, min(zw, zh))
        case .width: zoom = zw
        case .height: zoom = zh
        case .fill: zoom = max(zw, zh)
        case .manual: break
        }
        zoom = max(Self.zoomRange.lowerBound, min(Self.zoomRange.upperBound, zoom))
        centerImage()
    }

    private mutating func clampPan() {
        let ds = displaySize
        if ds.width <= viewSize.width {
            pan.x = (viewSize.width - ds.width) / 2
        } else {
            pan.x = min(0, max(viewSize.width - ds.width, pan.x))
        }
        if ds.height <= viewSize.height {
            pan.y = (viewSize.height - ds.height) / 2
        } else {
            pan.y = min(0, max(viewSize.height - ds.height, pan.y))
        }
    }
}
