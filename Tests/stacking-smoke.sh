#!/bin/sh
# Runs the Linux build in headless labwc or Wayfire ($2), compositors that keep a window's
# top-left corner when it grows and give a client no way to move itself. A window rule puts
# the viewer near the bottom-right corner of the 1280x720 screen; the slideshow's second image
# needs most of the screen, and the viewer must grow only as far as the screen allows. That
# image has four colored quarters: a screenshot shows all four at the same size only when no
# part of the window ran past the screen edge. The screenshot lands in $3.
set -eu
bin=$1
compositor=$2
shots=$3
mkdir -p "$shots"
pics=$(mktemp -d)
conf=$(mktemp -d)
log=$(mktemp)
magick -size 200x200 xc:green "$pics/1-small.png"
magick \( -size 600x350 xc:magenta xc:yellow +append \) \( -size 600x350 xc:cyan xc:blue +append \) -append \
    "$pics/2-large.png"

XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
# what each compositor puts in the session it starts
case $compositor in labwc) XDG_CURRENT_DESKTOP=labwc:wlroots ;; *) XDG_CURRENT_DESKTOP=$compositor ;; esac
export XDG_CURRENT_DESKTOP
trap 'kill ${pid:-} ${server:-} 2>/dev/null || true' EXIT
fail() { echo "$1" >&2; tail -40 "$log" >&2; exit 1; }
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
case $compositor in
labwc)
    cat >"$conf/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <windowRules>
    <windowRule identifier="nsxiv-mac">
      <action name="MoveTo" x="1000" y="420" />
    </windowRule>
  </windowRules>
</labwc_config>
EOF
    labwc -C "$conf" 2>"$log" &
    ;;
wayfire)
    cat >"$conf/wayfire.ini" <<'EOF'
[core]
plugins = window-rules
xwayland = false

[window-rules]
park = on created if app_id is "nsxiv-mac" then move 1000 420
EOF
    wayfire -c "$conf/wayfire.ini" 2>"$log" &
    ;;
*) fail "unknown compositor $compositor" ;;
esac
server=$!
socket=
for _ in $(seq 100); do
    for candidate in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do [ -S "$candidate" ] && socket=$(basename "$candidate"); done
    [ -n "$socket" ] && break
    sleep 0.1
done
[ -n "$socket" ] || fail "$compositor did not start"
export WAYLAND_DISPLAY=$socket

"$bin" -S 4 "$pics" &
pid=$!
sleep 6 # the large image shows from 4 to 8 seconds
kill -0 "$pid"
shot=$shots/$compositor.png
grim "$shot"

# the bounding box of each quarter's color, as width height x y
box() {
    magick "$shot" -fill black +opaque "$1" -fill white -opaque "$1" -trim -format '%w %h %X %Y' info: |
        tr -d '+'
}
for color in magenta yellow cyan blue; do
    set -- $(box "$color")
    echo "$color: ${1}x$2 at $3,$4"
    eval "w_$color=$1 h_$color=$2 right_$color=$(($3 + $1)) bottom_$color=$(($4 + $2))"
done
# every quarter whole, so none was cut by the screen edge, and the status bar below the image
# inside the screen too
for color in yellow cyan blue; do
    eval "dw=\$((w_$color - w_magenta)) dh=\$((h_$color - h_magenta))"
    [ "${dw#-}" -le 1 ] && [ "${dh#-}" -le 1 ] || fail "the $color quarter is cut: the window ran past the edge"
done
[ "$w_magenta" -gt 50 ] || fail "the large image is not on screen"
[ "$right_blue" -le 1280 ] && [ $((bottom_blue + 20)) -le 720 ] || fail "the status bar ran past the edge"
