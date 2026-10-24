import Foundation

// Thumbnail grid geometry: one cell per item in a view of viewSize, origin at the
// top left, scrolled down by scrollY.
struct GridLayout {
    var count = 0 { didSet { clampScroll() } }
    var viewSize = CGSize.zero { didSet { clampScroll() } }
    private(set) var sizeIndex = Config.thumbSizeIndex
    private(set) var scrollY: CGFloat = 0

    var thumbSize: CGFloat { Config.thumbSizes[sizeIndex] }
    var cellSize: CGFloat { thumbSize + Config.thumbPadding * 2 }
    var columns: Int { max(1, Int(viewSize.width / cellSize)) }
    private var xInset: CGFloat { (viewSize.width - CGFloat(columns) * cellSize) / 2 }
    private var contentHeight: CGFloat { CGFloat((count + columns - 1) / columns) * cellSize }

    // the cell of item i as drawn, scroll applied
    func cellRect(_ i: Int) -> CGRect {
        CGRect(x: xInset + CGFloat(i % columns) * cellSize,
               y: CGFloat(i / columns) * cellSize - scrollY,
               width: cellSize, height: cellSize)
    }

    // items in view, plus one row below it so those thumbnails load early
    var visible: Range<Int> {
        let first = min(count, max(0, Int(scrollY / cellSize)) * columns)
        let end = min(count, (Int((scrollY + viewSize.height) / cellSize) + 2) * columns)
        return first..<max(first, end)
    }

    func index(at p: CGPoint) -> Int? {
        let x = p.x - xInset, y = p.y + scrollY
        guard x >= 0, x < CGFloat(columns) * cellSize, y >= 0 else { return nil }
        let i = Int(y / cellSize) * columns + Int(x / cellSize)
        return i < count ? i : nil
    }

    func neighbor(of i: Int, _ direction: Direction) -> Int {
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        }
        return max(0, min(count - 1, i + step))
    }

    mutating func reveal(_ i: Int) {
        let r = cellRect(i)
        if r.minY < 0 {
            scrollY += r.minY
        } else if r.maxY > viewSize.height {
            scrollY += r.maxY - viewSize.height
        }
        clampScroll()
    }

    mutating func scroll(by dy: CGFloat) {
        scrollY += dy
        clampScroll()
    }

    mutating func scrollPage(_ direction: Direction) {
        switch direction {
        case .up: scroll(by: -viewSize.height)
        case .down: scroll(by: viewSize.height)
        default: break
        }
    }

    // false at the smallest or largest thumbnail size
    mutating func zoom(_ dir: Int) -> Bool {
        guard Config.thumbSizes.indices.contains(sizeIndex + dir) else { return false }
        sizeIndex += dir
        clampScroll()
        return true
    }

    private mutating func clampScroll() {
        scrollY = max(0, min(scrollY, contentHeight - viewSize.height))
    }
}
