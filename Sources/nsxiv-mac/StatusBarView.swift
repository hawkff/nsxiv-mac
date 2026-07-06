import AppKit

final class StatusBarView: NSView {
    var leftText = "" { didSet { needsDisplay = true } }
    var rightText = "" { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Config.barFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let pad: CGFloat = 8
        let right = NSAttributedString(string: rightText, attributes: attrs)
        let rightSize = right.size()
        let y = (bounds.height - rightSize.height) / 2
        right.draw(at: CGPoint(x: bounds.width - rightSize.width - pad, y: y))

        let maxLeft = bounds.width - rightSize.width - pad * 3
        var leftStr = leftText
        var left = NSAttributedString(string: leftStr, attributes: attrs)
        // truncate with ellipsis like nsxiv's statusbar
        while left.size().width > maxLeft, leftStr.count > 1 {
            leftStr = "…" + leftStr.dropFirst(2)
            left = NSAttributedString(string: leftStr, attributes: attrs)
        }
        left.draw(at: CGPoint(x: pad, y: y))
    }
}
