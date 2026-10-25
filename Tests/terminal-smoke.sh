#!/bin/sh
# Runs the Linux build in a pseudo-terminal with no display, as over SSH on a headless machine.
# chafa must draw the red first image as red symbols, with the status bar on the last line; j
# must draw the blue one; a smaller terminal must move the status bar to its new last line; m
# marks the image; SIGTERM must end the viewer as q does, giving the terminal back in the mode
# it found, before -o prints the marked file.
set -eu
bin=$1
pics=$(mktemp -d)
out=$pics/out
keys=$pics/keys
magick -size 800x464 xc:red "$pics/1-red.png"
magick -size 800x464 xc:blue "$pics/2-blue.png"
mkfifo "$keys"
unset DISPLAY WAYLAND_DISPLAY
export TERM=xterm-256color COLORTERM=truecolor bin pics
fail() { echo "$1" >&2; tail -c 1500 "$out" | od -c | tail -30 >&2; exit 1; }
# the session in script's terminal of 100 by 30 cells: it notes the terminal and the viewer's
# pid, and compares the terminal's mode before and after the viewer
cat >"$pics/session" <<'EOF'
stty cols 100 rows 30
tty >"$pics/tty"
before=$(stty -g)
sh -c 'echo $$ >"$pics/pid"; exec "$bin" -o "$pics"'
status=$?
[ "$(stty -g)" = "$before" ] || echo "the terminal mode changed"
exit "$status"
EOF
timeout 60 script -q -e -c "sh $pics/session" /dev/null <"$keys" >"$out" &
session=$!
exec 3>"$keys"
# waits for the viewer to write $1
drawn() {
    for _ in $(seq 100); do
        if grep -a -q -F "$1" "$out"; then return; fi
        sleep 0.1
    done
    fail "$2"
}
drawn 1-red.png "the status bar never named the first image"
drawn '255;0;0m' "chafa drew no red symbols for the red image"
printf j >&3
drawn 2-blue.png "j did not name the second image"
drawn '0;0;255m' "j did not draw the blue image"
stty -F "$(cat "$pics/tty")" cols 80 rows 20
drawn "$(printf '\033[20;1H')" "a smaller terminal did not get the status bar on its last line"
printf m >&3
drawn '*1 |' "m did not mark the image"
kill -TERM "$(cat "$pics/pid")"
wait "$session" || fail "SIGTERM did not end the viewer cleanly"
if grep -a -q 'the terminal mode changed' "$out"; then fail "the viewer left the terminal in another mode"; fi
leave=$(printf '\033[?1049l')
at=$(grep -a -b -o -F "$leave" "$out" | tail -1 | cut -d: -f1)
[ -n "$at" ] || fail "the viewer did not leave the alternate screen"
tail -c +$((at + ${#leave} + 1)) "$out" | grep -a -q -F "$pics/2-blue.png" ||
    fail "-o did not print the marked file once the terminal was back"
echo "drew $(wc -c <"$out") bytes, then printed the marked $pics/2-blue.png"
