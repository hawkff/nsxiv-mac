#if os(macOS)
import AppKit
#else
import Foundation
#endif

// a key-handler that stops reading its stdin must not kill the viewer
signal(SIGPIPE, SIG_IGN)

#if os(Linux)
// the terminal frontend's helper, which makes frames ahead in a process of its own
if CommandLine.arguments.dropFirst().first == "--frame-ahead" { TerminalUI.runAheadHelper() }
#endif

var options = Options.parse(Array(CommandLine.arguments.dropFirst()))

if options.cleanCache {
    // on macOS the system keeps the thumbnails, and clears them itself
    #if os(Linux)
    ImlibRenderer.cleanThumbnailCache()
    #endif
    exit(0)
}

var inputPaths = options.paths
if options.readStdin {
    while let line = readLine(strippingNewline: true) {
        if !line.isEmpty { inputPaths.append(line) }
    }
}

if inputPaths.isEmpty {
    FileHandle.standardError.write(Data((Options.usage + "\n").utf8))
    exit(2)
}

var files = FileList.build(paths: inputPaths, recursive: options.recursive, quiet: options.quiet)
if let path = options.startFile { options.startAt = FileList.start(at: path, in: &files, quiet: options.quiet) }
if files.isEmpty {
    warn("no images to display")
    exit(1)
}

#if os(macOS)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController(options: options, files: files)
app.delegate = controller
app.run()
#else
// a Wayland session gets a Wayland window; X11, or XWayland with WAYLAND_DISPLAY unset, an X one;
// with no display, as over SSH on a headless machine, the terminal shows the images
let viewer = Viewer(options: options, files: files)
if let wayland = WaylandUI(viewer: viewer) { wayland.run() }
if let x11 = X11UI(viewer: viewer) { x11.run() }
if let terminal = TerminalUI(viewer: viewer) { terminal.run() }
warn("cannot open display \(ProcessInfo.processInfo.environment["DISPLAY"] ?? "(DISPLAY unset)")")
exit(1)
#endif
