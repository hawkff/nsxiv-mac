#!/bin/sh
# Runs the Linux build in a pseudo-terminal with no display, as over SSH on a headless machine:
# chafa draws the image as colored symbols and the status bar takes the last line. j shows the
# next image and m marks it; q must give the terminal back before -o prints the marked file.
set -eu
bin=$1
pics=$(mktemp -d)
out=$(mktemp)
keys=$pics/keys
magick -size 640x400 gradient:red-blue "$pics/1-gradient.png"
magick -size 300x300 plasma: "$pics/2-plasma.jpg"
mkfifo "$keys"
unset DISPLAY WAYLAND_DISPLAY
export TERM=xterm-256color COLORTERM=truecolor
fail() { echo "$1" >&2; tail -c 1500 "$out" | od -c | tail -30 >&2; exit 1; }
# script runs the viewer on a terminal of 100 by 30 cells and copies what it draws to $out
timeout 60 script -q -e -c "stty cols 100 rows 30 && exec '$bin' -o '$pics'" /dev/null <"$keys" >"$out" &
session=$!
exec 3>"$keys"
# the status bar names the image on screen
shown() {
    for _ in $(seq 100); do
        if grep -a -q -F "$1" "$out"; then return; fi
        sleep 0.1
    done
    fail "the status bar never named $1"
}
shown 1-gradient.png
grep -a -q '38;2;' "$out" || fail "chafa drew no colored symbols"
printf j >&3
shown 2-plasma.jpg
printf mq >&3
wait "$session" || fail "the viewer did not exit cleanly"
leave=$(printf '\033[?1049l')
at=$(grep -a -b -o -F "$leave" "$out" | tail -1 | cut -d: -f1)
[ -n "$at" ] || fail "the viewer did not leave the alternate screen"
tail -c +$((at + ${#leave} + 1)) "$out" | grep -a -q -F "$pics/2-plasma.jpg" ||
    fail "-o did not print the marked file once the terminal was back"
echo "drew $(wc -c <"$out") bytes, then printed the marked $pics/2-plasma.jpg"
