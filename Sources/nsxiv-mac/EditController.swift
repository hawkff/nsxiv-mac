import AppKit
import UniformTypeIdentifiers

// Keyboard-driven edit mode. Entered with 'x' from image mode.
final class EditController {
    let canvas: EditCanvasView
    let session: EditSession
    private let statusUpdate: () -> Void
    private var textField: NSTextField?
    private var editingIndex: Int?

    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white,
    ]
    private var paletteIndex = 0

    static let emojis = ["✅", "❌", "⚠️", "❗", "⭐", "🔥", "👍", "👎", "💡", "🔒",
                         "🚫", "📌", "🎯", "🐛", "💯", "🤔", "😂", "🎉", "❤️", "🏴‍☠️", "🍆"]
    private var emojiIndex = 0

    init(base: CGImage, sourceURL: URL, statusUpdate: @escaping () -> Void) {
        session = EditSession(base: base, sourceURL: sourceURL)
        canvas = EditCanvasView()
        self.statusUpdate = statusUpdate
        canvas.session = session
        canvas.onStatusUpdate = statusUpdate
        canvas.onEditText = { [weak self] idx in self?.beginTextEdit(idx) }
    }

    var statusText: String {
        var parts = ["EDIT [\(session.tool.label)]"]
        switch session.tool {
        case .rect, .ellipse:
            let fm = session.fillMode == .stroke ? "stroke"
                : session.fillMode == .fill ? "fill" : "stroke+fill"
            parts.append(fm)
        case .censor:
            parts.append(session.censorMode.label)
        case .stamp:
            parts.append(session.emoji)
        case .badge:
            parts.append("#\(session.badgeCounter)")
        default:
            break
        }
        parts.append("w\(Int(session.lineWidth))")
        parts.append(colorName(session.color))
        if session.selection != nil { parts.append("sel") }
        parts.append("\(session.annotations.count) items")
        return parts.joined(separator: " | ")
    }

    private func colorName(_ c: NSColor) -> String {
        switch c {
        case .systemRed: return "red"
        case .systemOrange: return "orange"
        case .systemYellow: return "yellow"
        case .systemGreen: return "green"
        case .systemBlue: return "blue"
        case .systemPurple: return "purple"
        case .black: return "black"
        case .white: return "white"
        default: return "custom"
        }
    }

    // MARK: - key handling; returns nil if key means "exit edit mode"

    enum ExitAction { case save, discard }

    var isEditingText: Bool { textField != nil }

    func handleKey(_ event: NSEvent) -> ExitAction? {
        // while editing text inline, only intercept Escape; everything else
        // must reach the field (AppController passes those through)
        if textField != nil {
            if event.keyCode == 53 { endTextEdit(commit: true) } // esc commits
            return nil
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = chars

        if event.keyCode == 49 { // space held: reposition while drawing
            canvas.spaceDown = true
            return nil
        }

        if flags.contains(.command) {
            switch key {
            case "z": flags.contains(.shift) ? session.redo() : session.undo()
            case "s": return .save
            case "c": copyToClipboard()
            default: return nil
            }
            canvas.needsDisplay = true
            statusUpdate()
            return nil
        }

        switch key {
        // tools
        case "v": session.tool = .select
        case "a": session.tool = .arrow
        case "r": session.tool = .rect
        case "e": session.tool = .ellipse
        case "t": session.tool = .text
        case "p": session.tool = .pencil
        case "m": session.tool = .marker
        case "n": session.tool = .badge
        case "s": session.tool = .stamp
        case "c": session.tool = .censor
        case "h": session.tool = .spotlight

        // options
        case "f":
            let all = FillMode.allCases
            session.fillMode = all[(all.firstIndex(of: session.fillMode)! + 1) % all.count]
        case "C":
            let all = CensorMode.allCases
            session.censorMode = all[(all.firstIndex(of: session.censorMode)! + 1) % all.count]
        case "1", "2", "3", "4", "5", "6", "7", "8":
            paletteIndex = Int(key)! - 1
            session.color = Self.palette[paletteIndex]
            applyToSelection { $0.color = self.session.color }
        case "[": session.lineWidth = max(1, session.lineWidth - 1)
        case "]": session.lineWidth = min(24, session.lineWidth + 1)
        case "{": session.fontSize = max(10, session.fontSize - 4)
        case "}": session.fontSize = min(120, session.fontSize + 4)
        case "<":
            emojiIndex = (emojiIndex + Self.emojis.count - 1) % Self.emojis.count
            session.emoji = Self.emojis[emojiIndex]
        case ">":
            emojiIndex = (emojiIndex + 1) % Self.emojis.count
            session.emoji = Self.emojis[emojiIndex]

        // actions
        case "u": session.undo()
        case "U": session.redo()
        case "o": runOCR()
        case "Q": runQR()
        case "F": censorFaces()
        case "P": censorPII()
        case "I": invertColors()
        case "B": removeBackground()
        case "D": session.deleteSelected()
        case "w": return .save
        case "q": return .discard
        default:
            if event.specialKey == .delete || event.specialKey == .backspace {
                session.deleteSelected()
            } else if event.keyCode == 53 { // escape
                if session.selection != nil {
                    session.selection = nil
                } else {
                    return .discard
                }
            } else {
                return nil
            }
        }
        canvas.needsDisplay = true
        statusUpdate()
        return nil
    }

    func keyUp(_ event: NSEvent) {
        if event.keyCode == 49 { canvas.spaceDown = false }
    }

    private func applyToSelection(_ mutate: (inout Annotation) -> Void) {
        guard let idx = session.selectedIndex() else { return }
        mutate(&session.annotations[idx])
    }

    // MARK: - text editing overlay

    private func beginTextEdit(_ index: Int) {
        guard session.annotations.indices.contains(index) else { return }
        endTextEdit(commit: true)
        editingIndex = index
        let a = session.annotations[index]
        let origin = canvas.viewPoint(a.start)
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y - 4,
                                              width: max(220, canvas.bounds.width - origin.x - 20),
                                              height: a.fontSize * canvas.fitScale + 12))
        field.stringValue = a.text
        field.font = .boldSystemFont(ofSize: max(11, a.fontSize * canvas.fitScale))
        field.textColor = a.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.isBordered = true
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textCommitted)
        canvas.addSubview(field)
        canvas.window?.makeFirstResponder(field)
        textField = field
    }

    @objc private func textCommitted() {
        endTextEdit(commit: true)
    }

    func endTextEdit(commit: Bool) {
        guard let field = textField else { return }
        if commit, let idx = editingIndex, session.annotations.indices.contains(idx) {
            session.annotations[idx].text = field.stringValue
            if field.stringValue.isEmpty, session.annotations[idx].tool == .text {
                session.annotations.remove(at: idx)
            }
        }
        field.removeFromSuperview()
        textField = nil
        editingIndex = nil
        canvas.window?.makeFirstResponder(nil)
        canvas.needsDisplay = true
        statusUpdate()
    }

    // MARK: - vision actions

    private func runOCR() {
        let img = session.flattened() ?? session.base
        VisionTools.recognizeText(in: img) { [weak self] text, _ in
            guard self != nil else { return }
            if text.isEmpty {
                NSSound.beep()
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.flashStatus("OCR: \(text.count) chars copied")
        }
    }

    private func runQR() {
        let img = session.flattened() ?? session.base
        VisionTools.detectBarcodes(in: img) { [weak self] payloads in
            guard !payloads.isEmpty else {
                NSSound.beep()
                return
            }
            let joined = payloads.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
            self?.flashStatus("QR: copied \(payloads.count) payload(s)")
        }
    }

    private func censorFaces() {
        VisionTools.detectFaces(in: session.base) { [weak self] rects in
            guard let self else { return }
            guard !rects.isEmpty else {
                NSSound.beep()
                return
            }
            for r in rects {
                var a = Annotation(tool: .censor)
                a.start = r.origin
                a.end = CGPoint(x: r.maxX, y: r.maxY)
                a.censorMode = self.session.censorMode
                self.session.annotations.append(a)
            }
            self.session.redoStack.removeAll()
            self.canvas.needsDisplay = true
            self.flashStatus("censored \(rects.count) face(s)")
        }
    }

    private func censorPII() {
        VisionTools.recognizeText(in: session.base) { [weak self] _, words in
            guard let self else { return }
            let hits = VisionTools.findPII(in: words)
            guard !hits.isEmpty else {
                NSSound.beep()
                return
            }
            for r in hits {
                var a = Annotation(tool: .censor)
                a.start = r.origin
                a.end = CGPoint(x: r.maxX, y: r.maxY)
                a.censorMode = self.session.censorMode
                self.session.annotations.append(a)
            }
            self.session.redoStack.removeAll()
            self.canvas.needsDisplay = true
            self.flashStatus("censored \(hits.count) PII region(s)")
        }
    }

    private func invertColors() {
        guard let inverted = VisionTools.invert(session.base) else { return }
        session.base = inverted
        canvas.needsDisplay = true
    }

    private func removeBackground() {
        flashStatus("removing background…")
        VisionTools.removeBackground(from: session.base) { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.flashStatus("background removal needs macOS 14+ / no subject found")
                return
            }
            self.session.base = result
            self.canvas.needsDisplay = true
            self.flashStatus("background removed")
        }
    }

    // MARK: - output

    private var statusFlash: String?
    private var flashToken = 0
    var flashText: String? { statusFlash }

    private func flashStatus(_ msg: String) {
        statusFlash = msg
        flashToken &+= 1
        let token = flashToken
        statusUpdate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.statusFlash = nil
            self.statusUpdate()
        }
    }

    func copyToClipboard() {
        guard let img = session.flattened() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        flashStatus("copied to clipboard")
    }

    // Saves next to the original: pic.png -> pic-edit.png (never overwrites source)
    func save() -> URL? {
        guard let img = session.flattened() else { return nil }
        let src = session.sourceURL
        let base = src.deletingPathExtension().lastPathComponent
        let dir = src.deletingLastPathComponent()
        var n = 0
        var dest = dir.appendingPathComponent("\(base)-edit.png")
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            dest = dir.appendingPathComponent("\(base)-edit-\(n).png")
        }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]),
              (try? data.write(to: dest)) != nil else { return nil }
        return dest
    }
}
