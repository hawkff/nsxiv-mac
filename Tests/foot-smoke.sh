#!/bin/sh
# Runs the Linux build in foot, a terminal with sixels and the kitty keyboard protocol, in a
# headless sway. Each image must show in its color, as sixels. Three taps of m that reach the
# viewer in one read must mark three images, and a held k, whose repeats reach it the same way,
# must go back one image, not as many as it repeated. A key-handler must get Alt, Shift and
# Return as M-S-Return, Shift and j as J, and the comma by its name; one that asks on the terminal
# must read the answer as typed, and after the viewer the keys must type text again, both without
# the release of the key that came before. Screenshots land in $2.
set -eu
bin=$1
shots=$2
pics=$(mktemp -d)
mkdir -p "$shots"
n=0
for color in red blue lime yellow magenta; do
    n=$((n + 1))
    magick -size 640x400 "xc:$color" "$pics/$n-$color.png"
done

export XDG_CONFIG_HOME="$pics/config" XDG_CACHE_HOME="$pics/cache"
handler="$XDG_CONFIG_HOME/nsxiv-mac/exec/key-handler"
mkdir -p "$(dirname "$handler")"
# for the key p, the handler asks on the terminal and notes the answer
cat >"$handler" <<'EOF'
#!/bin/sh
if [ "$1" = p ]; then
    printf 'name? ' >/dev/tty
    : >"$0.asking"
    read -r name </dev/tty
    echo "$name" >"$0.name"
fi
echo "$1" >>"$0.keys"
EOF
chmod +x "$handler"

XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
trap 'kill ${foot:-} ${sway:-} 2>/dev/null || true' EXIT
echo 'output HEADLESS-1 resolution 1280x800' >"$pics/sway.conf"
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
[ -n "$socket" ] || { echo "sway opened no Wayland socket" >&2; exit 1; }
WAYLAND_DISPLAY=$(basename "$socket")
export WAYLAND_DISPLAY bin pics

fail() { echo "$1" >&2; grim "$shots/failed.png" 2>/dev/null || true; exit 1; }
# the viewer in foot's terminal, without the display it would open a window on; then a line read
# from the terminal, as a shell would
cat >"$pics/run" <<'EOF'
unset WAYLAND_DISPLAY DISPLAY
sh -c 'echo $$ >"$pics/pid"; exec "$bin" -o "$pics"' >"$pics/marked"
read -r line
echo "$line" >"$pics/typed"
EOF
timeout 90 foot sh "$pics/run" &
foot=$!
for _ in $(seq 100); do [ -s "$pics/pid" ] && break; sleep 0.1; done
[ -s "$pics/pid" ] || fail "foot did not start the viewer"
pid=$(cat "$pics/pid")
sleep 2

# each wtype plugs in a new virtual keyboard; the pause lets foot bind it first
key() { wtype -s 300 "$@"; }
# the color in the middle of the screen, where the image shows, or which of red, green and blue
# are bright there
shown() {
    sleep 1
    grim "$shots/$1.png"
    magick "$shots/$1.png" -format '%[fx:p{640,400}.r > 0.8] %[fx:p{640,400}.g > 0.8] %[fx:p{640,400}.b > 0.8]' info: |
        sed 's/^1 0 0$/red/; s/^0 0 1$/blue/; s/^0 1 0$/lime/; s/^1 1 0$/yellow/; s/^1 0 1$/magenta/'
}
# what the viewer reads at once, as after a frame that took long: typed while it is stopped
burst() {
    kill -STOP "$pid"
    key "$@"
    sleep 0.3
    kill -CONT "$pid"
}
# waits for the key-handler to have run for key $1
handled() {
    for _ in $(seq 100); do
        [ "$(tail -1 "$handler.keys" 2>/dev/null)" = "$1" ] && return
        sleep 0.1
    done
    fail "the key-handler got $(tail -1 "$handler.keys" 2>/dev/null), not $1"
}

color=$(shown 1-first)
[ "$color" = red ] || fail "the first image shows as $color, not red"
key j
color=$(shown 2-next)
[ "$color" = blue ] || fail "j shows $color, not the blue image"
key k
# m marks the image and goes to the next: three taps mark the first three, and leave the fourth
burst mmm
color=$(shown 3-taps)
[ "$color" = yellow ] || fail "after three taps of m in one read, $color shows, not the fourth image"
# k held for about twenty repeats goes back one image, where m takes the mark away again
burst -P k -s 1500 -p k
color=$(shown 4-held)
[ "$color" = lime ] || fail "after a held k in one read, $color shows, not the third image"
key m
key -M ctrl x -m ctrl -M alt -M shift -k Return -m shift -m alt
handled M-S-Return
key -M ctrl x -m ctrl J
handled J
key -M ctrl x -m ctrl ,
handled comma
key -M ctrl x -m ctrl p
for _ in $(seq 100); do [ -e "$handler.asking" ] && break; sleep 0.1; done
[ -e "$handler.asking" ] || fail "the key-handler did not ask on the terminal"
key red -k Return
handled p
[ "$(cat "$handler.name")" = red ] || fail "the key-handler read '$(cat "$handler.name")' on the terminal, not red"
key q
for _ in $(seq 100); do [ -s "$pics/marked" ] && break; sleep 0.1; done
[ "$(cat "$pics/marked")" = "$pics/1-red.png
$pics/2-blue.png" ] || fail "the marks are $(tr '\n' ' ' <"$pics/marked"), not the first two images"
key ok -k Return
wait "$foot" || fail "foot ended with an error"
[ "$(cat "$pics/typed" 2>/dev/null)" = ok ] ||
    fail "after the viewer, the keys typed '$(cat "$pics/typed" 2>/dev/null)', not ok: the keyboard mode stayed"
echo "in foot: sixel images, three taps as three keys, a held key as one, and modifiers for the key-handler"
