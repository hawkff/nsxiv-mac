#!/bin/sh
# Runs the Linux build as a floating window of niri, nested in a headless sway: a window rule
# opens it 10 pixels from the bottom-right corner, and the slideshow's second image needs
# most of the screen. The grown window must stay inside niri's output; niri's IPC reports
# where it is.
set -eu
bin=$1
pics=$(mktemp -d)
conf=$(mktemp -d)
magick -size 200x200 xc:green "$pics/1-small.png"
magick -size 1200x700 gradient:red-blue "$pics/2-large.png"

XDG_RUNTIME_DIR=$(mktemp -d)
XDG_CURRENT_DESKTOP=niri
export XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK NIRI_SOCKET
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

echo 'output HEADLESS-1 resolution 1600x1000' >"$conf/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$conf/sway.conf" &
sway=$!
host=$(next_socket)
cat >"$conf/niri.kdl" <<'EOF'
window-rule {
    match app-id="nsxiv-mac"
    open-floating true
    default-floating-position x=10 y=10 relative-to="bottom-right"
}
hotkey-overlay {
    skip-at-startup
}
EOF
WAYLAND_DISPLAY=$host LIBGL_ALWAYS_SOFTWARE=1 niri -c "$conf/niri.kdl" &
niri=$!
nested=$(next_socket "$host")
for _ in $(seq 100); do
    for candidate in "$XDG_RUNTIME_DIR"/niri.*.sock; do [ -S "$candidate" ] && NIRI_SOCKET=$candidate; done
    [ -n "${NIRI_SOCKET:-}" ] && break
    sleep 0.1
done
export NIRI_SOCKET

WAYLAND_DISPLAY=$nested "$bin" -S 4 "$pics" &
pid=$!
sleep 6 # the large image shows from 4 to 8 seconds
kill -0 "$pid"
output=$(niri msg --json outputs | jq -c '[.[] | .logical][0] | [.width, .height]')
window=$(niri msg --json windows | jq -c --argjson pid "$pid" '.[] | select(.pid == $pid) |
    [.is_floating, .layout.tile_pos_in_workspace_view[0], .layout.tile_pos_in_workspace_view[1], .layout.tile_size[0], .layout.tile_size[1]]')
echo "output: $output; window (floating, x, y, width, height): $window"
# shellcheck disable=SC2046
set -- $(echo "$output $window" | tr -d '[]' | tr ',' ' ')
[ "$3" = true ] || { echo "the window is not floating" >&2; exit 1; }
w=$1 h=$2 x=${4%.*} y=${5%.*} tw=${6%.*} th=${7%.*}
[ "$tw" -gt 300 ] || { echo "the window did not grow for the large image" >&2; exit 1; }
[ "$x" -ge 0 ] && [ "$y" -ge 0 ] && [ $((x + tw)) -le "${w%.*}" ] && [ $((y + th)) -le "${h%.*}" ] ||
    { echo "the grown window ran past niri's output" >&2; exit 1; }
