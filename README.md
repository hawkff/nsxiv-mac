# nsxiv-mac

A native macOS rewrite of [nsxiv](https://github.com/nsxiv/nsxiv)'s
keyboard-driven image viewing. Swift on AppKit, ImageIO, and Vision. No
third-party dependencies. Requires macOS 13 or later.

## Features

- Image mode: zoom, pan, rotate, flip, gamma and contrast correction
- Window in the style of mpv: the image fills it, the title bar fades in at the top edge
- Thumbnail grid with a disk cache in `~/Library/Caches/nsxiv-mac`
- Plays animated GIF, APNG, and WebP; steps through single frames
- Reloads the image when the file changes on disk
- Marks for batch workflows; `-o` prints marked files on exit
- Edit mode: annotate, censor, OCR (press `x`)
- Shell scripting through a `key-handler`, same protocol as nsxiv
- Slideshow
- nsxiv keybindings and CLI flags
- Opens JPEG, PNG, GIF, WebP, HEIC, AVIF, TIFF, and camera RAW via ImageIO

## Build

```sh
swift build -c release
```

The binary lands in `.build/release/nsxiv-mac`. Copy it into your `$PATH`.

## Usage

```sh
nsxiv-mac [-bfiopqrtv] [-g WxH] [-n NUM] [-S DELAY] [-s MODE] [-z ZOOM] FILE...

nsxiv-mac ~/Pictures                     # every image in a directory
nsxiv-mac -r ~/Pictures                  # recurse into subdirectories
fd -e jpg | nsxiv-mac -i                 # read the file list from stdin
nsxiv-mac -o *.jpg > picked.txt          # mark with 'm', quit; marked paths print to stdout
```

## Keybindings

nsxiv defaults, adjusted where noted:

| Key | Action |
| --- | --- |
| `q` / `Q` | quit / pick-quit (print current file) |
| `Return` | switch image/thumbnail mode |
| `f` | fullscreen |
| `b` | toggle status bar |
| `j` `k` | next / previous image |
| `[` `]` | jump 10 forward / back |
| `g` `G` | first / last image |
| `h` `l` `u` `d`, arrows | pan image; `h j k l` moves the thumbnail selection |
| `H` `J` `K` `L` | pan to edge |
| `C-h/j/k/l` | pan a full screen; page the thumbnail grid |
| `+` `-` | zoom in / out; resize thumbnails in the grid |
| `=` | zoom 100% |
| `w` `W` `F` `e` `E` | scale mode: down, fit, fill, width, height |
| `z` | center image |
| `<` `>` `?` | rotate 90° CCW / 90° CW / 180° |
| `\|` `_` | flip horizontal / vertical |
| `{` `}` / `(` `)` | gamma / contrast down, up |
| `C-g` | reset gamma |
| `a` `A` | toggle antialiasing / alpha checkerboard |
| `x` | edit mode (see below) |
| `m` `M` | mark image / mark range |
| `C-m` `C-u` | reverse / clear all marks |
| `N` `P` | next / previous marked image |
| `r` / `R` | reload image / rebuild all thumbnails |
| `D` | remove image from the list |
| `s` / `S` | toggle slideshow / increase delay |
| `C-n` `C-p` | next / previous animation frame |
| `C-Space` `C-a` | toggle animation playback |
| `C-6` | alternate image (last shown) |
| `C-x KEY` | pass KEY and the file list to your key-handler |

Mouse: click near the left or right edge to navigate, drag to pan, right-click
to switch modes. The scroll wheel zooms; a trackpad pans and pinch-zooms. Move
the mouse to the top edge to show the title bar; drag it to move the window,
double-click it to zoom.

## Edit mode

Press `x` on an image to annotate it. The tool set follows
[macshot](https://github.com/sw33tLie/macshot). The status bar names the
active tool. Annotations stay editable until you leave: `w` writes
`name-edit.png` next to the original and opens it, `q` discards. nsxiv-mac
never modifies the source file.

| Key | Tool |
| --- | --- |
| `v` | select: click an annotation, drag to move, corner handles resize, `D` or `Delete` removes, double-click text to re-edit |
| `a` | arrow |
| `r` / `e` | rectangle / ellipse; `f` cycles stroke, stroke+fill, fill |
| `t` | text: click to place, type, `Esc` commits |
| `p` / `m` | pencil / marker, freeform with smoothing |
| `n` | numbered marker, auto-increments |
| `s` | emoji stamp; `<` `>` cycles 21 emojis |
| `c` | censor a dragged region; `C` cycles pixelate, blur, solid |
| `h` | spotlight: the region stays bright, the rest dims |

| Key | Action |
| --- | --- |
| `1`-`8` | color: red, orange, yellow, green, blue, purple, black, white |
| `[` `]` | stroke width |
| `{` `}` | font and emoji size |
| `u` / `U`, `Cmd-Z` | undo / redo |
| `Space` (held) | move the shape you are drawing without resizing it |
| `o` | OCR the image (Apple Vision, auto language) and copy the text |
| `Q` | read QR codes and barcodes, copy the payloads |
| `F` | censor every detected face |
| `P` | censor PII found by OCR: emails, phone numbers, cards, SSNs, API keys |
| `I` | invert colors; press twice to revert |
| `B` | remove the background (Apple Vision, macOS 14+) |
| `Cmd-C` | copy the flattened image to the clipboard |
| `w` / `Cmd-S` | save as `name-edit.png` and open it |
| `q` / `Esc` | discard and return to viewing |

## key-handler

Place an executable at `~/.config/nsxiv-mac/exec/key-handler`. After you press
`C-x` in the viewer, the next key arrives as `$1` and the marked files (or the
current file) arrive on stdin, one path per line. `etc/key-handler.example`
ships clipboard, trash, and reveal-in-Finder actions.

## File manager integration

`etc/nsxiv-rifle` opens a single image and lets you browse its whole
directory, starting at that file. For yazi, register it as an opener:

```toml
[opener]
nsxiv = [
  { run = 'nsxiv-rifle "$@"', desc = "nsxiv-mac", for = "unix" },
]

[open]
prepend_rules = [
  { mime = "image/*", use = "nsxiv" },
]
```

## Configuration

Compile-time constants live in `Sources/nsxiv-mac/Config.swift`, the
`config.h` of this project: zoom levels, thumbnail sizes, slideshow delay,
window size, image extensions. Edit and rebuild.

## License

MIT.
