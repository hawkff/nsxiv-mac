import AppKit
import CoreImage
import CoreText

enum EditTool: CaseIterable {
    case select, arrow, rect, ellipse, text, pencil, marker, badge, stamp, censor, spotlight
}

enum FillMode: CaseIterable { case stroke, strokeFill, fill }

enum CensorMode: CaseIterable {
    case pixelate, blur, solid
}

// All geometry is in image pixel coordinates, bottom-left origin
// (the same space CGImage drawing and Vision rects use).
struct Annotation: Identifiable {
    let id = UUID()
    var tool: EditTool
    var start = CGPoint.zero
    var end = CGPoint.zero
    var points: [CGPoint] = []
    var text = ""
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fillMode: FillMode = .stroke
    var censorMode: CensorMode = .pixelate
    var number = 1
    var fontSize: CGFloat = 28

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var textBounds: CGRect {
        let lines = text.components(separatedBy: "\n")
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        var width: CGFloat = 0
        for line in lines {
            let s = NSAttributedString(string: line, attributes: [.font: font])
            width = max(width, s.size().width)
        }
        let lineH = fontSize * 1.25
        let height = CGFloat(lines.count) * lineH
        return CGRect(x: start.x, y: start.y - height + fontSize, width: width, height: height)
    }

    var badgeRadius: CGFloat { 14 + lineWidth * 2 }
    var stampBounds: CGRect {
        let s = fontSize * 3
        return CGRect(x: start.x - s / 2, y: start.y - s / 2, width: s, height: s)
    }

    func moved(by d: CGPoint) -> Annotation {
        var a = self
        a.start.x += d.x; a.start.y += d.y
        a.end.x += d.x; a.end.y += d.y
        a.points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return a
    }

    func hit(_ p: CGPoint) -> Bool {
        // marker draws 5x wider than lineWidth; match the visible stroke
        let slop = max(10, tool == .marker ? lineWidth * 2.5 : lineWidth)
        switch tool {
        case .arrow:
            return Annotation.segmentDistance(p, start, end) < slop
        case .rect, .ellipse, .censor, .spotlight:
            if fillMode != .stroke || tool == .censor || tool == .spotlight {
                return rect.insetBy(dx: -slop, dy: -slop).contains(p)
            }
            let outer = rect.insetBy(dx: -slop, dy: -slop)
            let inner = rect.insetBy(dx: slop, dy: slop)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .pencil, .marker:
            guard points.count > 1 else { return false }
            for i in 1..<points.count
            where Annotation.segmentDistance(p, points[i - 1], points[i]) < slop {
                return true
            }
            return false
        case .text:
            return textBounds.insetBy(dx: -slop, dy: -slop).contains(p)
        case .badge:
            return hypot(p.x - start.x, p.y - start.y) < badgeRadius + slop
        case .stamp:
            return stampBounds.contains(p)
        case .select:
            return false
        }
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

enum AnnotationRenderer {
    private static let ciContext = CIContext()
    private static var censorCache: [String: CGImage] = [:]

    static func drawAll(_ annotations: [Annotation], base: CGImage?, ctx: CGContext,
                        imageSize: CGSize, selection: UUID? = nil, handleScale: CGFloat = 0) {
        let spots = annotations.filter { $0.tool == .spotlight }
        if !spots.isEmpty {
            drawSpotlightDim(spots, ctx: ctx, imageSize: imageSize)
        }
        for a in annotations {
            draw(a, base: base, ctx: ctx, imageSize: imageSize)
        }
        if let selection, handleScale > 0,
           let sel = annotations.first(where: { $0.id == selection }) {
            drawSelection(sel, ctx: ctx, scale: handleScale)
        }
    }

    static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext.rgba(width: w, height: h) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        drawAll(annotations, base: base, ctx: ctx,
                imageSize: CGSize(width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - single annotation

    private static func draw(_ a: Annotation, base: CGImage?, ctx: CGContext, imageSize: CGSize) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineJoin(.round)

        switch a.tool {
        case .arrow: drawArrow(a, ctx: ctx)
        case .rect: drawShape(a, ctx: ctx, path: CGPath(rect: a.rect, transform: nil))
        case .ellipse: drawShape(a, ctx: ctx, path: CGPath(ellipseIn: a.rect, transform: nil))
        case .pencil: drawStroke(a, ctx: ctx, width: a.lineWidth, alpha: 1)
        case .marker:
            ctx.setBlendMode(.multiply)
            drawStroke(a, ctx: ctx, width: a.lineWidth * 5, alpha: 0.45)
        case .text: drawText(a.text, at: a.start, font: NSFont.boldSystemFont(ofSize: a.fontSize),
                             color: a.color, ctx: ctx)
        case .badge: drawBadge(a, ctx: ctx)
        case .stamp:
            drawText(a.text, at: CGPoint(x: a.stampBounds.minX, y: a.start.y - a.fontSize),
                     font: NSFont.systemFont(ofSize: a.fontSize * 2.4), color: a.color, ctx: ctx)
        case .censor: drawCensor(a, base: base, ctx: ctx, imageSize: imageSize)
        case .spotlight: drawSpotlightBorder(a, ctx: ctx)
        case .select: break
        }
    }

    private static func drawArrow(_ a: Annotation, ctx: CGContext) {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let head = max(12, a.lineWidth * 4)
        let tip = a.end
        let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
        ctx.setLineCap(.round)
        ctx.move(to: a.start)
        ctx.addLine(to: base)
        ctx.strokePath()
        let px = -uy, py = ux
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: base.x + px * head * 0.5, y: base.y + py * head * 0.5))
        ctx.addLine(to: CGPoint(x: base.x - px * head * 0.5, y: base.y - py * head * 0.5))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawShape(_ a: Annotation, ctx: CGContext, path: CGPath) {
        ctx.addPath(path)
        switch a.fillMode {
        case .stroke:
            ctx.strokePath()
        case .strokeFill:
            ctx.setFillColor(a.color.withAlphaComponent(0.3).cgColor)
            ctx.drawPath(using: .fillStroke)
        case .fill:
            ctx.fillPath()
        }
    }

    private static func drawStroke(_ a: Annotation, ctx: CGContext, width: CGFloat, alpha: CGFloat) {
        guard a.points.count > 1 else { return }
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(a.color.withAlphaComponent(alpha).cgColor)
        ctx.move(to: a.points[0])
        // smooth: quad curves through midpoints
        for i in 1..<a.points.count - 1 {
            let mid = CGPoint(x: (a.points[i].x + a.points[i + 1].x) / 2,
                              y: (a.points[i].y + a.points[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: a.points[i])
        }
        ctx.addLine(to: a.points[a.points.count - 1])
        ctx.strokePath()
    }

    private static func drawText(_ text: String, at origin: CGPoint, font: NSFont,
                                 color: NSColor, ctx: CGContext) {
        guard !text.isEmpty else { return }
        let lineH = font.pointSize * 1.25
        var y = origin.y
        for line in text.components(separatedBy: "\n") {
            let attr = NSAttributedString(string: line, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
            ])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: origin.x, y: y)
            CTLineDraw(ctLine, ctx)
            y -= lineH
        }
    }

    private static func drawBadge(_ a: Annotation, ctx: CGContext) {
        let r = a.badgeRadius
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        ctx.fillEllipse(in: circle)
        let font = NSFont.boldSystemFont(ofSize: r)
        let attr = NSAttributedString(string: "\(a.number)", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: NSColor.white.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: a.start.x - w / 2, y: a.start.y - r * 0.35)
        CTLineDraw(line, ctx)
    }

    private static func drawCensor(_ a: Annotation, base: CGImage?, ctx: CGContext,
                                   imageSize: CGSize) {
        let r = a.rect.intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard !r.isEmpty else { return }
        if a.censorMode == .solid {
            ctx.setFillColor(a.color.cgColor)
            ctx.fill(r)
            return
        }
        guard let base, let piece = censoredPiece(a, rect: r, base: base, imageSize: imageSize)
        else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(r)
            return
        }
        ctx.draw(piece, in: r)
    }

    private static func censoredPiece(_ a: Annotation, rect: CGRect, base: CGImage,
                                      imageSize: CGSize) -> CGImage? {
        let basePtr = UInt(bitPattern: Unmanaged.passUnretained(base).toOpaque())
        let key = "\(a.id)-\(a.censorMode)-\(rect)-\(basePtr)"
        if let hit = censorCache[key] { return hit }
        if censorCache.count > 64 { censorCache.removeAll() }

        // CGImage.cropping uses a top-left origin; our rect is bottom-left
        let scaleX = CGFloat(base.width) / imageSize.width
        let scaleY = CGFloat(base.height) / imageSize.height
        let crop = CGRect(x: rect.minX * scaleX,
                          y: (imageSize.height - rect.maxY) * scaleY,
                          width: rect.width * scaleX,
                          height: rect.height * scaleY)
        guard let piece = base.cropping(to: crop) else { return nil }
        var ci = CIImage(cgImage: piece)
        switch a.censorMode {
        case .pixelate:
            let scale = max(8, min(rect.width, rect.height) / 12)
            let f = CIFilter(name: "CIPixellate")!
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(scale, forKey: kCIInputScaleKey)
            ci = f.outputImage ?? ci
        case .blur:
            let f = CIFilter(name: "CIGaussianBlur")!
            f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(14, forKey: kCIInputRadiusKey)
            ci = f.outputImage ?? ci
        case .solid:
            break
        }
        let out = ciContext.createCGImage(ci, from: CGRect(origin: .zero, size: crop.size))
        if let out { censorCache[key] = out }
        return out
    }

    private static func drawSpotlightDim(_ spots: [Annotation], ctx: CGContext,
                                         imageSize: CGSize) {
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: imageSize))
        for s in spots {
            path.addRect(s.rect)
        }
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(CGRect(origin: .zero, size: imageSize))
        ctx.restoreGState()
    }

    private static func drawSpotlightBorder(_ a: Annotation, ctx: CGContext) {
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(a.rect)
    }

    private static func drawSelection(_ a: Annotation, ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 * scale)
        ctx.setLineDash(phase: 0, lengths: [4 * scale, 3 * scale])
        let box = selectionBox(a)
        ctx.stroke(box.insetBy(dx: -4 * scale, dy: -4 * scale))
        ctx.setLineDash(phase: 0, lengths: [])
        for h in handlePoints(a) {
            let r = 4.5 * scale
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2))
            ctx.strokeEllipse(in: CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()
    }

    static func selectionBox(_ a: Annotation) -> CGRect {
        switch a.tool {
        case .text: return a.textBounds
        case .badge:
            let r = a.badgeRadius
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        case .stamp: return a.stampBounds
        case .pencil, .marker:
            guard let f = a.points.first else { return a.rect }
            var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
            for p in a.points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default: return a.rect
        }
    }

    static func handlePoints(_ a: Annotation) -> [CGPoint] {
        switch a.tool {
        case .arrow:
            return [a.start, a.end]
        case .rect, .ellipse, .censor, .spotlight:
            let r = a.rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        default:
            return []
        }
    }
}
