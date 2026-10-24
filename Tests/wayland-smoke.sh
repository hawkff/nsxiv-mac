#!/bin/sh
# Drives the Linux build as a Wayland client of a headless sway at scale 1.5: still,
# turned, alpha and animated images, fullscreen, the grid, the key-handler, then -o
# with two marks. Screenshots land in $2.
set -eu
bin=$1
shots=$2
pics=$(mktemp -d)
mkdir -p "$shots"
magick -size 640x400 gradient:red-blue "$pics/1-gradient.png"
magick -size 200x200 xc:none -fill green -draw 'circle 100,100 100,20' "$pics/2-alpha.png"
magick -delay 20 -size 120x80 xc:red xc:lime xc:blue -loop 0 "$pics/3-animated.gif"
magick -size 300x300 plasma: "$pics/4-a-name-long-enough-to-lose-its-start-in-the-status-bar.jpg"

export XDG_CONFIG_HOME="$pics/config"
handler="$XDG_CONFIG_HOME/nsxiv-mac/exec/key-handler"
mkdir -p "$(dirname "$handler")"
printf '#!/bin/sh\n{ echo "key $1"; cat; } >"$0.ran"\n' >"$handler"
chmod +x "$handler"

XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
trap 'kill ${pid:-} ${sway:-} 2>/dev/null || true' EXIT
cat >"$pics/sway.conf" <<'EOF'
output HEADLESS-1 resolution 1280x800 scale 1.5
for_window [app_id="nsxiv-mac"] floating enable
EOF
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$pics/sway.conf" &
sway=$!
socket=
for _ in $(seq 100); do
    for candidate in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do
        [ -S "$candidate" ] && socket=$candidate
    done
    [ -n "$socket" ] && break
    sleep 0.1
done
WAYLAND_DISPLAY=$(basename "$socket")
export WAYLAND_DISPLAY
for _ in $(seq 100); do
    for candidate in "$XDG_RUNTIME_DIR"/sway-ipc.*.sock; do [ -S "$candidate" ] && SWAYSOCK=$candidate; done
    [ -n "${SWAYSOCK:-}" ] && break
    sleep 0.1
done
export SWAYSOCK # the viewer places its floating window through sway's IPC
unset DISPLAY # a Wayland window, not an X one through XWayland

shot() { sleep 1; grim "$shots/$1.png"; }
# the floating window takes each image's size; sway's geometry field keeps the first one
expect_width() {
    width=$(swaymsg -t get_tree | jq '.. | objects | select(.app_id == "nsxiv-mac") | .window_rect.width')
    [ "$width" = "$1" ] || { echo "window is $width wide, expected $1" >&2; exit 1; }
}
# the whole window, sway's title bar included, stays inside the workspace
expect_inside() {
    swaymsg -t get_tree | jq -e '[.. | objects | select(.type == "workspace" and .name == "1") | .rect] as [$w]
        | .. | objects | select(.app_id == "nsxiv-mac") | .rect
        | .x >= $w.x and .y >= $w.y and .x + .width <= $w.x + $w.width and .y + .height <= $w.y + $w.height' \
        >/dev/null || { echo "window left the workspace: $(swaymsg -t get_tree | jq -c '.. | objects |
            select(.app_id == "nsxiv-mac" or .type == "workspace") | .rect')" >&2; exit 1; }
}
# each wtype plugs in a new virtual keyboard; the pause lets the client bind it first
key() { wtype -s 300 "$@"; }

timeout 60 "$bin" -o "$pics" >"$pics/marked" & # a viewer that misses q fails the run
pid=$!
sleep 2
shot 1-image
key '>' && shot 2-turned && expect_inside
key j && shot 3-alpha && expect_width 200
key A && shot 4-checkerboard
key j && shot 5-animated
key f && shot 6-fullscreen
key f && sleep 1
key g m m -k Return
sleep 2
shot 7-grid && expect_inside
key -M ctrl x -m ctrl c
sleep 1
key q
wait "$pid"
test "$(wc -l <"$pics/marked")" -eq 2
test "$(cat "$handler.ran")" = "key c
$(cat "$pics/marked")"
echo "marked and passed to the key-handler: $(tr '\n' ' ' <"$pics/marked")"
