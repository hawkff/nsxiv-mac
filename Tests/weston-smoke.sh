#!/bin/sh
# Runs the Linux build in a headless Weston at scale 2. Like GNOME, Weston draws no
# decorations for Wayland windows, so the window draws its own title bar; Weston has no
# fractional scaling either, so the window uses the integer buffer scale. Screenshots
# land in $2.
set -eu
bin=$1
shots=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
pics=$(mktemp -d)
mkdir -p "$shots"
magick -size 640x400 gradient:red-blue "$pics/1-gradient.png"
magick -size 300x300 plasma: "$pics/2-plasma.jpg"

XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
unset DISPLAY
trap 'kill ${pid:-} ${weston:-} 2>/dev/null || true' EXIT
# --debug lets weston-screenshooter capture the output
weston --backend=headless --renderer=pixman --width=1280 --height=800 --scale=2 --idle-time=0 \
    --debug --socket=wayland-1 &
weston=$!
for _ in $(seq 100); do
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
    sleep 0.1
done
export WAYLAND_DISPLAY=wayland-1

"$bin" "$pics" &
pid=$!
sleep 3
(cd "$shots" && XDG_PICTURES_DIR=$shots weston-screenshooter)
for shot in "$shots"/wayland-screenshot*.png; do mv "$shot" "$shots/1-title-bar.png"; done
kill -0 "$pid" # a protocol error would have ended the viewer
# Weston places windows at random, so count the bar color: a 1280-pixel-wide window with a
# title bar and a status bar shows two bars of it, about 150000 pixels, and one bar half that
bar=$(magick "$shots/1-title-bar.png" -fill black +opaque '#eeeeee' -fill white -opaque '#eeeeee' \
    -format '%[fx:int(mean*w*h)]' info:)
echo "bar-colored pixels: $bar"
[ "$bar" -gt 110000 ] || { echo "no title bar above the status bar" >&2; exit 1; }
