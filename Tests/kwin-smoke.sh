#!/bin/sh
# Runs the Linux build in a headless KWin, KDE's compositor. A test-only KWin script parks
# the small first window near the bottom-right corner and logs its frame. The slideshow's
# second image needs most of the screen, so a window that kept its top-left corner would run
# past the edge; the viewer's own KWin script must move it back inside, then unload itself
# when the viewer quits. Run under dbus-run-session.
set -eu
bin=$1
pics=$(mktemp -d)
magick -size 200x200 xc:green "$pics/1-small.png"
magick -size 1200x700 gradient:red-blue "$pics/2-large.png"
log=$(mktemp)
observer=$(mktemp --suffix=.js)

XDG_RUNTIME_DIR=$(mktemp -d)
XDG_CURRENT_DESKTOP=KDE
export XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
trap 'kill ${pid:-} ${kwin:-} 2>/dev/null || true' EXIT
# Qt logs to the journal when stderr is no terminal; a container has no journal
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_RULES='js=true;kwin_scripting=true' KWIN_COMPOSE=Q \
    kwin_wayland --virtual --width=1280 --height=800 --socket=wayland-k --no-lockscreen 2>"$log" &
kwin=$!
for _ in $(seq 150); do
    [ -S "$XDG_RUNTIME_DIR/wayland-k" ] && break
    sleep 0.1
done
[ -S "$XDG_RUNTIME_DIR/wayland-k" ] || { echo "KWin did not start" >&2; cat "$log" >&2; exit 1; }
sleep 1 # its D-Bus interfaces come up after the socket

kwin() { dbus-send --session --print-reply --dest=org.kde.KWin "$@"; }
cat >"$observer" <<'EOF'
function show(r) { return [r.x, r.y, r.width, r.height].map(Math.round).join(" "); }
function watch(w) {
    if (w.resourceClass !== "nsxiv-mac") return;
    const area = workspace.clientArea(KWin.MaximizeArea, w), f = w.frameGeometry;
    console.info("nsxiv-test area " + show(area));
    w.frameGeometryChanged.connect(function () { console.info("nsxiv-test frame " + show(w.frameGeometry)); });
    w.frameGeometry = { x: area.x + area.width - f.width - 10, y: area.y + area.height - f.height - 10,
                        width: f.width, height: f.height };
}
console.info("nsxiv-test observer running");
workspace.windowList().forEach(watch);
workspace.windowAdded.connect(watch);
EOF
id=$(kwin /Scripting org.kde.kwin.Scripting.loadScript string:"$observer" string:observer | awk 'END { print $2 }')
kwin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null

WAYLAND_DISPLAY=wayland-k "$bin" -S 4 "$pics" &
pid=$!
sleep 6 # the large image shows from 4 to 8 seconds
kill -0 "$pid"
kwin /Scripting org.kde.kwin.Scripting.isScriptLoaded string:"nsxiv-mac-$pid" | grep -q 'boolean true' ||
    { echo "the viewer loaded no KWin script" >&2; tail -40 "$log" >&2; exit 1; }

area=$(sed -n 's/.*nsxiv-test area //p' "$log" | tail -1)
frame=$(sed -n 's/.*nsxiv-test frame //p' "$log" | tail -1)
echo "work area: ${area:-none}; window: ${frame:-none}"
[ -n "$area" ] && [ -n "$frame" ] || { echo "the observer logged no window" >&2; tail -60 "$log" >&2; exit 1; }
# shellcheck disable=SC2086
set -- $area $frame
[ "$7" -ge 1000 ] || { echo "the window did not grow for the large image" >&2; exit 1; }
[ "$5" -ge "$1" ] && [ "$6" -ge "$2" ] && [ $(($5 + $7)) -le $(($1 + $3)) ] && [ $(($6 + $8)) -le $(($2 + $4)) ] ||
    { echo "the grown window ran past the work area" >&2; tail -40 "$log" >&2; exit 1; }

kill "$pid"
sleep 2
kwin /Scripting org.kde.kwin.Scripting.isScriptLoaded string:"nsxiv-mac-$pid" | grep -q 'boolean false' ||
    { echo "the viewer's KWin script outlived its window" >&2; exit 1; }
