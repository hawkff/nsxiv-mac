#!/bin/sh
# Drives the Linux build under Xvfb: still, turned, alpha, animated and long-named
# images, the grid, the key-handler, then -o with two marks. Screenshots land in $2.
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
printf '#!/bin/sh\n{ echo "key $1"; cat; } >"$0.ran"\n' >"$handler"
chmod +x "$handler"

shot() { sleep 1; import -window root "$shots/$1.png"; }

timeout 60 "$bin" -o "$pics" >"$pics/marked" & # a viewer that misses q fails the run
pid=$!
sleep 2
xdotool mousemove 40 40 # without a window manager, keys go to the window under the pointer
shot 1-image
xdotool key greater && shot 2-turned
xdotool key j && shot 3-alpha
xdotool key A && shot 4-checkerboard
xdotool key j && shot 5-animated
xdotool key j && shot 6-long-name
xdotool key g m m Return
sleep 2
shot 7-grid
xdotool key ctrl+x c
sleep 1
xdotool key q
wait "$pid"
test "$(wc -l <"$pics/marked")" -eq 2
test "$(cat "$handler.ran")" = "key c
$(cat "$pics/marked")"
echo "marked and passed to the key-handler: $(tr '\n' ' ' <"$pics/marked")"
