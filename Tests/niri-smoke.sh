#!/bin/sh
# Runs the Linux build as a Wayland client of niri at scale 1.5, with niri nested in a
# headless sway that grim photographs: in a column whose width niri leaves to the
# window, then fullscreen, on the next image, then closed by niri. Screenshots land in $2.
set -eu
bin=$1
shots=$2
pics=$(mktemp -d)
mkdir -p "$shots"
magick -size 640x400 gradient:red-blue "$pics/1-gradient.png"
magick -size 300x300 plasma: "$pics/2-plasma.jpg"

XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
unset DISPLAY
trap 'kill ${pid:-} ${niri:-} ${sway:-} 2>/dev/null || true' EXIT

# the newest wayland-N socket in XDG_RUNTIME_DIR other than $1
next_socket() {
    for _ in $(seq 200); do
        for candidate in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do
            if [ -S "$candidate" ] && [ "$(basename "$candidate")" != "${1:-}" ]; then
                basename "$candidate"
                return
            fi
        done
        sleep 0.1
    done
    echo "no Wayland socket appeared" >&2
    exit 1
}

echo 'output HEADLESS-1 resolution 1600x1000' >"$pics/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$pics/sway.conf" &
sway=$!
host=$(next_socket)

cat >"$pics/niri.kdl" <<'EOF'
output "winit" {
    scale 1.5
}
window-rule {
    match app-id="nsxiv-mac"
    default-column-width {}
}
hotkey-overlay {
    skip-at-startup
}
EOF
WAYLAND_DISPLAY=$host LIBGL_ALWAYS_SOFTWARE=1 niri -c "$pics/niri.kdl" &
niri=$!
nested=$(next_socket "$host")
for _ in $(seq 100); do
    for candidate in "$XDG_RUNTIME_DIR"/niri.*.sock; do [ -S "$candidate" ] && NIRI_SOCKET=$candidate; done
    [ -n "${NIRI_SOCKET:-}" ] && break
    sleep 0.1
done
export NIRI_SOCKET

shot() { sleep 1; WAYLAND_DISPLAY=$host grim "$shots/$1.png"; }
# the column is as wide as the 640x400 gradient at 100%, the zoom it gets in a 617-high
# tile, and the window keeps the tile's height
expect_size() {
    niri msg windows
    size=$(niri msg windows | awk '/Window size:/ { print $3 "x" $5 }')
    [ "$size" = 640x617 ] || { echo "window is $size, expected 640x617" >&2; exit 1; }
}

WAYLAND_DISPLAY=$nested timeout 60 "$bin" "$pics" &
pid=$!
sleep 3
shot 1-tiled
expect_size
niri msg action fullscreen-window
shot 2-fullscreen
niri msg action fullscreen-window
shot 3-tiled-again
expect_size
WAYLAND_DISPLAY=$nested wtype -s 300 j
shot 4-next-image
# the viewer names its window after the image it shows
title=$(niri msg --json windows | jq -r '.[] | select(.app_id == "nsxiv-mac") | .title')
[ "$title" = 2-plasma.jpg ] || { echo "j showed $title, expected 2-plasma.jpg" >&2; exit 1; }
niri msg windows
niri msg action close-window
wait "$pid" # niri's close ends the viewer; a hang fails the timeout
