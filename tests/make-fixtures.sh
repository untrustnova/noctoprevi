#!/usr/bin/env bash
#
# noctoprevi - generator fixture video untuk test suite.
# Membuat clip mp4 pendek yang valid, plus file sengaja rusak.

set -uo pipefail

DEST="${1:-}"
if [ -z "$DEST" ]; then
    printf 'pakai: %s <direktori-tujuan>\n' "$0" >&2
    exit 2
fi

command -v ffmpeg >/dev/null 2>&1 || {
    printf 'ffmpeg tidak ditemukan\n' >&2
    exit 3
}

mkdir -p "$DEST" || exit 1

make_clip() {
    local name="$1" color="$2" seconds="$3" size="${4:-640x360}"
    ffmpeg -nostdin -loglevel error -y \
        -f lavfi -i "testsrc2=size=$size:rate=24:duration=$seconds" \
        -pix_fmt yuv420p -c:v libx264 -preset ultrafast -crf 40 \
        -movflags +faststart "$DEST/$name" 2>/dev/null
}

printf 'membuat fixture di %s\n' "$DEST"

make_clip "alpha.mp4" "red" 4 || exit 1
make_clip "bravo.mp4" "blue" 4 || exit 1
make_clip "charlie.mkv" "green" 3 || exit 1

printf 'ini bukan video yang valid' >"$DEST/broken.mp4"
: >"$DEST/empty.mp4"
printf 'ignored' >"$DEST/notes.txt"
mkdir -p "$DEST/subdir"
cp "$DEST/alpha.mp4" "$DEST/subdir/nested.mp4" 2>/dev/null

# Header utuh + durasi valid, tapi payload video di tengah dirusak.
# File seperti ini LALOS ffprobe (VALIDATE_MEDIA=1) tapi gagal decode.
# Hanya yang menangkapnya adalah VALIDATE_MEDIA=2.
make_clip "corrupt.mp4" "yellow" 5 || exit 1
python3 - "$DEST/corrupt.mp4" <<'PY' 2>/dev/null
import sys
path = sys.argv[1]
with open(path, "r+b") as fh:
    fh.seek(20000)
    fh.write(b"\xff" * 20000)
PY

# Terpotong: header ada tapi badan tidak lengkap.
head -c 20000 "$DEST/alpha.mp4" >"$DEST/truncated.mp4" 2>/dev/null

# Terlalu pendek: 0.3 detik, di bawah MIN_DURATION_SEC.
make_clip "tiny.mp4" "purple" 1 >/dev/null 2>&1
ffmpeg -nostdin -loglevel error -y -i "$DEST/tiny.mp4" -t 0.3 -c copy \
    "$DEST/tiny-short.mp4" 2>/dev/null
rm -f "$DEST/tiny.mp4" 2>/dev/null

ls -la "$DEST"
