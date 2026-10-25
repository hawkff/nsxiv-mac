#!/bin/sh
# Runs the Linux build in a pseudo-terminal with no display, as over SSH on a headless machine,
# in mode $2. In "symbols", a terminal without images, chafa must draw the red first image as
# red symbols, and a smaller terminal must move the status bar to its new last line. In "kitty"
# and "kitty-files", this script answers the viewer's queries as a terminal with kitty graphics
# would, one that cannot read the viewer's files and one that can: the large red first image
# must come at the terminal's pixels, inline as PNG or as raw RGB in a file; the small blue
# second one, shown at 100%, at its own pixels, which the terminal scales up, sent ahead while
# the viewer waits; j and then k must only place them again. In all modes, m marks the image,
# and SIGTERM must end the viewer as q does: the terminal comes back in the mode it found,
# without images, before -o prints the marked file.
set -eu
bin=$1
mode=${2:-symbols}
pics=$(mktemp -d)
out=$pics/out
keys=$pics/keys
magick -size 2000x1160 xc:red "$pics/1-red.png"
magick -size 400x232 xc:blue "$pics/2-blue.png"
mkfifo "$keys"
unset DISPLAY WAYLAND_DISPLAY
export TERM=xterm-256color COLORTERM=truecolor bin pics mode
fail() { echo "$1" >&2; tail -c 1500 "$out" | od -c | tail -30 >&2; exit 1; }
# the session in script's terminal of 100 by 30 cells, of 10 by 20 pixels for kitty images,
# which stty cannot set: it notes the terminal and the viewer's pid, and compares the
# terminal's mode before and after the viewer
cat >"$pics/session" <<'EOF'
if [ "$mode" = symbols ]; then
    stty cols 100 rows 30
else
    perl -e '$size = pack("S4", 30, 100, 1000, 600); ioctl(STDIN, 0x5414, $size) or die "TIOCSWINSZ: $!\n"' # 0x5414 is TIOCSWINSZ
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
# how many kitty commands of kind $1, as a=T, a=t or a=p, the viewer sent
sent() { grep -a -o -F "$(printf '\033_G')$1," "$out" | wc -l; }
# the id of the last kitty command of kind $1
last() { grep -a -o "$(printf '\033_G')$1,i=[0-9]*" "$out" | tail -1 | sed 's/.*i=//'; }
# The image the viewer sent as id $1, written to $pics/image-$1.png: PNG chunks up to the one
# with m=0, or raw RGB in the file whose path came base64 encoded
picture() {
    awk -v id="$1" 'BEGIN { RS = "\033\\\\" }
        {
            at = index($0, "\033_G"); if (!at) next
            body = substr($0, at + 3); semi = index(body, ";")
            keys = "," substr(body, 1, semi - 1) ","; data = substr(body, semi + 1)
            if (keys ~ /,a=[Tt],/ && index(keys, ",i=" id ",")) {
                if (keys ~ /,t=t,/) {
                    match(keys, /,s=[0-9]+,/); w = substr(keys, RSTART + 3, RLENGTH - 4)
                    match(keys, /,v=[0-9]+,/); h = substr(keys, RSTART + 3, RLENGTH - 4)
                    print "file", w, h, data
                    exit
                }
                taking = 1
                payload = ""
            }
            if (taking) {
                payload = payload data
                if (keys ~ /,m=0,/) { print "png", payload; exit }
            }
        }' "$out" >"$pics/sent"
    read -r kind w h data <"$pics/sent" || fail "the viewer sent no image $1"
    if [ "$kind" = file ]; then
        magick -size "${w}x$h" -depth 8 "rgb:$(echo "$data" | base64 -d)" "$pics/image-$1.png"
    else
        echo "$w" | base64 -d >"$pics/image-$1.png"
    fi
}
# pixel x,y of image $1 as r,g,b
pixel() { magick "$pics/image-$1.png" -format "%[fx:round(255*p{$2}.r)],%[fx:round(255*p{$2}.g)],%[fx:round(255*p{$2}.b)]" info:; }
size() { magick "$pics/image-$1.png" -format '%wx%h' info:; }

if [ "$mode" = symbols ]; then
    drawn -F 1-red.png "the status bar never named the first image"
    # chafa's colors, as 38;2;R;G;B or 48;2;R;G;B, may be a step off the image's 255
    drawn -E ';2;2[45][0-9];[0-9]{1,2};[0-9]{1,2}m' "chafa drew no red symbols for the red image"
    printf j >&3
    drawn -F 2-blue.png "j did not name the second image"
    drawn -E ';2;[0-9]{1,2};[0-9]{1,2};2[45][0-9]m' "j did not draw the blue image"
    stty -F "$(cat "$pics/tty")" cols 80 rows 20
    drawn -F "$(printf '\033[20;1H')" "a smaller terminal did not get the status bar on its last line"
else
    drawn -F "$(printf '\033_Gi=31,s=1,v=1,a=q')" "the viewer did not ask whether the terminal shows kitty graphics"
    if [ "$mode" = kitty-files ]; then files=OK; else files='EBADF:Failed to read image file'; fi
    printf '\033_Gi=31;OK\033\\\033_Gi=32;%s\033\\\033[?62;22c' "$files" >&3 # herdr's answers
    drawn -F "$(printf '\033_Ga=T,')" "the viewer sent no kitty image"
    drawn -F 1-red.png "the status bar never named the first image"
    red=$(last a=T)
    picture "$red"
    [ "$(size "$red") $(pixel "$red" 500,290) $(pixel "$red" 995,575)" = "1000x580 255,0,0 255,0,0" ] ||
        fail "the red image went as $(size "$red"), not filling 1000x580 pixels with red"
    drawn -F "$(printf '\033_Ga=t,')" "the viewer did not send the next image ahead"
    blue=$(last a=t)
    picture "$blue"
    [ "$(size "$blue") $(pixel "$blue" 400,232) $(pixel "$blue" 5,5)" = "800x464 0,0,255 255,255,255" ] ||
        fail "the blue image went as $(size "$blue"), not as 800x464 pixels with blue amid white"
    printf j >&3
    drawn -F "$(printf '\033_Ga=p,i=%s,' "$blue")" "j did not show the blue image sent ahead"
    drawn -F 2-blue.png "j did not name the second image"
    printf k >&3
    drawn -F "$(printf '\033_Ga=p,i=%s,' "$red")" "k did not show the red image again"
    [ "$(sent a=T)" -eq 1 ] && [ "$(sent a=t)" -eq 1 ] || fail "j or k sent an image again"
    printf j >&3
    drawn -E "$(printf '\033_Ga=p,i=%s,.*\033_Ga=p,i=%s,' "$red" "$blue")" "j did not show the blue image again"
fi
printf m >&3
drawn -F '*1 |' "m did not mark the image"
# the mark, on the last image, changed only the status bar, which goes without the image
if [ "$mode" != symbols ] && [ "$(sent a=T) $(sent a=t) $(sent a=p)" != "1 1 3" ]; then
    fail "the mark sent or placed an image again"
fi
kill -TERM "$(cat "$pics/pid")"
wait "$session" || fail "SIGTERM did not end the viewer cleanly"
if grep -a -q 'the terminal mode changed' "$out"; then fail "the viewer left the terminal in another mode"; fi
leave=$(printf '\033[?1049l')
at=$(grep -a -b -o -F "$leave" "$out" | tail -1 | cut -d: -f1)
[ -n "$at" ] || fail "the viewer did not leave the alternate screen"
if [ "$mode" != symbols ]; then
    grep -a -q -F "$(printf '\033_Ga=d,d=A,q=2\033\\\033[0m\033[?7h\033[?25h\033[?1049l')" "$out" ||
        fail "the viewer left its image on the screen"
fi
tail -c +$((at + ${#leave} + 1)) "$out" | grep -a -q -F "$pics/2-blue.png" ||
    fail "-o did not print the marked file once the terminal was back"
echo "$mode: drew $(wc -c <"$out") bytes, then printed the marked $pics/2-blue.png"
