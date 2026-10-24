#!/bin/sh
# Runs the Linux build in a headless mutter, GNOME's compositor, and checks that a window
# that grows for a larger image stays on screen. mutter puts the small first window in the
# middle, and the slideshow's second image needs most of the screen: grown from its top-left
# corner, the window would run past the bottom-right edge. Run under dbus-run-session.
set -eu
bin=$1
pics=$(mktemp -d)
magick -size 200x200 xc:green "$pics/1-small.png"
magick -size 1200x700 gradient:red-blue "$pics/2-large.png"
log=$(mktemp)

XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
trap 'kill ${pid:-} ${mutter:-} 2>/dev/null || true' EXIT
# mutter logs where a window asks to go, then where each constraint leaves it
MUTTER_DEBUG=geometry mutter --headless --virtual-monitor 1280x800 --no-x11 --wayland-display=wayland-m \
    2>"$log" &
mutter=$!
for _ in $(seq 100); do
    [ -S "$XDG_RUNTIME_DIR/wayland-m" ] && break
    sleep 0.1
done
[ -S "$XDG_RUNTIME_DIR/wayland-m" ] || { echo "mutter did not start" >&2; cat "$log" >&2; exit 1; }

WAYLAND_DISPLAY=wayland-m "$bin" -S 4 "$pics" &
pid=$!
sleep 6 # the large image shows from 4 to 8 seconds
kill -0 "$pid"

asked=$(sed -n 's/.*Constraining .* to \(-*[0-9]*\),\(-*[0-9]*\) \([0-9]*\)x\([0-9]*\)$/\1 \2 \3 \4/p' "$log" |
    awk '$3 >= 1000 && ($1 + $3 > 1280 || $2 + $4 > 800)' | head -1)
final=$(sed -n 's/.*info->current is \(-*[0-9]*\),\(-*[0-9]*\) \([0-9]*\)x\([0-9]*\) after.*/\1 \2 \3 \4/p' "$log" |
    awk '$3 >= 1000' | tail -1)
echo "asked for: ${asked:-nothing past the edge}; placed at: ${final:-nothing}"
[ -n "$asked" ] || { echo "the large image never asked to run past the edge" >&2; tail -40 "$log" >&2; exit 1; }
[ -n "$final" ] || { echo "mutter logged no placement for the large image" >&2; tail -40 "$log" >&2; exit 1; }
# shellcheck disable=SC2086
set -- $final
[ "$1" -ge 0 ] && [ "$2" -ge 0 ] && [ $(($1 + $3)) -le 1280 ] && [ $(($2 + $4)) -le 800 ] ||
    { echo "mutter left the grown window past the screen edge" >&2; exit 1; }
