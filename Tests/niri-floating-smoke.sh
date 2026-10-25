#!/bin/sh
# Runs the Linux build as a floating window of niri, nested in a headless sway: a window rule
# opens it 300 pixels from the bottom-right corner, and the slideshow's second image needs
# most of the screen. The window must grow into that room and stay inside niri's output;
# niri's IPC reports where it is.
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
    default-floating-position x=300 y=300 relative-to="bottom-right"
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
# the viewer names its window after the image it shows; wait for the large one in the grown
# window
window=
for _ in $(seq 100); do
    window=$(niri msg --json windows | jq -c --argjson pid "$pid" '.[] | select(.pid == $pid) | .layout as $l |
        {title, floating: .is_floating, x: $l.tile_pos_in_workspace_view[0], y: $l.tile_pos_in_workspace_view[1],
         width: $l.tile_size[0], height: $l.tile_size[1]}')
    [ "$(echo "$window" | jq '.title == "2-large.png" and .width > 400')" = true ] && break
    sleep 0.1
done
kill -0 "$pid"
output=$(niri msg --json outputs | jq -c '[.[] | .logical][0] | {width, height}')
echo "output: $output; window: $window"
[ -n "$window" ] || { echo "niri lists no viewer window" >&2; exit 1; }
# niri reports logical pixels, which may be fractional
problem=$(jq -rn --argjson o "$output" --argjson w "$window" '
    if $w.title != "2-large.png" then "the viewer did not show the large image"
    elif ($w.floating | not) then "the window is not floating"
    elif $w.width <= 400 then "the window did not grow into the room it had"
    elif $w.x < 0 or $w.y < 0 or $w.x + $w.width > $o.width or $w.y + $w.height > $o.height
    then "the grown window ran past the output"
    else empty end')
[ -z "$problem" ] || { echo "$problem" >&2; exit 1; }
