#!/bin/sh
# Runs the Linux build in a headless Hyprland on a 1280x800 output, with the viewer floating
# near the bottom-right corner. The slideshow's second image needs most of the screen; the
# viewer must grow only as far as the screen allows. hyprctl reports where the window is.
set -eu
bin=$1
pics=$(mktemp -d)
log=$(mktemp)
conf=$(mktemp --suffix=.conf)
magick -size 200x200 xc:green "$pics/1-small.png"
magick -size 1200x700 gradient:red-blue "$pics/2-large.png"

XDG_RUNTIME_DIR=$(mktemp -d)
XDG_CURRENT_DESKTOP=Hyprland
export XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE
trap 'kill ${pid:-} ${hypr:-} 2>/dev/null || true' EXIT
fail() { echo "$1" >&2; tail -60 "$log" >&2; exit 1; }
cat >"$conf" <<'EOF'
monitor = , 1280x800, 0x0, 1
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
EOF
HYPRLAND_HEADLESS_ONLY=1 Hyprland --config "$conf" >"$log" 2>&1 &
hypr=$!
for _ in $(seq 100); do
    for dir in "$XDG_RUNTIME_DIR"/hypr/*; do [ -S "$dir/.socket.sock" ] && HYPRLAND_INSTANCE_SIGNATURE=$(basename "$dir"); done
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && break
    sleep 0.2
done
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || fail "Hyprland did not start"
export HYPRLAND_INSTANCE_SIGNATURE
hyprctl -j monitors | jq -e 'length > 0' >/dev/null || hyprctl output create headless HEADLESS-2
monitor=$(hyprctl -j monitors | jq -c '.[0] | [.x, .y, .width, .height, .reserved]')
echo "monitor: $monitor"
socket=
for candidate in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do [ -S "$candidate" ] && socket=$(basename "$candidate"); done
[ -n "$socket" ] || fail "Hyprland opened no Wayland socket"

WAYLAND_DISPLAY=$socket "$bin" -S 4 "$pics" &
pid=$!
sleep 1.5
hyprctl dispatch setfloating "pid:$pid"
hyprctl dispatch movewindowpixel "exact 1000 500,pid:$pid"
sleep 4.5 # the large image shows from 4 to 8 seconds
kill -0 "$pid"
window=$(hyprctl -j clients | jq -c --argjson pid "$pid" '.[] | select(.pid == $pid) | [.at[0], .at[1], .size[0], .size[1]]')
echo "window: $window"
[ -n "$window" ] || fail "hyprctl lists no viewer window"
# shellcheck disable=SC2046
set -- $(echo "$window" | tr -d '[]' | tr ',' ' ')
[ "$3" -gt 220 ] || fail "the window did not grow for the large image"
[ "$1" -ge 0 ] && [ "$2" -ge 0 ] && [ $(($1 + $3)) -le 1280 ] && [ $(($2 + $4)) -le 800 ] ||
    fail "the grown window ran past the screen edge"
