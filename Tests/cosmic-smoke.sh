#!/bin/sh
# Runs the Linux build in COSMIC's compositor, nested in a headless sway. COSMIC puts the
# small first window in the middle of its screen; the slideshow's second image is larger than
# the screen, so a window that kept its top-left corner and grew to fit it would run past the
# bottom-right edge. That image has four colored quarters: a screenshot shows all four at the
# same size only when the image did not run past an edge, and the status bar below it shows
# whole above the bottom edge. The screenshot lands in $2. Run under dbus-run-session.
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

# with no title bar or border, COSMIC's screen is the whole of sway's
printf 'output HEADLESS-1 resolution 1280x800\ndefault_border none\n' >"$conf/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$conf/sway.conf" &
sway=$!
host=$(next_socket)
WAYLAND_DISPLAY=$host LIBGL_ALWAYS_SOFTWARE=1 cosmic-comp >"$log" 2>&1 &
cosmic=$!
nested=$(next_socket "$host")

WAYLAND_DISPLAY=$nested "$bin" -S 4 "$pics" &
pid=$!
shot=$shots/cosmic.png

# the bounding box of a color within fuzz $2 (default 3%), as width height x y; 1 1 -1 -1 when
# the color is missing
box() {
    magick "$shot" -alpha off -fuzz "${2:-3%}" -fill black +opaque "$1" -fill white -opaque "$1" -trim \
        -format '%w %h %X %Y' info: 2>/dev/null | tr -d '+'
}
# the large image shows for four seconds once the viewer is up; wait for a screenshot of it in
# the grown window, as the small window shows each quarter at most 100 pixels wide
for _ in $(seq 40); do
    sleep 0.25
    WAYLAND_DISPLAY=$host grim "$shot"
    set -- $(box magenta)
    [ "$1" -gt 100 ] && break
done
kill -0 "$pid"
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
# the window grows across to the right edge but has room below, so a bar the bottom edge cut
# would reach it; a tight fuzz leaves out the light title text in COSMIC's header
set -- $(box '#eeeeee' 1%)
echo "status bar: ${1}x$2 at $3,$4"
[ "$2" -ge 20 ] && [ $(($4 + $2)) -lt 800 ] || fail "the status bar ran past the bottom edge"
