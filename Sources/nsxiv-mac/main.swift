import AppKit

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

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

let files = FileList.build(paths: inputPaths, recursive: options.recursive, quiet: options.quiet)
if files.isEmpty {
    warn("no images to display")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController(options: options, files: files)
app.delegate = controller
app.run()
