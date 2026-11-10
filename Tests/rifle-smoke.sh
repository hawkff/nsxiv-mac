#!/bin/sh
# Runs etc/nsxiv-rifle on one image, with a stand-in for the viewer that prints its arguments
# and then its stdin: the viewer must start at that image, among the images of its directory
# listed in one pass, without the hidden file, the text file, the directory and the FIFO that
# sit there under image names. A file that is no image by its name must open alone, and so
# must the image when the list cannot be written.
set -eu
rifle=$(cd "$(dirname "$0")/.." && pwd)/etc/nsxiv-rifle
dir=$(mktemp -d)
mkdir -p "$dir/bin" "$dir/pics/album.png"
printf '#!/bin/sh\necho "$*"\ncat\n' >"$dir/bin/nsxiv-mac"
chmod +x "$dir/bin/nsxiv-mac"
touch "$dir/pics/a.jpg" "$dir/pics/b one.PNG" "$dir/pics/c.txt" "$dir/pics/.d.png" "$dir/pics/e.webp"
ln -s a.jpg "$dir/pics/f.jpeg"
mkfifo "$dir/pics/pipe.png"
PATH=$dir/bin:$PATH

ran=$(sh "$rifle" "$dir/pics/b one.PNG")
[ "$ran" = "-i -n 2
./a.jpg
./b one.PNG
./e.webp
./f.jpeg" ] || { echo "nsxiv-rifle ran the viewer as: $ran" >&2; exit 1; }
ran=$(sh "$rifle" "$dir/pics/c.txt" </dev/null)
[ "$ran" = "-- c.txt" ] || { echo "nsxiv-rifle opened a text file as: $ran" >&2; exit 1; }
# a mktemp that names a file in a directory that is not there, so the list cannot be written
printf '#!/bin/sh\necho "$0.none/list"\n' >"$dir/bin/mktemp"
chmod +x "$dir/bin/mktemp"
ran=$(sh "$rifle" "$dir/pics/b one.PNG" 2>/dev/null </dev/null)
[ "$ran" = "-- b one.PNG" ] || { echo "without its list, nsxiv-rifle ran the viewer as: $ran" >&2; exit 1; }
echo "nsxiv-rifle started the viewer at the second of four images"
