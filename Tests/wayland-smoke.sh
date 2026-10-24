#!/bin/sh
# Drives the Linux build as a Wayland client of a headless sway at scale 1.5: still,
# turned, alpha and animated images, fullscreen, the grid, then -o with two marks.
# Screenshots land in $2.
set -eu
bin=$1
shots=$2
pics=$(mktemp -d)
mkdir -p "$shots"
magick -size 640x400 gradient:red-blue "$pics/1-gradient.png"
magick -size 200x200 xc:none -fill green -draw 'circle 100,100 100,20' "$pics/2-alpha.png"
magick -delay 20 -size 120x80 xc:red xc:lime xc:blue -loop 0 "$pics/3-animated.gif"
magick -size 300x300 plasma: "$pics/4-a-name-long-enough-to-lose-its-start-in-the-status-bar.jpg"

XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
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
unset DISPLAY # a Wayland window, not an X one through XWayland

shot() { sleep 1; grim "$shots/$1.png"; }

timeout 60 "$bin" -o "$pics" >"$pics/marked" & # a viewer that misses q fails the run
pid=$!
sleep 2
shot 1-image
wtype '>' && shot 2-turned
wtype j && shot 3-alpha
wtype A && shot 4-checkerboard
wtype j && shot 5-animated
wtype f && shot 6-fullscreen
wtype f g m m && wtype -k Return
sleep 2
shot 7-grid
wtype q
wait "$pid"
kill "$sway"
test "$(wc -l <"$pics/marked")" -eq 2
echo "marked: $(tr '\n' ' ' <"$pics/marked")"
