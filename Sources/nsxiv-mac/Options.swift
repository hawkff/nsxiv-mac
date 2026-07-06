import Foundation

enum ScaleMode {
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
    var startAt = 1
    var slideshow: TimeInterval?
    var zoom: CGFloat?
    var scaleMode: ScaleMode?
    var geometry: CGSize?
    var paths: [String] = []

    static let usage = """
    usage: \(Config.appName) [-bfiopqrtv] [-g WxH] [-n NUM] [-S DELAY] [-s MODE] [-z ZOOM] FILE...

      -b            do not show the status bar
      -f            start in fullscreen
      -g WxH        initial window size
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
    """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0

        func value(_ flag: String) -> String {
            i += 1
            guard i < args.count else {
                warn("option \(flag) requires an argument")
                exit(2)
            }
            return args[i]
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
            case "-n", "--start-at":
                o.startAt = Int(value(a)) ?? 1
            case "-S", "--ss-delay":
                o.slideshow = max(0.1, TimeInterval(value(a)) ?? Config.slideshowDelay)
            case "-z", "--zoom":
                if let z = Double(value(a)), z > 0 { o.zoom = CGFloat(z / 100) }
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
                let parts = value(a).lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                    o.geometry = CGSize(width: w, height: h)
                }
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
