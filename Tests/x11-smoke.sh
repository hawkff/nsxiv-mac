#!/bin/sh
# Drives the Linux build under Xvfb: still, turned, alpha, animated and long-named
# images, the grid, the key-handler, then -o with two marks. The handler waits for a job of
# its own, which a shell started with SIGCHLD blocked never sees end, and a mark typed while
# a slow handler runs must not count. First, an option whose argument is out of range must
# end the viewer with a message and status 2. Screenshots land in $2.
set -eu
bin=$1
shots=$2
pics=$(mktemp -d)
mkdir -p "$shots"
magick -size 640x400 gradient:red-blue "$pics/1-gradient.png"
magick -size 200x200 xc:none -fill green -draw 'circle 100,100 100,20' "$pics/2-alpha.png"
magick -delay 20 -size 120x80 xc:red xc:lime xc:blue -loop 0 "$pics/3-animated.gif"
magick -size 300x300 plasma: "$pics/4-a-name-long-enough-to-lose-its-start-in-the-status-bar.jpg"

export XDG_CONFIG_HOME="$pics/config"
handler="$XDG_CONFIG_HOME/nsxiv-mac/exec/key-handler"
mkdir -p "$(dirname "$handler")"
# for the key s, the handler runs until the test takes its .waiting file away
cat >"$handler" <<'EOF'
#!/bin/sh
true & wait
if [ "$1" = s ]; then : >"$0.waiting"; while [ -e "$0.waiting" ]; do sleep 0.1; done; fi
{ echo "key $1"; cat; } >"$0.ran"
EOF
chmod +x "$handler"

shot() { sleep 1; import -window root "$shots/$1.png"; }

for bad in '-S 99999999999' '-g 99999999999x1' '-g 800' '-n 0' '-z x'; do
    # shellcheck disable=SC2086
    timeout 10 "$bin" $bad "$pics" 2>/dev/null && status=0 || status=$?
    [ "$status" -eq 2 ] || { echo "nsxiv-mac $bad ended with status $status, not 2" >&2; exit 1; }
done

timeout 60 "$bin" -o "$pics" >"$pics/marked" & # a viewer that misses q fails the run
pid=$!
sleep 2
xdotool mousemove 40 40 # without a window manager, keys go to the window under the pointer
shot 1-image
# with no window manager the window sits at 0,0, and the 640x400 gradient at 100% fills its
# top: red at the top, blue at the bottom
[ "$(magick "$shots/1-image.png" -format '%[fx:p{320,5}.r > 0.8 && p{320,5}.b < 0.2 && p{320,394}.b > 0.8 && p{320,394}.r < 0.2]' info:)" = 1 ] ||
    { echo "the first image is not drawn" >&2; exit 1; }
xdotool key greater
shot 2-turned
# turned clockwise, the gradient's red top is on the right; a gamma step must leave it turned
xdotool key braceright
shot 2-turned-gamma
[ "$(magick "$shots/2-turned-gamma.png" -format '%[fx:p{395,300}.r > 0.8 && p{395,300}.b < 0.3 && p{5,300}.b > 0.8 && p{5,300}.r < 0.3]' info:)" = 1 ] ||
    { echo "after a gamma step, the turned image is not drawn turned" >&2; exit 1; }
xdotool key ctrl+g
xdotool key j
shot 3-alpha
xdotool key A
shot 4-checkerboard
xdotool key j
shot 5-animated
xdotool key j
shot 6-long-name
xdotool key g m m Return
sleep 2
shot 7-grid
xdotool key ctrl+x s
for _ in $(seq 100); do [ -e "$handler.waiting" ] && break; sleep 0.1; done
xdotool key m # while the handler runs: dropped, as in nsxiv
sleep 0.5
rm "$handler.waiting"
for _ in $(seq 100); do grep -q 'key s' "$handler.ran" 2>/dev/null && break; sleep 0.1; done
sleep 0.5
xdotool key ctrl+x c
sleep 1
xdotool key q
wait "$pid"
test "$(wc -l <"$pics/marked")" -eq 2
test "$(cat "$handler.ran")" = "key c
$(cat "$pics/marked")"
echo "marked and passed to the key-handler: $(tr '\n' ' ' <"$pics/marked")"
