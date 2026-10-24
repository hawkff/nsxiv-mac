#!/bin/sh
# Runs the Linux build in a headless KWin, KDE's compositor, on $2 side-by-side 1280x800
# screens (default 1), with two viewers whose slideshows go from a small image to one that
# needs most of a screen. A test-only KWin script places them and logs their frames. The
# "corner" window starts inside the first screen, near its bottom-right corner; KWin lets it
# run past that screen's edge as it grows, and the viewer's own KWin script must move it
# back inside the same screen. The "parked" window hangs past the right edge of the last
# screen, as a user may leave it; it must stay there as it grows, and come back to the same
# frame after a trip through fullscreen. Each viewer's script must unload itself when its
# viewer quits. Works with Plasma 5.27 and 6. Run under dbus-run-session.
set -eu
bin=$1
outputs=${2:-1}
command -v magick >/dev/null || magick() { convert "$@"; } # ImageMagick 6 on Debian 12
pics=$(mktemp -d)
magick -size 200x200 xc:green "$pics/1-small.png"
magick -size 1200x700 gradient:red-blue "$pics/2-large.png"
log=$(mktemp)
observer=$(mktemp --suffix=.js)

XDG_RUNTIME_DIR=$(mktemp -d)
XDG_CURRENT_DESKTOP=KDE
export XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
trap 'kill ${corner:-} ${parked:-} ${kwin:-} 2>/dev/null || true' EXIT
fail() { echo "$1" >&2; tail -60 "$log" >&2; exit 1; }
# Qt logs to the journal when stderr is no terminal; a container has no journal
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 QT_LOGGING_RULES='js=true;kwin_scripting=true' KWIN_COMPOSE=Q \
    kwin_wayland --virtual --width=1280 --height=800 --output-count="$outputs" --socket=wayland-k \
    --no-lockscreen 2>"$log" &
kwin=$!
for _ in $(seq 150); do
    [ -S "$XDG_RUNTIME_DIR/wayland-k" ] && break
    sleep 0.1
done
[ -S "$XDG_RUNTIME_DIR/wayland-k" ] || fail "KWin did not start"

kwin() { dbus-send --session --print-reply --dest=org.kde.KWin "$@"; }
# KWin's D-Bus interfaces come up after its socket
for _ in $(seq 75); do
    kwin /Scripting org.kde.kwin.Scripting.isScriptLoaded string:none >/dev/null 2>&1 && break
    sleep 0.2
done

WAYLAND_DISPLAY=wayland-k "$bin" -S 4 "$pics" &
corner=$!
WAYLAND_DISPLAY=wayland-k "$bin" -S 4 "$pics" &
parked=$!
echo "const corner = $corner, parked = $parked, outputs = $outputs, width = 1280, height = 800;" >"$observer"
cat >>"$observer" <<'EOF'
function show(r) { return [r.x, r.y, r.width, r.height].map(Math.round).join(" "); }
function later(ms, f) {
    const t = new QTimer();
    t.singleShot = true;
    t.interval = ms;
    t.timeout.connect(f);
    t.start();
}
function watch(w) {
    if (w.pid !== corner && w.pid !== parked) return;
    const name = w.pid === corner ? "corner" : "parked";
    const f = w.frameGeometry;
    w.frameGeometryChanged.connect(function () { console.info("nsxiv-test " + name + " " + show(w.frameGeometry)); });
    const x = name === "corner" ? width - f.width - 10 : outputs * width - f.width / 2;
    w.frameGeometry = { x: x, y: height - f.height - 10, width: f.width, height: f.height };
    if (name !== "parked") return;
    let trip = false;
    w.frameGeometryChanged.connect(function () {
        if (trip || w.fullScreen || w.frameGeometry.width < 1000) return;
        trip = true;
        later(500, function () {
            console.info("nsxiv-test before-fullscreen " + show(w.frameGeometry));
            w.fullScreen = true;
            later(500, function () {
                w.fullScreen = false;
                later(500, function () { console.info("nsxiv-test after-fullscreen " + show(w.frameGeometry)); });
            });
        });
    });
}
(workspace.windowList ? workspace.windowList() : workspace.clientList()).forEach(watch);
(workspace.windowAdded || workspace.clientAdded).connect(watch);
EOF
id=$(kwin /Scripting org.kde.kwin.Scripting.loadScript string:"$observer" string:observer | awk 'END { print $2 }')
case $id in '' | *[!0-9]*) fail "KWin did not load the observer: '$id'" ;; esac
# Plasma 6 puts a script at /Scripting/Script<id>, Plasma 5 at /<id>
kwin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1 || kwin "/$id" org.kde.kwin.Script.run >/dev/null

logged() { sed -n "s/.*nsxiv-test $1 //p" "$log"; }
# the large image shows from 4 to 8 seconds; the fullscreen trip ends about 1.5 seconds later
sleep 4
for _ in $(seq 30); do
    [ -n "$(logged after-fullscreen)" ] && break
    sleep 0.2
done
for pid in $corner $parked; do
    kill -0 "$pid"
    kwin /Scripting org.kde.kwin.Scripting.isScriptLoaded string:"nsxiv-mac-$pid" | grep -q 'boolean true' ||
        fail "viewer $pid loaded no KWin script"
done
echo "screens: $outputs x 1280x800"
echo "corner: $(logged corner | tr '\n' ';')"
echo "parked: $(logged parked | tr '\n' ';')"

# the corner window ran past the first screen's edge as it grew, then came back inside it
logged corner | awk '$3 >= 1000 && ($1 + $3 > 1280 || $2 + $4 > 800) { found = 1 } END { exit !found }' ||
    fail "the corner window never ran past the edge, so nothing was tested"
grown=$(logged corner | awk '$3 >= 1000' | tail -1) # the slideshow returns to the small image at 8 seconds
# shellcheck disable=SC2086
set -- $grown
[ $# -eq 4 ] && [ "$1" -ge 0 ] && [ "$2" -ge 0 ] && [ $(($1 + $3)) -le 1280 ] && [ $(($2 + $4)) -le 800 ] ||
    fail "the grown corner window is not inside its screen: $grown"

# the parked window grew where the user left it, and fullscreen brought it back there
before=$(logged before-fullscreen | tail -1)
after=$(logged after-fullscreen | tail -1)
echo "parked before fullscreen: $before; after: $after"
# shellcheck disable=SC2086
set -- $before
[ $# -eq 4 ] && [ "$3" -ge 1000 ] && [ $(($1 + $3)) -gt $((outputs * 1280)) ] ||
    fail "the parked window was pulled in: $before"
[ "$after" = "$before" ] || fail "fullscreen moved the parked window from $before to $after"

kill "$corner" "$parked"
sleep 2
for pid in $corner $parked; do
    kwin /Scripting org.kde.kwin.Scripting.isScriptLoaded string:"nsxiv-mac-$pid" | grep -q 'boolean false' ||
        fail "the KWin script of viewer $pid outlived its window"
done
