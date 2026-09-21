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

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingHead // "…name", like nsxiv's statusbar
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Config.barFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let pad: CGFloat = 8
        let right = NSAttributedString(string: rightText, attributes: attrs)
        let rightSize = right.size()
        let y = (bounds.height - rightSize.height) / 2
        right.draw(at: CGPoint(x: bounds.width - rightSize.width - pad, y: y))

        // draw(in:) lays the line out from the rect's top edge; -y puts that edge at y + line height
        let leftRect = CGRect(x: pad, y: -y, width: bounds.width - rightSize.width - pad * 3,
                              height: bounds.height)
        NSAttributedString(string: leftText, attributes: attrs).draw(in: leftRect)
    }
}
