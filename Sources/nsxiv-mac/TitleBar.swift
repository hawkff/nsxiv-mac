import AppKit

// Window chrome after mpv's video/out/mac/title_bar.swift: the image fills
// the whole window, and the title bar fades in over it while the mouse is
// near the top edge.
final class TitleBar: NSVisualEffectView {
    static let height = NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height

    // traffic lights, title, and proxy icon live in this system view
    private var systemBar: NSView? { window?.standardWindowButton(.closeButton)?.superview }

    static func install(in window: NSWindow) {
        guard let content = window.contentView else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        let bar = TitleBar(frame: CGRect(x: 0, y: content.bounds.height - height,
                                         width: content.bounds.width, height: height))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.autoresizingMask = [.width, .minYMargin]
        bar.alphaValue = 0
        content.addSubview(bar, positioned: .above, relativeTo: nil)
        content.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: bar, userInfo: nil))
        bar.systemBar?.alphaValue = 0
        // fullscreen transitions happen without mouse movement; re-apply the state
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(bar, selector: #selector(TitleBar.hide),
                                                   name: name, object: window)
        }
    }

    // drag on the visible bar moves the window, as the real title bar would
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hide), object: nil)
        fade(to: 1)
        if !bounds.contains(convert(event.locationInWindow, from: nil)) {
            perform(#selector(hide), with: nil, afterDelay: 0.5)
        }
    }

    override func mouseExited(with event: NSEvent) { hide() }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.zoom(self) }
    }

    @objc private func hide(_ sender: Any? = nil) { fade(to: 0) }

    private func fade(to alpha: CGFloat) {
        // native fullscreen slides the system bar in with the menu bar; leave
        // it opaque there and keep the blur strip out of the way
        let fullscreen = window?.styleMask.contains(.fullScreen) == true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            systemBar?.animator().alphaValue = fullscreen ? 1 : alpha
            animator().alphaValue = fullscreen ? 0 : alpha
        }
    }
}
