#!/bin/sh
# Runs the Linux build in Hyprland on a virtual 1024x768 display (vkms), as root in a
# container. Hyprland sizes a window when it maps it and keeps that size when the client
# resizes itself later, cutting off what lies past it. A window rule opens the viewer
# floating; when the slideshow's second image needs most of the screen, the viewer must fit
# it into the size Hyprland gave and never ask for room to grow. Hyprland draws no frames on
# such a display, so the check reads Hyprland's log and hyprctl instead of a screenshot.
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

WAYLAND_DISPLAY=$socket "$bin" -S 4 "$pics" &
pid=$!
# the viewer names its window after the image it shows
shown() { hyprctl -j clients | jq -e --argjson pid "$pid" 'any(.[]; .pid == $pid and .title == "2-large.png")' >/dev/null; }
for _ in $(seq 100); do shown && break; sleep 0.1; done
shown || fail "the viewer did not show the large image"
sleep 1 # a probe for room would have come by now
kill -0 "$pid"

window=$(hyprctl -j clients | jq -r --argjson pid "$pid" '.[] | select(.pid == $pid) | "\(.floating) \(.size[0])x\(.size[1])"')
echo "window (floating size): $window"
[ "${window%% *}" = true ] || fail "the window is not floating"
logs=$(cat "$log" "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE"/*.log 2>/dev/null || true)
echo "$logs" | grep 'Map request dispatched' || fail "Hyprland's log shows no window"
if echo "$logs" | grep 'gets unconstrained to'; then fail "the viewer asked for room to grow"; fi
