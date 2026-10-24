#!/bin/sh
# Runs the Linux build in COSMIC's compositor, nested in a headless sway. COSMIC puts the
# small first window in the middle of its screen; the slideshow's second image is larger than
# the screen, so a window that kept its top-left corner and grew to fit it would run past the
# bottom-right edge. That image has four colored quarters: a screenshot shows all four at the
# same size only when no part of the window ran past an edge. The screenshot lands in $2. Run
# under dbus-run-session.
set -eu
bin=$1
shots=$2
mkdir -p "$shots"
pics=$(mktemp -d)
conf=$(mktemp -d)
log=$(mktemp)
magick -size 200x200 xc:green "$pics/1-small.png"
magick \( -size 800x500 xc:magenta xc:yellow +append \) \( -size 800x500 xc:cyan xc:blue +append \) -append \
    "$pics/2-large.png"

XDG_RUNTIME_DIR=$(mktemp -d)
XDG_CURRENT_DESKTOP=COSMIC
export XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
trap 'kill ${pid:-} ${cosmic:-} ${sway:-} 2>/dev/null || true' EXIT
fail() { echo "$1" >&2; tail -40 "$log" >&2; exit 1; }

# the newest wayland-N socket in XDG_RUNTIME_DIR other than $1
next_socket() {
    for _ in $(seq 300); do
        for candidate in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do
            if [ -S "$candidate" ] && [ "$(basename "$candidate")" != "${1:-}" ]; then
                basename "$candidate"
                return
            fi
        done
        sleep 0.1
    done
    fail "no Wayland socket appeared"
}

echo 'output HEADLESS-1 resolution 1280x800' >"$conf/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$conf/sway.conf" &
sway=$!
host=$(next_socket)
WAYLAND_DISPLAY=$host LIBGL_ALWAYS_SOFTWARE=1 cosmic-comp >"$log" 2>&1 &
cosmic=$!
nested=$(next_socket "$host")

WAYLAND_DISPLAY=$nested "$bin" -S 4 "$pics" &
pid=$!
sleep 6 # the large image shows from 4 to 8 seconds
kill -0 "$pid"
shot=$shots/cosmic.png
WAYLAND_DISPLAY=$host grim "$shot"

# the bounding box of each quarter's color, as width height x y
box() {
    magick "$shot" -alpha off -fuzz 3% -fill black +opaque "$1" -fill white -opaque "$1" -trim \
        -format '%w %h %X %Y' info: | tr -d '+'
}
for color in magenta yellow cyan blue; do
    set -- $(box "$color")
    echo "$color: ${1}x$2 at $3,$4"
    eval "w_$color=$1 h_$color=$2"
done
[ "$w_magenta" -gt 100 ] || fail "the window did not grow for the large image"
for color in yellow cyan blue; do
    eval "dw=\$((w_$color - w_magenta)) dh=\$((h_$color - h_magenta))"
    [ "${dw#-}" -le 1 ] && [ "${dh#-}" -le 1 ] || fail "the $color quarter is cut: the window ran past the edge"
done
