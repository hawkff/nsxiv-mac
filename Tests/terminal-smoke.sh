#!/bin/sh
# Runs the Linux build in a pseudo-terminal with no display, as over SSH on a headless machine,
# in mode $2. In "symbols", a terminal without images, chafa must draw the red first image as
# red symbols, and a smaller terminal must move the status bar to its new last line. In "kitty",
# this script answers the viewer's query as a terminal with kitty graphics would, and the red
# first image must arrive as a PNG at the terminal's pixels. In both, j must show the blue
# second image, m marks it, and SIGTERM must end the viewer as q does: the terminal comes back
# in the mode it found, without images, before -o prints the marked file.
set -eu
bin=$1
mode=${2:-symbols}
pics=$(mktemp -d)
out=$pics/out
keys=$pics/keys
magick -size 800x464 xc:red "$pics/1-red.png"
magick -size 800x464 xc:blue "$pics/2-blue.png"
mkfifo "$keys"
unset DISPLAY WAYLAND_DISPLAY
export TERM=xterm-256color COLORTERM=truecolor bin pics mode
fail() { echo "$1" >&2; tail -c 1500 "$out" | od -c | tail -30 >&2; exit 1; }
# the session in script's terminal of 100 by 30 cells, for kitty images of 10 by 20 pixels,
# which stty cannot set: it notes the terminal and the viewer's pid, and compares the
# terminal's mode before and after the viewer
cat >"$pics/session" <<'EOF'
if [ "$mode" = kitty ]; then
    perl -e '$size = pack("S4", 30, 100, 1000, 600); ioctl(STDIN, 0x5414, $size) or die "TIOCSWINSZ: $!\n"' # 0x5414 is TIOCSWINSZ
else
    stty cols 100 rows 30
fi
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
# waits for the viewer to write $2, a fixed string with -F or a pattern with -E as $1
drawn() {
    for _ in $(seq 100); do
        if grep -a -q "$1" -- "$2" "$out"; then return; fi
        sleep 0.1
    done
    fail "$3"
}
# waits for kitty image $1, counting from 1, from its first chunk to the one with m=0; then
# checks it is 1000x580, the cells under the status bar, and its middle is the color $2 as r,g,b
image() {
    for _ in $(seq 100); do
        awk -v want="$1" 'BEGIN { RS = "\033\\\\" }
            {
                at = index($0, "\033_G"); if (!at) next
                body = substr($0, at + 3); semi = index(body, ";")
                keys = substr(body, 1, semi - 1)
                if (keys ~ /(^|,)a=T(,|$)/) { n++; payload = "" }
                if (n == want) { payload = payload substr(body, semi + 1); if (keys ~ /(^|,)m=0(,|$)/) { printf "%s", payload; exit } }
            }' "$out" | base64 -d >"$pics/image-$1.png" 2>/dev/null || true
        if seen=$(magick "$pics/image-$1.png" -format '%w %h %[fx:round(255*p{500,290}.r)],%[fx:round(255*p{500,290}.g)],%[fx:round(255*p{500,290}.b)]' info: 2>/dev/null); then
            [ "$seen" = "1000 580 $2" ] || fail "kitty image $1 is $seen, expected 1000 580 $2"
            return
        fi
        sleep 0.1
    done
    fail "the viewer sent no kitty image $1"
}

if [ "$mode" = kitty ]; then
    drawn -F "$(printf '\033_Gi=31,s=1,v=1,a=q')" "the viewer did not ask whether the terminal shows kitty graphics"
    printf '\033_Gi=31;OK\033\\\033[?62;22c' >&3 # herdr's answer
    image 1 255,0,0
    drawn -F 1-red.png "the status bar never named the first image"
    printf j >&3
    image 2 0,0,255
    drawn -F "$(printf '\033_Ga=d,d=I,i=1,q=2')" "the first image stayed under the second"
    drawn -F 2-blue.png "j did not name the second image"
else
    drawn -F 1-red.png "the status bar never named the first image"
    # chafa's colors, as 38;2;R;G;B or 48;2;R;G;B, may be a step off the image's 255
    drawn -E ';2;2[45][0-9];[0-9]{1,2};[0-9]{1,2}m' "chafa drew no red symbols for the red image"
    printf j >&3
    drawn -F 2-blue.png "j did not name the second image"
    drawn -E ';2;[0-9]{1,2};[0-9]{1,2};2[45][0-9]m' "j did not draw the blue image"
    stty -F "$(cat "$pics/tty")" cols 80 rows 20
    drawn -F "$(printf '\033[20;1H')" "a smaller terminal did not get the status bar on its last line"
fi
printf m >&3
drawn -F '*1 |' "m did not mark the image"
kill -TERM "$(cat "$pics/pid")"
wait "$session" || fail "SIGTERM did not end the viewer cleanly"
if grep -a -q 'the terminal mode changed' "$out"; then fail "the viewer left the terminal in another mode"; fi
leave=$(printf '\033[?1049l')
at=$(grep -a -b -o -F "$leave" "$out" | tail -1 | cut -d: -f1)
[ -n "$at" ] || fail "the viewer did not leave the alternate screen"
if [ "$mode" = kitty ]; then
    grep -a -q -F "$(printf '\033_Ga=d,d=A,q=2\033\\\033[0m\033[?7h\033[?25h\033[?1049l')" "$out" ||
        fail "the viewer left its image on the screen"
fi
tail -c +$((at + ${#leave} + 1)) "$out" | grep -a -q -F "$pics/2-blue.png" ||
    fail "-o did not print the marked file once the terminal was back"
echo "$mode: drew $(wc -c <"$out") bytes, then printed the marked $pics/2-blue.png"
