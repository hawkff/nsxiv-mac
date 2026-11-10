#!/bin/sh
# Runs etc/nsxiv-rifle with a stand-in for the viewer that prints its directory and its
# arguments: one image must start the viewer at that image, from the image's directory, and
# several files, or a directory, must reach the viewer as they are.
set -eu
rifle=$(cd "$(dirname "$0")/.." && pwd)/etc/nsxiv-rifle
dir=$(mktemp -d)
mkdir -p "$dir/bin" "$dir/pics"
printf '#!/bin/sh\nprintf "%%s:" "$(pwd -P)"\nfor a; do printf "[%%s]" "$a"; done\n' >"$dir/bin/nsxiv-mac"
chmod +x "$dir/bin/nsxiv-mac"
touch "$dir/pics/a.jpg" "$dir/pics/b one.PNG"
PATH=$dir/bin:$PATH
here=$(pwd -P)
pics=$(cd "$dir/pics" && pwd -P)

ran=$(sh "$rifle" "$dir/pics/b one.PNG")
[ "$ran" = "$pics:[--start-file][b one.PNG][--][.]" ] ||
    { echo "for one image, nsxiv-rifle ran the viewer as $ran" >&2; exit 1; }
ran=$(sh "$rifle" "$dir/pics/a.jpg" "$dir/pics/b one.PNG")
[ "$ran" = "$here:[--][$dir/pics/a.jpg][$dir/pics/b one.PNG]" ] ||
    { echo "for two images, nsxiv-rifle ran the viewer as $ran" >&2; exit 1; }
ran=$(sh "$rifle" "$dir/pics")
[ "$ran" = "$here:[--][$dir/pics]" ] || { echo "for a directory, nsxiv-rifle ran the viewer as $ran" >&2; exit 1; }
echo "nsxiv-rifle started the viewer at one image, and passed two files and a directory on"
