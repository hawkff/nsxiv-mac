#!/bin/sh
# Runs the Linux build in Hyprland on a virtual 1024x768 display (vkms), as root in a
# container. Window rules open the viewer floating with room to its right and below; when the
# slideshow's second image needs most of the screen, the viewer asks how much room it has
# through a popup that Hyprland must trim to the screen's work area, and the window must stay
# on screen. Hyprland draws no frames on such a display, so the check reads Hyprland's own log
# and hyprctl instead of a screenshot.
set -eu
bin=$1
pics=$(mktemp -d)
log=$(mktemp)
conf=$(mktemp --suffix=.conf)
magick -size 200x200 xc:green "$pics/1-small.png"
magick -size 1200x700 gradient:red-blue "$pics/2-large.png"

XDG_RUNTIME_DIR=$(mktemp -d)
XDG_CURRENT_DESKTOP=Hyprland
LIBSEAT_BACKEND=noop # no seat manager in a container; root opens the display itself
export XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP LIBSEAT_BACKEND
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE
trap 'kill ${pid:-} ${hypr:-} 2>/dev/null || true' EXIT
fail() { echo "$1" >&2; tail -60 "$log" >&2; exit 1; }
cat >"$conf" <<'EOF'
monitor = , preferred, auto, 1
windowrule = match:class ^(nsxiv-mac)$, float on
windowrule = match:class ^(nsxiv-mac)$, move 500 400
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
debug {
    disable_logs = false
}
EOF
Hyprland --i-am-really-stupid --config "$conf" >"$log" 2>&1 &
hypr=$!
for _ in $(seq 150); do
    for dir in "$XDG_RUNTIME_DIR"/hypr/*; do [ -S "$dir/.socket.sock" ] && HYPRLAND_INSTANCE_SIGNATURE=$(basename "$dir"); done
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && break
    sleep 0.2
done
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || fail "Hyprland did not start"
export HYPRLAND_INSTANCE_SIGNATURE
socket=
for candidate in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do [ -S "$candidate" ] && socket=$(basename "$candidate"); done
[ -n "$socket" ] || fail "Hyprland opened no Wayland socket"
# shellcheck disable=SC2046
set -- $(hyprctl -j monitors | jq -r '.[0] | "\(.width) \(.height)"')
w=$1 h=$2
echo "monitor: ${w}x$h"

WAYLAND_DISPLAY=$socket "$bin" -S 4 "$pics" &
pid=$!
sleep 6 # the large image shows from 4 to 8 seconds
kill -0 "$pid"

# Hyprland logs where it puts each popup; the probe asks for a 1048576-pixel square
trimmed=$(cat "$log" "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE"/*.log 2>/dev/null |
    grep 'gets unconstrained to' | tail -1)
echo "probe: ${trimmed:-none}"
[ -n "$trimmed" ] || fail "Hyprland got no room probe"
case $trimmed in *1048576*) fail "Hyprland left the room probe untrimmed" ;; esac

window=$(hyprctl -j clients | jq -r --argjson pid "$pid" '.[] | select(.pid == $pid) | "\(.floating) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
echo "window (floating x y width height): $window"
# shellcheck disable=SC2086
set -- $window
[ $# -eq 5 ] || fail "hyprctl lists no viewer window"
[ "$1" = true ] || fail "the window is not floating"
[ "$2" -ge 0 ] && [ "$3" -ge 0 ] && [ $(($2 + $4)) -le "$w" ] && [ $(($3 + $5)) -le "$h" ] ||
    fail "the window ran past the screen edge"
