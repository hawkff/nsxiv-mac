import Foundation

enum ScaleMode: Codable {
    case down, fit, width, height, fill, manual
}

struct Options {
    var noBar = false
    var fullscreen = false
    var thumbnailMode = false
    var recursive = false
    var readStdin = false
    var outputMarked = false
    var quiet = false
    var privateMode = false
    var cleanCache = false
    var startAt = 1
    var slideshow: TimeInterval?
    var zoom: CGFloat?
    var scaleMode: ScaleMode?
    var geometry: CGSize?
    var startFile: String?
    var paths: [String] = []

    static let usage = """
    usage: \(Config.appName) [-bcfiopqrtv] [-g WxH] [-n NUM] [-S DELAY] [-s MODE] [-z ZOOM]
           [--start-file FILE] FILE...

      -b            do not show the status bar
      -c            remove the cached thumbnails of images that are gone, and exit
      -f            start in fullscreen
      -g WxH        fixed window size instead of fitting the window to each image
      -i            read file paths from stdin
      -n NUM        start at file number NUM
      -o            print marked files to stdout on quit
      -p            private mode, do not write a thumbnail cache
      -q            be quiet, disable warnings
      -r            search directories recursively
      -S DELAY      start slideshow with DELAY seconds between images
      -s MODE       set scale mode: d=down, f=fit, F=fill, w=width, h=height
      -t            start in thumbnail mode
      -v            print version and exit
      -z ZOOM       set zoom level in percent
      --start-file FILE
                    start at FILE, or show it alone if it is not among the files
    """

    static func parse(_ arguments: [String]) -> Options {
        var o = Options()
        var args = arguments
        var i = 0

        func value(_ flag: String) -> String {
            i += 1
            guard i < args.count else {
                warn("option \(flag) requires an argument")
                exit(2)
            }
            return args[i]
        }

        // a number out of range, or no number, ends with a message, as in nsxiv
        func invalid(_ flag: String, _ text: String) -> Never {
            warn("invalid argument for option \(flag): \(text)")
            exit(2)
        }

        func number(_ flag: String, in range: ClosedRange<Double>) -> Double {
            let text = value(flag)
            guard let number = Double(text), range.contains(number) else { invalid(flag, text) }
            return number
        }

        while i < args.count {
            let a = args[i]
            switch a {
            case "-b", "--no-bar": o.noBar = true
            case "-f", "--fullscreen": o.fullscreen = true
            case "-t", "--thumbnail": o.thumbnailMode = true
            case "-r", "--recursive": o.recursive = true
            case "-i", "--stdin": o.readStdin = true
            case "-o", "--output": o.outputMarked = true
            case "-q", "--quiet": o.quiet = true
            case "-p", "--private": o.privateMode = true
            case "-c", "--clean-cache": o.cleanCache = true
            case "-n", "--start-at":
                let text = value(a)
                guard let n = Int(text), n > 0 else { invalid(a, text) }
                o.startAt = n
            case "--start-file":
                o.startFile = value(a)
            case "-S", "--ss-delay":
                // at least a tenth of a second, and at most what nsxiv takes, which counts tenths in
                // 32 bits; the timer takes no delay of centuries
                o.slideshow = max(0.1, number(a, in: Double.leastNonzeroMagnitude...Double(UInt32.max) / 10))
            case "-z", "--zoom":
                o.zoom = CGFloat(number(a, in: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude) / 100)
            case "-s", "--scale-mode":
                switch value(a) {
                case "d": o.scaleMode = .down
                case "f": o.scaleMode = .fit
                case "F": o.scaleMode = .fill
                case "w": o.scaleMode = .width
                case "h": o.scaleMode = .height
                default:
                    warn("invalid scale mode, expected one of: d f F w h")
                    exit(2)
                }
            case "-g", "--geometry":
                let text = value(a), parts = text.lowercased().split(separator: "x")
                // a height that is no number may have an X geometry's position after it, as the
                // +10+10 in 800x600+10+10, which is left out
                let height = parts.last.flatMap { Double($0) ?? Double($0.prefix { !"+-".contains($0) }) }
                let pixels = 1...Double(Int16.max) // X11 counts a window's pixels in 16 bits
                guard parts.count == 2, let w = Double(parts[0]), let h = height,
                      pixels.contains(w), pixels.contains(h) else { invalid(a, text) }
                o.geometry = CGSize(width: w.rounded(), height: h.rounded())
            case "-v", "--version":
                print("\(Config.appName) \(Config.appVersion)")
                exit(0)
            case "-h", "--help":
                print(usage)
                exit(0)
            case "--":
                i += 1
                while i < args.count {
                    o.paths.append(args[i])
                    i += 1
                }
            default:
                // getopt-style clusters: -rt is -r -t, -n5 is -n 5
                if a.count > 2, a.hasPrefix("-"), !a.hasPrefix("--") {
                    let flag = a.prefix(2), rest = a.dropFirst(2)
                    let takesValue = "gnSsz".contains(flag.last!)
                    args.replaceSubrange(i...i, with: [String(flag), takesValue ? String(rest) : "-\(rest)"])
                    continue
                }
                if a.hasPrefix("-"), a.count > 1 {
                    warn("unknown option: \(a)")
                    FileHandle.standardError.write(Data((usage + "\n").utf8))
                    exit(2)
                }
                o.paths.append(a)
            }
            i += 1
        }
        return o
    }
}
