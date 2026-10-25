#!/bin/sh
# Runs the Linux build in a headless mutter, GNOME's compositor, on $2 side-by-side 1280x800
# monitors (default 1), and checks that a window that grows for a larger image stays on
# screen. mutter puts the small first window in the middle of a monitor, and the slideshow's
# second image needs most of it: grown from its top-left corner, the window would run past
# the monitor's bottom-right edge, and mutter must move it back. mutter keeps it on the
# screens, not on its first monitor: with two, it may spread onto the second. Run under
# dbus-run-session.
set -eu
bin=$1
monitors=${2:-1}
pics=$(mktemp -d)
magick -size 200x200 xc:green "$pics/1-small.png"
magick -size 1200x700 gradient:red-blue "$pics/2-large.png"
log=$(mktemp)

XDG_RUNTIME_DIR=$(mktemp -d)
XDG_CURRENT_DESKTOP=GNOME
export XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
trap 'kill ${pid:-} ${mutter:-} 2>/dev/null || true' EXIT
set --
for _ in $(seq "$monitors"); do set -- "$@" --virtual-monitor 1280x800; done
# mutter logs where a window asks to go, then where each constraint leaves it
MUTTER_DEBUG=geometry mutter --headless "$@" --no-x11 --wayland-display=wayland-m 2>"$log" &
mutter=$!
for _ in $(seq 100); do
    [ -S "$XDG_RUNTIME_DIR/wayland-m" ] && break
    sleep 0.1
done
[ -S "$XDG_RUNTIME_DIR/wayland-m" ] || { echo "mutter did not start" >&2; cat "$log" >&2; exit 1; }

# mutter names each window it constrains, as W1 (title); the viewer's own comes first, its room
# probes later. For that window: where it asked to go, and where each constraint left it
viewer() {
    awk -v kind="$1" '
        / Constraining / {
            for (i = 1; i < NF; i++) if ($i == "Constraining") desc = $(i + 1)
            if (first == "") first = desc
            if (kind == "asked" && desc == first) { split($(NF - 1), p, ","); split($NF, z, "x"); print p[1], p[2], z[1], z[2] }
        }
        /info->current is/ && desc == first && kind == "placed" {
            for (i = 1; i < NF; i++) if ($i == "is") { split($(i + 1), p, ","); split($(i + 2), z, "x"); print p[1], p[2], z[1], z[2] }
        }' "$log"
}

WAYLAND_DISPLAY=wayland-m "$bin" -S 4 "$pics" &
pid=$!
# the large image shows for four seconds once the viewer is up; wait for mutter to place the
# grown window, then for the rest of that placement's log
for _ in $(seq 40); do
    sleep 0.25
    [ -n "$(viewer placed | awk '$3 > 400')" ] && break
done
sleep 0.5
kill -0 "$pid"

past=$(viewer asked | awk '$3 > 400 && ($1 % 1280 + $3 > 1280 || $2 + $4 > 800)' | head -1)
final=$(viewer placed | awk '$3 > 400' | tail -1)
echo "the viewer asked for: $(viewer asked | tr '\n' ';')"
echo "monitors: $monitors x 1280x800; asked past an edge: ${past:-never}; placed at: ${final:-nothing}"
[ -n "$final" ] || { echo "the window did not grow for the large image" >&2; tail -40 "$log" >&2; exit 1; }
[ -n "$past" ] || { echo "the window never asked to run past an edge, so mutter was not tested" >&2; exit 1; }
# shellcheck disable=SC2086
set -- $final
[ "$1" -ge 0 ] && [ "$2" -ge 0 ] && [ $(($1 + $3)) -le $((monitors * 1280)) ] && [ $(($2 + $4)) -le 800 ] ||
    { echo "the grown window ran past the screen's edge" >&2; exit 1; }
