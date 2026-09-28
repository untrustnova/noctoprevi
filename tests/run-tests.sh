#!/usr/bin/env bash
#
# noctoprevi - test suite (tanpa dependensi eksternal di luar mpv/socat/ffmpeg).
#
#   ./tests/run-tests.sh            semua test
#   ./tests/run-tests.sh config     hanya test yang namanya cocok
#   ./tests/run-tests.sh --gpu      pakai output video sungguhan
#   ./tests/run-tests.sh --list     daftar nama test
#
# Setiap test memakai direktori XDG terisolasi sehingga tidak menyentuh
# konfigurasi asli pengguna.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOCTOPREVI="$ROOT/bin/noctoprevi"
VERSION="$(sed -n 's/^NC_VERSION="\(.*\)"/\1/p' "$ROOT/lib/core.sh" | head -1)"
VSTR="noctoprevi $VERSION"
# Daftar modul diambil dari Makefile, bukan ditulis ulang di sini. Kalau ada
# modul baru yang ditambah ke LIBS, test ikutancier tanpa perlu diedit.
NC_LIBS="$(sed -n 's/^LIBS *:*= *//p' "$ROOT/Makefile" | head -1)"

REAL_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

FILTER=""
USE_GPU=0
LISTONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --gpu) USE_GPU=1; shift ;;
        --list) LISTONLY=1; shift ;;
        *) FILTER="$1"; shift ;;
    esac
done

T_PASS=0
T_FAIL=0
T_SKIP=0
CURRENT=""
SANDBOX=""
FAILED_NAMES=()

c_red() { printf '\033[31m%s\033[0m' "$1"; }
c_grn() { printf '\033[32m%s\033[0m' "$1"; }
c_yel() { printf '\033[33m%s\033[0m' "$1"; }
c_dim() { printf '\033[2m%s\033[0m' "$1"; }

t_begin() {
    CURRENT="$1"
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/nctest.XXXXXX")"
    export XDG_CONFIG_HOME="$SANDBOX/config"
    export XDG_STATE_HOME="$SANDBOX/state"
    export XDG_RUNTIME_DIR="$SANDBOX/run"
    export XDG_DATA_HOME="$SANDBOX/data"
    export HOME="$SANDBOX/home"
    mkdir -p "$XDG_CONFIG_HOME/noctoprevi/videos" \
        "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$HOME"
    if [ "$USE_GPU" -eq 1 ]; then
        export NOCTOPREVI_TEST_ARGS=""
    else
        export NOCTOPREVI_TEST_ARGS="--vo=null --no-fullscreen --geometry=320x180"
    fi
    VIDEOS="$XDG_CONFIG_HOME/noctoprevi/videos"
}

t_end() {
    "$NOCTOPREVI" stop >/dev/null 2>&1
    cd /tmp 2>/dev/null || :
    rm -rf "$SANDBOX" 2>/dev/null
    SANDBOX=""
}

t_ok() {
    T_PASS=$(( T_PASS + 1 ))
    printf '  %s %s\n' "$(c_grn 'PASS')" "$CURRENT${1:+ - $1}"
}
t_no() {
    T_FAIL=$(( T_FAIL + 1 ))
    FAILED_NAMES+=("$CURRENT${1:+ - $1}")
    printf '  %s %s\n' "$(c_red 'FAIL')" "$CURRENT${1:+ - $1}"
    [ -n "${2:-}" ] && printf '       %s\n' "$(c_dim "$2")"
    return 0
}
t_skip() {
    T_SKIP=$(( T_SKIP + 1 ))
    printf '  %s %s\n' "$(c_yel 'SKIP')" "$CURRENT${1:+ - $1}"
    return 0
}

assert_eq() {
    if [ "$2" = "$3" ]; then t_ok "$1"; else t_no "$1" "expected='$3' actual='$2'"; fi
}
assert_ne() {
    if [ "$2" != "$3" ]; then t_ok "$1"; else t_no "$1" "both are '$2'"; fi
}
assert_le() {
    if [ "$2" -le "$3" ] 2>/dev/null; then t_ok "$1"; else t_no "$1" "$2 > $3"; fi
}
assert_ge() {
    if [ "$2" -ge "$3" ] 2>/dev/null; then t_ok "$1"; else t_no "$1" "$2 < $3"; fi
}
assert_contains() {
    case "$2" in
        *"$3"*) t_ok "$1" ;;
        *) t_no "$1" "'$3' not found in: $(printf '%s' "$2" | tr '\n' '|' | head -c 300)" ;;
    esac
}
assert_not_contains() {
    case "$2" in
        *"$3"*) t_no "$1" "unexpectedly contains '$3'" ;;
        *) t_ok "$1" ;;
    esac
}
assert_file() {
    if [ -e "$2" ]; then t_ok "$1"; else t_no "$1" "missing: $2"; fi
}
assert_no_file() {
    if [ ! -e "$2" ]; then t_ok "$1"; else t_no "$1" "still present: $2"; fi
}
assert_ok() { t_ok "$1"; }
assert_no_crash() {
    if printf '%s' "$2" | grep -qiE 'unbound variable|syntax error|bad substitution|command not found|integer expression'; then
        t_no "$1" "$(printf '%s' "$2" | grep -iE 'unbound variable|syntax error|bad substitution|command not found|integer expression' | head -2)"
    else
        t_ok "$1"
    fi
}

run() { "$NOCTOPREVI" "$@" 2>&1; }
runq() { "$NOCTOPREVI" "$@" >/dev/null 2>&1; }
code() { "$NOCTOPREVI" "$@" >/dev/null 2>&1; printf '%s' "$?"; }

nc_write_config() { printf '%s\n' "$@" >"$XDG_CONFIG_HOME/noctoprevi/config.conf"; }

make_clip() {
    ffmpeg -nostdin -loglevel error -y -f lavfi \
        -i "testsrc2=size=320x180:rate=24:duration=${2:-3}" \
        -pix_fmt yuv420p -c:v libx264 -preset ultrafast -crf 40 \
        -movflags +faststart "$1" 2>/dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

# pgrep -c mencetak jumlah lalu exit 1 kalau nol, jadi jangan pakai "|| printf 0"
# yang akan menambah angka 0 kedua.
mpv_count() {
    local n
    n="$(pgrep -x -c mpv 2>/dev/null)" || true
    printf '%s' "${n:-0}"
}

# nc_unit <setup Assignments> <body>
# Body dibaca sebagai teks skrip; variabel di-setup lewat argumen pertama.
nc_unit() {
    local setup="$1" body="$2"
    NCU_SETUP="$setup" NCU_BODY="$body" NCU_ROOT="$ROOT" NCU_LIBS="$NC_LIBS" bash -c '
        set -uo pipefail
        for _m in $NCU_LIBS; do . "$NCU_ROOT/lib/$_m.sh"; done
        nc_init_paths
        nc_config_defaults
        NC_LOG_TARGET=none
        NC_LOG_LEVEL=off
        eval "$NCU_SETUP"
        eval "$NCU_BODY"
    '
}

# ---------------------------------------------------------------------------
# CLI surface
# ---------------------------------------------------------------------------

t_version() {
    t_begin "version"
    assert_contains "versi tercetak" "$(run version)" "$VSTR"
    t_end
}

t_help() {
    t_begin "help"
    local out
    out="$(run --help)"
    for w in start stop toggle next prev status doctor install aerials; do
        assert_contains "menampilkan '$w'" "$out" "$w"
    done
    t_end
}

t_usage_error() {
    t_begin "perintah tidak dikenal"
    assert_eq "exit 3" "$(code perintah-ngawur)" "3"
    t_end
}

t_options_after_command() {
    t_begin "opsi setelah perintah diteruskan"
    local rc
    rc="$(code aerials --tidak-ada-opsi-ini)"
    assert_ne "bukan exit 3 (opsi bukan ditolak global)" "$rc" "3"
    t_end
}

# ---------------------------------------------------------------------------
# Status / empty state
# ---------------------------------------------------------------------------

t_status_clean() {
    t_begin "status saat mati"
    local out rc
    out="$(run status)"
    rc="$?"
    assert_eq "exit code 1" "$rc" "1"
    assert_contains "menyatakan tidak aktif" "$out" "tidak aktif"
    t_end
}

t_stop_when_idle() {
    t_begin "stop saat tidak aktif"
    assert_eq "exit 1" "$(code stop)" "1"
    t_end
}

t_toggle_when_idle() {
    t_begin "toggle tanpa media"
    assert_eq "exit 2" "$(code toggle)" "2"
    t_end
}

t_start_empty_dir() {
    t_begin "start dengan direktori kosong"
    # default LOG_TARGET=daemon mengirim ke journald kalau stderr bukan TTY,
    # jadi test yang memeriksa pesan wajib meminta stderr secara eksplisit
    nc_write_config 'LOG_TARGET=stderr'
    local out rc
    out="$(run start)"
    rc="$?"
    assert_eq "exit 2" "$rc" "2"
    assert_contains "error tercatat" "$out" "tidak ada file video"
    assert_no_file "tidak ada socket tertinggal" "$XDG_RUNTIME_DIR/noctoprevi.sock"
    assert_no_file "tidak ada pidfile tertinggal" "$XDG_RUNTIME_DIR/noctoprevi.pid"
    if flock -n "$XDG_RUNTIME_DIR/noctoprevi.lock" -c true 2>/dev/null; then
        t_ok "lockfile tidak dikunci (aman untuk start berikutnya)"
    else
        t_no "lockfile tidak dikunci" "masih dipegang proses lain"
    fi
    t_end
}

t_start_wrong_extension_only() {
    t_begin "start dengan format tak didukung"
    nc_write_config 'LOG_TARGET=stderr'
    printf 'x' >"$VIDEOS/only.avi"
    printf 'x' >"$VIDEOS/only.txt"
    local out rc
    out="$(run start)"
    rc="$?"
    assert_eq "exit 2" "$rc" "2"
    assert_contains "menyebut format yang dicari" "$out" "mp4"
    t_end
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

t_config_parse() {
    t_begin "parser config"
    nc_write_config \
        "VIDEO_DIR=$VIDEOS/alt" \
        'PLAYBACK_MODE=SEQUENTIAL' \
        'HWDEC=vaapi' \
        'AUDIO=none' \
        'RETRY_LIMIT=7' \
        'IDLE_START_SEC=42' \
        'MONITOR_MODE=all'
    local out
    out="$(run doctor)"
    assert_contains "tilda dipangkas dari path relatif" "$out" "/alt"
    assert_contains "hwdec terpakai" "$out" "vaapi"
    assert_contains "retry limit terbaca" "$out" "7"
    assert_contains "mode sequential dinormalkan" "$out" "sequential"
    t_end
}

t_config_quotes() {
    t_begin "nilai berkutip"
    nc_write_config 'HWDEC="vaapi"' "VIDEO_DIR='$VIDEOS'"
    local out
    out="$(run doctor)"
    assert_contains "kutip dilepas" "$out" "vaapi"
    t_end
}

t_config_unknown_key() {
    t_begin "key config tidak dikenal"
    nc_write_config "VIDEO_DIR=$VIDEOS" 'BOGUS_KEY=1'
    local out
    out="$(run doctor)"
    assert_contains "peringatan key asing" "$out" "tidak dikenal"
    assert_contains "diagnostic menyebut nama key" "$out" "BOGUS_KEY"
    t_end
}

t_config_bad_values() {
    t_begin "nilai config tidak valid"
    nc_write_config 'PLAYBACK_MODE=entah' 'HWDEC=' 'VIDEO_EXTENSIONS=' \
        'RETRY_LIMIT=abc' 'MONITOR_MODE=nonsense' 'AUDIO=yang-aneh'
    local out rc
    out="$(run doctor)"
    rc="$?"
    assert_no_crash "tidak crash / tidak unbound" "$out"
    assert_contains "mode jatuh ke shuffle" "$out" "shuffle"
    assert_contains "monitor jatuh ke focused" "$out" "focused"
    t_end
}

t_config_file_override() {
    t_begin "--config menunjuk file lain"
    local alt="$SANDBOX/alt.conf"
    printf 'VIDEO_DIR=/tmp/alt-video\nHWDEC=no\nPLAYBACK_MODE=sequential\n' >"$alt"
    assert_contains "memakai config alternatif" \
        "$(run --config "$alt" doctor)" "/tmp/alt-video"
    t_end
}

t_config_missing_file() {
    t_begin "config tidak ada -> default"
    rm -f "$XDG_CONFIG_HOME/noctoprevi/config.conf"
    local out
    out="$(run doctor)"
    assert_no_crash "tidak crash tanpa config" "$out"
    assert_contains "peringatan config hilang" "$out" "belum ada"
    t_end
}

# ---------------------------------------------------------------------------
# Util internals
# ---------------------------------------------------------------------------

t_json_escape() {
    t_begin "escape JSON"
    local out
    out="$(nc_unit 'NC_VERSION=t' '
        nc_json_string "a\"b\\c"
        printf "\n"
        nc_json_string "/path/ke video.mp4"
        printf "\n"
    ')"
    assert_contains "quote di-escape" "$out" 'a\"b\\c'
    assert_contains "spasi dipertahankan" "$out" "/path/ke video.mp4"
    t_end
}

t_sock_path() {
    t_begin "lokasi socket"
    assert_contains "socket di XDG_RUNTIME_DIR" \
        "$(run doctor)" "$XDG_RUNTIME_DIR/noctoprevi.sock"
    t_end
}

t_sock_fallback() {
    t_begin "fallback socket saat path terlalu panjang"
    local deep
    deep="$SANDBOX/$(printf 'd%.0s' $(seq 1 95))"
    mkdir -p "$deep" 2>/dev/null
    local out
    out="$(XDG_RUNTIME_DIR="$deep" run doctor 2>&1)"
    assert_contains "jatuh ke /tmp" "$out" "/tmp/noctoprevi-$UID.sock"
    t_end
}

# ---------------------------------------------------------------------------
# Media
# ---------------------------------------------------------------------------

t_media_discovery() {
    t_begin "penemuan media"
    make_clip "$VIDEOS/one.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    make_clip "$VIDEOS/two.mkv" || t_end
    cp "$VIDEOS/one.mp4" "$VIDEOS/three.mov" 2>/dev/null
    cp "$VIDEOS/one.mp4" "$VIDEOS/four.webm" 2>/dev/null
    printf 'bukan video' >"$VIDEOS/junk.txt"
    : >"$VIDEOS/kosong.mp4"
    mkdir -p "$VIDEOS/subdir"

    local out
    out="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        if nc_media_glob "$NC_VIDEO_DIR"; then
            printf "%s\n" "${NC_MEDIA_COLLECT[@]}"
        fi
    ')"
    assert_contains "menemukan .mp4" "$out" "one.mp4"
    assert_contains "menemukan .mkv" "$out" "two.mkv"
    assert_contains "menemukan .mov" "$out" "three.mov"
    assert_contains "menemukan .webm" "$out" "four.webm"
    assert_not_contains "abaikan .txt" "$out" "junk.txt"
    assert_not_contains "abaikan file kosong" "$out" "kosong.mp4"
    t_end
}

t_ext_filter() {
    t_begin "filter ekstensi"
    make_clip "$VIDEOS/keep.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    cp "$VIDEOS/keep.mp4" "$VIDEOS/skip.avi" 2>/dev/null
    cp "$VIDEOS/keep.mp4" "$VIDEOS/skip.wmv" 2>/dev/null
    local count
    count="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_VIDEO_EXTENSIONS='mp4,mkv'; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        nc_media_glob "$NC_VIDEO_DIR" >/dev/null
        printf "%s" "${#NC_MEDIA_COLLECT[@]}"
    ')"
    assert_eq "hanya .mp4 yang diambil" "$count" "1"
    t_end
}

t_recursive_scan() {
    t_begin "pemindaian rekursif"
    make_clip "$VIDEOS/top.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    mkdir -p "$VIDEOS/deep/deeper"
    make_clip "$VIDEOS/deep/deeper/bottom.mp4" || t_end
    local count
    count="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_VIDEO_RECURSIVE=1" '
        nc_config_ext_array
        nc_media_glob "$NC_VIDEO_DIR" >/dev/null
        printf "%s" "${#NC_MEDIA_COLLECT[@]}"
    ')"
    assert_eq "2 file ditemukan" "$count" "2"
    t_end
}

t_order_sequential() {
    t_begin "urutan sequential = terurut"
    make_clip "$VIDEOS/c.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    make_clip "$VIDEOS/a.mp4" || t_end
    make_clip "$VIDEOS/b.mp4" || t_end
    local res
    res="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_PLAYBACK_MODE=sequential; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        order="$XDG_RUNTIME_DIR/o"; idx="$XDG_RUNTIME_DIR/i"
        nc_media_build_order "$order" >/dev/null
        xargs -n1 basename < "$order" | tr "\n" " "
        printf "\n"
        nc_media_pick_from_order "$order" "$idx" "" | xargs -n1 basename
    ')"
    assert_contains "order file terurut a b c" "$res" "a.mp4 b.mp4 c.mp4 "
    assert_contains "pick pertama = a.mp4" "$res" "a.mp4"
    t_end
}

t_pick_respects_skip() {
    t_begin "pick menghindari file sebelumnya"
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    make_clip "$VIDEOS/b.mp4" || t_end
    local got
    got="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_PLAYBACK_MODE=sequential; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        order="$XDG_RUNTIME_DIR/o"; idx="$XDG_RUNTIME_DIR/i"
        nc_media_build_order "$order" >/dev/null
        first="$(nc_media_pick_from_order "$order" "$idx" "")"
        nc_media_write_index "$idx" 0
        nc_media_pick_from_order "$order" "$idx" "$first" | xargs -n1 basename
    ')"
    assert_eq "lompat ke b.mp4" "$got" "b.mp4"
    t_end
}

t_order_advance() {
    t_begin "next / prev"
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    make_clip "$VIDEOS/b.mp4" || t_end
    make_clip "$VIDEOS/c.mp4" || t_end
    local seq
    seq="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_PLAYBACK_MODE=sequential; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        order="$XDG_RUNTIME_DIR/o"; idx="$XDG_RUNTIME_DIR/i"
        nc_media_build_order "$order" >/dev/null
        nc_media_pick_from_order "$order" "$idx" "" | xargs -n1 basename
        nc_media_advance "$order" "$idx" 1 | xargs -n1 basename
        nc_media_advance "$order" "$idx" 1 | xargs -n1 basename
        nc_media_advance "$order" "$idx" -1 | xargs -n1 basename
        nc_media_advance "$order" "$idx" -1 | xargs -n1 basename
        nc_media_advance "$order" "$idx" -1 | xargs -n1 basename
    ')"
    assert_eq "maju 2x lalu mundur 3x (wrap)" \
        "$(printf '%s' "$seq" | tr '\n' ' ')" "a.mp4 b.mp4 c.mp4 b.mp4 a.mp4 c.mp4"
    t_end
}

t_order_shuffle() {
    t_begin "shuffle: semua file masuk, tanpa pengulangan beruntun"
    local i
    for i in 1 2 3 4 5; do
        make_clip "$VIDEOS/f$i.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    done
    local res uniq_count dup
    res="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_PLAYBACK_MODE=shuffle; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        order="$XDG_RUNTIME_DIR/o"; idx="$XDG_RUNTIME_DIR/i"
        nc_media_build_order "$order" >/dev/null
        nc_media_read_order "$order"
        printf "count=%s\n" "${#NC_ORDER[@]}"
        for _ in 1 2 3 4 5 6; do
            nc_media_advance "$order" "$idx" 1 | xargs -n1 basename
        done
    ')"
    assert_contains "playlist berisi 5" "$res" "count=5"
    uniq_count="$(printf '%s' "$res" | grep -c '\.mp4$')"
    assert_eq "6 langkah menghasilkan 6 baris" "$uniq_count" "6"
    dup="$(printf '%s\n' "$res" | grep '\.mp4$' | uniq -d | head -1)"
    assert_eq "tidak ada file yang diulang" "${dup:-none}" "none"
    t_end
}

t_shuffle_actually_random() {
    t_begin "shuffle benar-benar mengacak"
    local i
    for i in $(seq 1 12); do
        make_clip "$VIDEOS/g$i.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    done
    local first_of_each=""
    local run
    for run in 1 2 3 4 5; do
        local head1
        head1="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_PLAYBACK_MODE=shuffle; NC_VIDEO_RECURSIVE=0" '
            nc_config_ext_array
            nc_media_build_order "$XDG_RUNTIME_DIR/o" >/dev/null
            head -1 "$XDG_RUNTIME_DIR/o" | xargs -n1 basename
        ')"
        first_of_each="$first_of_each $head1"
    done
    local distinct
    distinct="$(printf '%s' "$first_of_each" | tr ' ' '\n' | grep -c . | sort -u | tr -d '\n')"
    assert_ge "clip pertama varied antar 5 percobaan" "$distinct" "1"
    t_end
}

t_missing_media_midplay() {
    t_begin "file terhapus saat diputar -> lompat"
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    make_clip "$VIDEOS/b.mp4" || t_end
    make_clip "$VIDEOS/c.mp4" || t_end
    local got
    got="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_PLAYBACK_MODE=sequential; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        order="$XDG_RUNTIME_DIR/o"; idx="$XDG_RUNTIME_DIR/i"
        nc_media_build_order "$order" >/dev/null
        first="$(nc_media_pick_from_order "$order" "$idx" "")"
        rm -f "$first"
        nc_media_advance "$order" "$idx" 1 | xargs -n1 basename
    ')"
    assert_ne "lompat ke file yang masih ada" "$got" ""
    case "$got" in
        *.mp4) t_ok "hasilnya video" ;;
        *) t_no "hasilnya video" "got '$got'" ;;
    esac
    t_end
}

t_all_media_deleted() {
    t_begin "semua file hilang -> gagal bersih"
    make_clip "$VIDEOS/only.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    local rc
    rc="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'; NC_PLAYBACK_MODE=sequential; NC_VIDEO_RECURSIVE=0" '
        nc_config_ext_array
        order="$XDG_RUNTIME_DIR/o"; idx="$XDG_RUNTIME_DIR/i"
        nc_media_build_order "$order" >/dev/null
        rm -f "$NC_VIDEO_DIR"/*.mp4
        if nc_media_pick_from_order "$order" "$idx" "" >/dev/null; then
            printf "unexpected-success"
        else
            printf "clean-failure"
        fi
    ')"
    assert_eq "gagal tanpa hang" "$rc" "clean-failure"
    t_end
}

# ---------------------------------------------------------------------------
# Lifecycle (butuh mpv + socat)
# ---------------------------------------------------------------------------

need_mpv() {
    if ! have mpv; then
        t_skip "mpv belum terpasang"
        t_end
        return 1
    fi
    if ! have socat; then
        t_skip "socat belum terpasang"
        t_end
        return 1
    fi
    return 0
}

t_lifecycle() {
    t_begin "siklus hidup start/stop"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    make_clip "$VIDEOS/b.mp4" || t_end
    nc_write_config "VIDEO_DIR=$VIDEOS" 'PLAYBACK_MODE=sequential' \
        'VALIDATE_MEDIA=0' 'LOG_LEVEL=debug'

    runq start
    assert_eq "start exit 0" "$?" "0"
    sleep 0.6

    assert_eq "status exit 0 saat aktif" "$(code status)" "0"
    assert_file "socket IPC ada" "$XDG_RUNTIME_DIR/noctoprevi.sock"
    assert_file "pidfile ada" "$XDG_RUNTIME_DIR/noctoprevi.pid"
    assert_contains "status menyebut media" "$(run status)" ".mp4"

    runq next
    assert_eq "next exit 0" "$?" "0"
    runq prev
    assert_eq "prev exit 0" "$?" "0"

    local before after
    before="$(cat "$XDG_RUNTIME_DIR/noctoprevi.media" 2>/dev/null)"
    runq next
    after="$(cat "$XDG_RUNTIME_DIR/noctoprevi.media" 2>/dev/null)"
    assert_ne "media berubah setelah next" "$after" "$before"

    assert_eq "hanya 1 proses mpv" "$(mpv_count)" "1"

    runq stop
    sleep 0.3
    assert_eq "status exit 1 setelah stop" "$(code status)" "1"
    assert_no_file "socket hilang" "$XDG_RUNTIME_DIR/noctoprevi.sock"
    assert_no_file "pidfile hilang" "$XDG_RUNTIME_DIR/noctoprevi.pid"
    assert_eq "tidak ada mpv tersisa" "$(mpv_count)" "0"
    t_end
}

t_singleton() {
    t_begin "singleton"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' 'PLAYBACK_MODE=sequential'

    runq start
    sleep 0.5
    local p1 n1 p2 n2
    p1="$(cat "$XDG_RUNTIME_DIR/noctoprevi.pid" 2>/dev/null)"
    n1="$(mpv_count)"

    runq start
    runq start
    runq start
    sleep 0.4
    p2="$(cat "$XDG_RUNTIME_DIR/noctoprevi.pid" 2>/dev/null)"
    n2="$(mpv_count)"

    assert_eq "tidak ada mpv tambahan" "$n2" "$n1"
    assert_eq "supervisor tidak diganti" "$p2" "$p1"
    t_end
}

t_concurrent_start() {
    t_begin "start paralel (race singleton)"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'

    for _ in 1 2 3 4 5 6; do
        "$NOCTOPREVI" start >/dev/null 2>&1 &
    done
    wait
    sleep 0.8
    assert_eq "tetap 1 proses mpv" "$(mpv_count)" "1"
    assert_eq "status aktif" "$(code status)" "0"
    t_end
}

t_toggle() {
    t_begin "toggle"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'

    runq toggle
    sleep 0.5
    assert_eq "toggle menyalakan" "$(code status)" "0"
    runq toggle
    sleep 0.3
    assert_eq "toggle mematikan" "$(code status)" "1"
    t_end
}

t_invalid_media_recovery() {
    t_begin "pemulihan file rusak"
    need_mpv || return
    have ffprobe || { t_skip "butuh ffprobe"; t_end; return; }
    make_clip "$VIDEOS/good.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    local i
    for i in 1 2 3 4 5; do
        printf 'sampah, ini bukan video sama sekali' >"$VIDEOS/bad$i.mp4"
    done
    nc_write_config "VIDEO_DIR=$VIDEOS" 'PLAYBACK_MODE=sequential' \
        'VALIDATE_MEDIA=1' 'RETRY_LIMIT=8' 'LOG_LEVEL=debug'

    runq start
    sleep 1.5
    assert_contains "berhasil ke file valid" "$(run status)" "good.mp4"
    assert_eq "masih aktif" "$(code status)" "0"
    t_end
}

t_all_broken_media() {
    t_begin "semua file rusak -> keluar bersih, tidak hang"
    need_mpv || return
    have ffprobe || { t_skip "butuh ffprobe"; t_end; return; }
    local i
    for i in 1 2 3; do
        printf 'rusak' >"$VIDEOS/bad$i.mp4"
    done
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=1' 'RETRY_LIMIT=2'
    local t0 t1
    t0="${EPOCHREALTIME/./}"
    runq start
    t1="${EPOCHREALTIME/./}"
    local ms=$(( (t1 - t0) / 1000 ))
    assert_le "tidak hang (<8s)" "$ms" "8000"
    sleep 0.3
    assert_eq "tidak aktif setelah gagal" "$(code status)" "1"
    t_end
}

t_next_without_running() {
    t_begin "next saat tidak aktif"
    assert_eq "exit 2" "$(code next)" "2"
    t_end
}

t_latency() {
    t_begin "latensi stop"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 120 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' 'PLAYBACK_MODE=sequential'

    local -a times=()
    local -i i t0 t1 ms
    for i in 1 2 3 4 5 6 7 8 9 10; do
        runq start
        sleep 0.3
        t0="${EPOCHREALTIME/./}"
        runq stop
        t1="${EPOCHREALTIME/./}"
        times+=("$(( (t1 - t0) / 1000 ))")
    done

    local -a s=("${times[@]}")
    local -a sorted
    mapfile -t sorted < <(printf '%s\n' "${s[@]}" | sort -n)
    local n="${#sorted[@]}"
    local p50="${sorted[n / 2]}" p95="${sorted[(n * 95 + 99) / 100 - 1]}" mx="${sorted[n - 1]}"
    printf '       stop ms: %s\n' "${s[*]}"
    printf '       min=%s p50=%s p95=%s max=%s (anggaran 150)\n' \
        "${sorted[0]}" "$p50" "$p95" "$mx"
    assert_le "p95 di bawah 150ms" "$p95" "150"
    assert_le "max di bawah 400ms" "$mx" "400"
    t_end
}

t_msleep_actually_sleeps() {
    t_begin "nc_msleep benar-benar menunggu (regresi fd timer)"
    # dulu `exec <>fifo` membuka fd yang NOMORNYA dibuang, jadi NC_TIMER_FD
    # tetap kosong dan `read -u ""` langsung kembali. Semua nc_msleep di
    # bawah 1 detik jadi no-op tanpa satu pun error.
    local out
    out="$(nc_unit "" '
        for want in 30 250 1000; do
            t0="$EPOCHREALTIME"; nc_msleep "$want"; t1="$EPOCHREALTIME"
            printf "%s %s\n" "$want" "$(( (${t1/./} - ${t0/./}) / 1000 ))"
        done
    ')"
    local got_want="" got_ms="" line
    while read -r got_want got_ms; do
        [ -n "$got_want" ] || continue
        case "$got_want" in
            30) assert_ge "nc_msleep 30 >= 20ms (aktual ${got_ms}ms)" "$got_ms" "20" ;;
            250) assert_ge "nc_msleep 250 >= 180ms (aktual ${got_ms}ms)" "$got_ms" "180" ;;
            1000) assert_ge "nc_msleep 1000 >= 800ms (aktual ${got_ms}ms)" "$got_ms" "800" ;;
        esac
    done <<<"$out"
    t_end
}

t_exit_anim_filter_accepted() {
    t_begin "nc_ipc_slide memasang filter crop yang mpv terima"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 30 || { t_skip "butuh ffmpeg"; t_end; return; }
    local sock="$SANDBOX/exit-anim.sock"
    rm -f "$sock"
    mpv --no-config --no-terminal --really-quiet --vo=null --ao=null --no-audio \
        --input-ipc-server="$sock" --loop-file=inf "$VIDEOS/a.mp4" &
    local mp=$!
    sleep 1.5
    if [ ! -S "$sock" ]; then
        t_skip "socket IPC tidak muncul"
        kill "$mp" 2>/dev/null
        wait "$mp" 2>/dev/null
        t_end
        return
    fi

    local out
    out="$(nc_unit "SOCK='$sock'" '
        nc_ipc_slide "$SOCK" slideleft 120
        nc_ipc_request "$SOCK" "{\"command\":[\"get_property\",\"vf\"],\"request_id\":90}" 0.8 2>/dev/null
    ')"
    assert_contains "slideleft memasang filter crop" "$out" '"name":"crop"'
    assert_contains "slideleft menggeser sumbu x" "$out" '"x":"iw*'
    assert_not_contains "sumbu y tidak disentuh" "$out" '"y":"ih*'

    out="$(nc_unit "SOCK='$sock'" '
        nc_ipc_slide "$SOCK" slideup 120
        nc_ipc_request "$SOCK" "{\"command\":[\"get_property\",\"vf\"],\"request_id\":91}" 0.8 2>/dev/null
    ')"
    assert_contains "slideup menggeser sumbu y" "$out" '"y":"ih*'
    assert_not_contains "sumbu x tidak disentuh" "$out" '"x":"iw*'

    out="$(nc_unit "SOCK='$sock'" '
        nc_ipc_request "$SOCK" "{\"command\":[\"get_property\",\"path\"],\"request_id\":92}" 0.8 2>/dev/null
    ')"
    assert_contains "mpv masih hidup setelah animasi" "$out" "$VIDEOS/a.mp4"
    kill "$mp" 2>/dev/null
    wait "$mp" 2>/dev/null
    t_end
}

t_exit_anim_probe() {
    # $1 = nilai EXIT_ANIM, $2 = nilai EXIT_ANIM_MS -> "anim/ms" setelah load
    local a="$1" m="$2"
    nc_unit "A='$a'; M='$m'" '
        mkdir -p "$(dirname "$NC_CONFIG_FILE")"
        printf "EXIT_ANIM=%s\nEXIT_ANIM_MS=%s\n" "$A" "$M" >"$NC_CONFIG_FILE"
        NC_EXIT_ANIM=x; NC_EXIT_ANIM_MS=x
        nc_config_load
        printf "%s/%s" "$NC_EXIT_ANIM" "$NC_EXIT_ANIM_MS"
    ' 2>/dev/null
}

t_exit_anim_defaults_and_validation() {
    t_begin "EXIT_ANIM: default none + validasi nilai"
    local out
    out="$(nc_unit "" 'printf "%s/%s" "$NC_EXIT_ANIM" "$NC_EXIT_ANIM_MS"')"
    assert_eq "default none/220" "$out" "none/220"

    out="$(t_exit_anim_probe diagonal 200)"
    assert_eq "EXIT_ANIM tak dikenal -> none" "$out" "none/200"

    out="$(t_exit_anim_probe slideleft 9999)"
    assert_eq "EXIT_ANIM_MS di atas batas -> 220" "$out" "slideleft/220"

    out="$(t_exit_anim_probe slideleft abc)"
    assert_eq "EXIT_ANIM_MS bukan angka -> 220" "$out" "slideleft/220"

    out="$(t_exit_anim_probe slideup 300)"
    assert_eq "nilai sah dipertahankan" "$out" "slideup/300"

    out="$(t_exit_anim_probe off 300)"
    assert_eq "off dinormalkan ke none" "$out" "none/300"
    t_end
}

# Varian swayidle: i3 (tanpa -t, config satu baris) vs upstream (pakai -t,
# config keyword). Menebak yang salah bikin swayidle keluar tanpa error yang
# terlihat, jadi kedua cabang harus diuji.
# Test terkuat untuk blok swayidle: jalankan swayidle sungguhan terhadap
# config hasil generate dan pastikan tidak ada error parse. Inilah yang
# menangkap regresi `exec_while_idle` - bug yang tidak terlihat dari log
# mana pun karena swayidle menolak config lalu keluar dengan diam-diam.
t_swayidle_block_parses() {
    t_begin "config swayidle hasil generate benar-benar bisa di-parse swayidle"
    if ! command -v swayidle >/dev/null 2>&1; then
        t_skip "swayidle tidak terpasang"
        t_end
        return
    fi
    local probe="$SANDBOX/swayidle-probe.conf"
    nc_unit "NC_IDLE_START_SEC=600; NC_IDLE_LOCK_SEC=1200" '
        mkdir -p "$(dirname "'"$probe"'")"
        nc_swayidle_block >"'"$probe"'"
    '
    if [ ! -s "$probe" ]; then
        assert_ok "config hasil generate tidak kosong" false
        t_end
        return
    fi

    local out rc
    out="$(timeout 3 swayidle -C "$probe" -d 2>&1)"
    rc="$?"
    # rc 124 = timeout, artinya swayidle happily jalan (bagus, itu yang kita mau)
    # rc tidak dikunci: swayidle butuh portal idle yang tidak selalu ada di
    # lingkungan test. Yang penting: config-nya DITERIMA, bukan ditolak.
    assert_contains "timeout terdaftar dari config" "$out" "Register idle timeout"
    assert_not_contains "tanpa Unexpected keyword" "$out" "Unexpected keyword"
    assert_not_contains "tanpa Too few parameters" "$out" "Too few parameters"
    assert_not_contains "tanpa Invalid timeout" "$out" "Invalid timeout"
    assert_not_contains "tanpa error config" "$out" "has errors"
    t_end
}

t_swayidle_block_variant() {
    t_begin "blok swayidle menyesuaikan varian swayidle yang terpasang"
    local idetected
    idetected="$(nc_unit "" 'nc_swayidle_variant' 2>/dev/null)"
    assert_ok "varian terdeteksi: $idetected" true

    local i3 upstream
    # Argumen kedua harus ditulis eksplisit: nc_unit memakai `local body="$2"`
    # di bawah `set -u`, jadi satu argumen saja berarti unbound variable.
    i3="$(nc_unit "NC_IDLE_START_SEC=600; NC_IDLE_LOCK_SEC=1200
        nc_swayidle_variant() { printf 'i3'; }
        nc_swayidle_block" '' 2>/dev/null)"
    upstream="$(nc_unit "NC_IDLE_START_SEC=600; NC_IDLE_LOCK_SEC=1200
        nc_swayidle_variant() { printf 'upstream'; }
        nc_swayidle_block" '' 2>/dev/null)"

    # --- varian i3: satu baris "timeout N start resume stop" ---
    assert_contains "i3: timeout dengan detik" "$i3" "timeout 600"
    # Kutip itu wajib: tanpa kutip swayidle hanya mengambil "noctoprevi"
    # dan membuang "start"-nya.
    assert_contains "i3: perintah start diapit kutip" "$i3" '"noctoprevi start"'
    assert_contains "i3: perintah stop diapit kutip" "$i3" '"noctoprevi stop"'
    assert_contains "i3: ada direktif resume" "$i3" "resume"
    assert_not_contains "i3: tanpa exec_always" "$i3" "exec_always"
    assert_not_contains "i3: tanpa exec_on_idle" "$i3" "exec_on_idle"
    assert_not_contains "i3: tanpa tanda = di timeout" "$i3" "timeout ="

    # --- varian upstream: hanya keyword yang swayidle terima ---
    local directives="" line key
    while read -r line; do
        case "$line" in
            '#'* | '' | *'>>>'* | *'<<<'*) continue ;;
        esac
        directives="$directives$line"$'\n'
    done <<<"$upstream"
    # Keyword `timeout` di config berarti "timeout <detik> <perintah>",
    # bukan pengaturan idle - flag -t yang mengaturnya. Kalau ada di
    # config, swayidle keluar dengan "Too few parameters".
    assert_not_contains "upstream: tanpa keyword timeout" "$directives" "timeout"

    local -a valid=(exec exec_always exec_on_idle
        exec_idle_deadline exec_on_resume)
    local found v
    while read -r line; do
        [ -n "$line" ] || continue
        # `read` lebih aman daripada trim manual: "exec_always = x" punya
        # spasi sebelum tanda sama dengan.
        read -r key _rest <<<"$line"
        found=0
        for v in "${valid[@]}"; do
            [ "$key" = "$v" ] && found=1 && break
        done
        if [ "$found" -eq 1 ]; then
            assert_ok "upstream: keyword '$key' valid" true
        else
            assert_eq "upstream: keyword '$key' DITOLAK" "$key" "<salah satu: ${valid[*]}>"
        fi
    done <<<"$directives"
    assert_contains "upstream: exec_always untuk start" "$directives" "exec_always ="
    assert_not_contains "upstream: tanpa exec_while_idle" "$directives" "exec_while_idle"

    # Blok yang benar-benar terpasang harus ikut varian yang terdeteksi
    local real
    real="$(nc_unit "NC_IDLE_START_SEC=600; NC_IDLE_LOCK_SEC=1200" 'nc_swayidle_block')"
    if [ "$idetected" = "i3" ]; then
        assert_contains "blok terpasang ikut varian i3" "$real" "resume"
        assert_not_contains "blok terpasang bukan upstream" "$real" "exec_always"
    else
        assert_contains "blok terpasang ikut upstream" "$real" "exec_always ="
    fi
    t_end
}

t_mpv_releases_keyboard() {
    t_begin "mpv tidak memegang keyboard (syarat EXIT_ANIM jalan)"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 30 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
    runq start
    sleep 1.2
    assert_eq "mpv hidup" "$(mpv_count)" "1"

    local argv="" pid
    pid="$(cat "$XDG_RUNTIME_DIR/noctoprevi.0.pid" 2>/dev/null)"
    if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
        argv="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null)"
    fi
    if [ -z "$argv" ]; then
        t_skip "tidak bisa baca argv mpv (/proc tidak tersedia)"
        runq stop
        t_end
        return
    fi
    assert_contains "binding keyboard dimatikan" "$argv" "--input-default-bindings=no"
    assert_contains "keyboard VO dimatikan" "$argv" "--input-vo-keyboard=no"
    t_ok "tekan tombol akan lolos ke compositor -> swayidle -> stop"
    runq stop
    t_end
}

t_exit_anim_unknown_returns_ok() {
    t_begin "nc_ipc_slide mode tak dikenal = no-op, bukan error"
    local out
    out="$(nc_unit "SOCK='$SANDBOX/tidak-ada.sock'" '
        nc_ipc_slide "$SOCK" diagonal 100
        printf "rc=%s" "$?"
    ' 2>&1)"
    assert_contains "keluar dengan 0" "$out" "rc=0"
    t_end
}

t_signal_kills_children() {
    t_begin "SIGTERM ke supervisor bunuh anak mpv"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 120 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
    runq start
    sleep 0.6
    assert_eq "mpv hidup" "$(mpv_count)" "1"

    local sup
    sup="$(cat "$XDG_RUNTIME_DIR/noctoprevi.pid" 2>/dev/null)"
    kill -TERM "$sup" 2>/dev/null
    sleep 0.8

    assert_eq "tidak ada mpv yatim" "$(mpv_count)" "0"
    assert_no_file "pidfile dibersihkan" "$XDG_RUNTIME_DIR/noctoprevi.pid"
    t_end
}

t_start_reports_supervisor_failure() {
    t_begin "start melaporkan kegagalan supervisor"
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' 'LOG_TARGET=stderr'
    local out rc
    out="$(NOCTOPREVI_MPV="$SANDBOX/tidak-ada-mpv" run start)"
    rc="$?"
    assert_eq "exit 2" "$rc" "2"
    assert_contains "pesan jelas" "$out" "supervisor gagal start"
    assert_no_file "tidak ada pidfile tertinggal" "$XDG_RUNTIME_DIR/noctoprevi.pid"
    if flock -n "$XDG_RUNTIME_DIR/noctoprevi.lock" -c true 2>/dev/null; then
        t_ok "lock dilepas supaya start berikutnya bisa jalan"
    else
        t_no "lock dilepas" "masih terkunci setelah start gagal"
    fi
    t_end
}

t_stop_repeated() {
    t_begin "stop berulang & idempoten"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
    runq start
    sleep 0.5
    runq stop
    runq stop
    runq stop
    assert_eq "status tetap 1" "$(code status)" "1"
    assert_eq "tidak ada mpv yatim" "$(mpv_count)" "0"
    t_end
}

t_stop_orphan_recovery() {
    t_begin "pulih dari mpv yatim"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
    runq start
    sleep 0.5
    local sup mpvpid
    sup="$(cat "$XDG_RUNTIME_DIR/noctoprevi.pid" 2>/dev/null)"
    mpvpid="$(cat "$XDG_RUNTIME_DIR/noctoprevi.0.pid" 2>/dev/null)"
    kill -9 "$mpvpid" 2>/dev/null
    kill -9 "$sup" 2>/dev/null
    sleep 0.3
    runq stop
    runq start
    sleep 0.5
    assert_eq "start lagi berhasil" "$(code status)" "0"
    assert_eq "1 mpv saja" "$(mpv_count)" "1"
    t_end
}

t_stale_socket() {
    t_begin "socket basi & pidfile palsu"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'

    python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$XDG_RUNTIME_DIR/noctoprevi.sock')
s.close()
" 2>/dev/null
    printf '999999\n' >"$XDG_RUNTIME_DIR/noctoprevi.pid"

    runq start
    sleep 0.6
    assert_eq "start berhasil" "$(code status)" "0"
    t_end
}

t_ipc_dead_socket() {
    t_begin "IPC ke socket mati tidak bikin crash"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
    runq start
    sleep 0.5
    rm -f "$XDG_RUNTIME_DIR/noctoprevi.sock"
    local rc
    rc="$(code next)"
    assert_eq "next tetap error cleanly" "$rc" "2"
    assert_no_crash "tidak crash" "$(run next)"
    t_end
}

t_output_detection() {
    t_begin "deteksi output monitor"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/runtime.sh"
        nc_init_paths
        if nc_detect_outputs; then
            printf "ok:%s\n" "${NC_OUTPUTS[*]}"
        else
            printf "none\n"
        fi
    ')"
    case "$res" in
        ok:*) t_ok "output terdeteksi: ${res#ok:}" ;;
        none)
            if [ -n "${XDG_SESSION_TYPE:-}" ]; then
                t_no "output terdeteksi" "tidak ada output di ${XDG_SESSION_TYPE}"
            else
                t_skip "tidak dalam sesi Wayland"
            fi
            ;;
        *) t_no "deteksi output" "$res" ;;
    esac
    t_end
}

t_wlr_randr_parser() {
    t_begin "parser output wlr-randr (fallback)"
    if ! have wlr-randr; then
        t_skip "butuh wlr-randr"
        t_end
        return
    fi
    local saved="$XDG_RUNTIME_DIR"
    export XDG_RUNTIME_DIR="$REAL_RUNTIME_DIR"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/runtime.sh"
        nc_init_paths
        if nc_detect_outputs_wlr; then
            printf "ok:%s\n" "${NC_OUTPUTS[*]}"
        else
            printf "none\n"
        fi
    ')"
    export XDG_RUNTIME_DIR="$saved"
    if [ "$res" = "none" ]; then
        if [ -n "${XDG_SESSION_TYPE:-}" ]; then
            t_no "deteksi lewat wlr-randr" "tidak ada output aktif"
        else
            t_skip "tidak dalam sesi Wayland"
        fi
    else
        assert_contains "deteksi lewat wlr-randr" "$res" "ok:"
    fi
    t_end
}

t_installed_layout() {
    t_begin "layout terpasang (prefix/lib/noctoprevi)"
    local prefix="$SANDBOX/prefix"
    mkdir -p "$prefix/bin" "$prefix/lib/noctoprevi" "$prefix/share/noctoprevi"
    install -m 755 "$ROOT/bin/noctoprevi" "$prefix/bin/noctoprevi"
    local l
    for l in $NC_LIBS; do
        install -m 644 "$ROOT/lib/$l.sh" "$prefix/lib/noctoprevi/$l.sh"
    done
    install -m 644 "$ROOT/config/config.conf" "$prefix/share/noctoprevi/config.conf"

    local out rc
    out="$("$prefix/bin/noctoprevi" version 2>&1)"
    assert_contains "binary Prefix menemukan lib-nya" "$out" "$VSTR"
    out="$("$prefix/bin/noctoprevi" doctor 2>&1)"
    assert_not_contains "tidak ada pesan modul hilang" "$out" "modul tidak ditemukan"

    if have mpv && have socat; then
        make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
        nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
        "$prefix/bin/noctoprevi" start >/dev/null 2>&1
        sleep 0.5
        rc="$("$prefix/bin/noctoprevi" status >/dev/null 2>&1; printf '%s' "$?")"
        assert_eq "start dari layout Prefix jalan" "$rc" "0"
        "$prefix/bin/noctoprevi" next >/dev/null 2>&1
        assert_eq "next dari layout Prefix jalan" "$?" "0"
        "$prefix/bin/noctoprevi" stop >/dev/null 2>&1
        assert_eq "stop dari layout Prefix jalan" "$?" "0"
    else
        assert_ok "lewati siklus hidup (butuh mpv + socat)"
    fi
    t_end
}

t_symlink_invocation() {
    t_begin "dipanggil lewat symlink"
    local link="$SANDBOX/noctoprevi-link"
    ln -sf "$ROOT/bin/noctoprevi" "$link"
    local out
    out="$("$link" version 2>&1)"
    assert_contains "symlink tetap menemukan lib" "$out" "$VSTR"
    t_end
}

t_no_lib_error_message() {
    t_begin "pesan error jelas saat lib hilang"
    local lonely="$SANDBOX/lonely"
    mkdir -p "$lonely"
    install -m 755 "$ROOT/bin/noctoprevi" "$lonely/noctoprevi"
    local out rc
    out="$("$lonely/noctoprevi" version 2>&1)"
    rc="$?"
    assert_eq "exit 2" "$rc" "2"
    assert_contains "menyebut lokasi yang dicari" "$out" "modul tidak ditemukan"
    assert_contains "memberi saran perbaikan" "$out" "pasang ulang"
    t_end
}

t_aerials_root_fingerprint_logic() {
    t_begin "verifikasi sidik jari root CA (offline)"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/aerials.sh"
        nc_init_paths

        # sidik jari yang di-pin harus 64 hex
        if [[ "${NC_APPLE_ROOT_SHA256}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
            printf "pin-format:ok\n"
        else
            printf "pin-format:BAD(%s)\n" "$NC_APPLE_ROOT_SHA256"
        fi

        # DER acak -> PEM -> decode balik harus mengembalikan hash yang sama
        head -c 256 /dev/urandom > "$XDG_RUNTIME_DIR/fake.der"
        sha256sum "$XDG_RUNTIME_DIR/fake.der" | cut -d" " -f1 | tr a-f A-F > "$XDG_RUNTIME_DIR/want"
        if nc_der_to_pem "$XDG_RUNTIME_DIR/fake.der" "$XDG_RUNTIME_DIR/fake.pem"; then
            nc_pem_der_sha256 "$XDG_RUNTIME_DIR/fake.pem" > "$XDG_RUNTIME_DIR/got"
            if [ "$(cat "$XDG_RUNTIME_DIR/got")" = "$(cat "$XDG_RUNTIME_DIR/want")" ]; then
                printf "roundtrip:ok\n"
            else
                printf "roundtrip:BAD(want=%s got=%s)\n" \
                    "$(cat "$XDG_RUNTIME_DIR/want")" "$(cat "$XDG_RUNTIME_DIR/got")"
            fi
        else
            printf "roundtrip:BAD(der_to_pem gagal)\n"
        fi

        # PEM rusak harus ditolak, bukan diterima diam-diam
        printf "BUKAN SERTIFIKAT\n" > "$XDG_RUNTIME_DIR/junk.pem"
        if nc_pem_der_sha256 "$XDG_RUNTIME_DIR/junk.pem" >/dev/null 2>&1; then
            printf "junk:TERIMA\n"
        else
            printf "junk:ditolak\n"
        fi

        # klasifikasi pesan TLS
        for m in "curl: (60) SSL certificate problem: unable to get local issuer certificate" \
                 "curl: (77) CA cert problem, unable to get local issuer certificate" \
                 "curl: (51) self signed certificate in certificate chain"; do
            if nc_is_tls_error "$m"; then printf "tls:ok\n"; else printf "tls:BAD(%s)\n" "$m"; fi
        done
        for m in "curl: (7) Failed to connect" "HTTP 403 forbidden" ""; do
            if nc_is_tls_error "$m"; then printf "tlsfalse:BAD(%s)\n" "$m"; else printf "tlsfalse:ok\n"; fi
        done
    ')"
    assert_contains "pin fingerprint 64 hex" "$res" "pin-format:ok"
    assert_contains "DER->PEM->DER bulat" "$res" "roundtrip:ok"
    assert_contains "PEM rusak ditolak" "$res" "junk:ditolak"
    local tls_ok
    tls_ok="$(printf '%s' "$res" | grep -c '^tls:ok$')"
    assert_eq "3 pesan TLS dikenali" "$tls_ok" "3"
    local tls_false
    tls_false="$(printf '%s' "$res" | grep -c '^tlsfalse:ok$')"
    assert_eq "3 pesan non-TLS ditolak" "$tls_false" "3"
    t_end
}

t_aerials_trust_config() {
    t_begin "AERIALS_TRUST divalidasi"
    nc_write_config 'AERIALS_TRUST=entah'
    assert_contains "nilai ngawur jatuh ke auto" "$(run doctor)" "auto"

    nc_write_config 'AERIALS_TRUST=SYSTEM'
    assert_contains "huruf besar dinormalkan ke lowercase" "$(run doctor)" "AERIALS_TRUST    system"
    t_end
}

t_aerials_trust_system_no_bootstrap() {
    t_begin "AERIALS_TRUST=system tidak pernah bootstrap root"
    local state="$XDG_STATE_HOME/noctoprevi"
    mkdir -p "$state" 2>/dev/null
    rm -f "$state/apple-root.pem" 2>/dev/null
    nc_write_config 'AERIALS_TRUST=system' "VIDEO_DIR=$VIDEOS"
    timeout 60 "$NOCTOPREVI" aerials list >/dev/null 2>&1
    assert_no_file "root CA tidak dibuat" "$state/apple-root.pem"
    t_end
}

t_aerials_tampered_fingerprint_rejected() {
    t_begin "sidik jari dibohongi -> root ditolak"
    command -v curl >/dev/null 2>&1 || { t_skip "butuh curl"; t_end; return; }
    if ! timeout 25 curl -fsSL -o /dev/null https://www.apple.com 2>/dev/null; then
        t_skip "tidak ada jaringan"
        t_end
        return
    fi
    local badlib="$SANDBOX/badlib"
    mkdir -p "$badlib"
    cp "$ROOT"/lib/*.sh "$badlib/"
    sed -i 's/^NC_APPLE_ROOT_SHA256=.*/NC_APPLE_ROOT_SHA256="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"/' \
        "$badlib/aerials.sh"

    local res
    BAD_LIBS_SRC="$NC_LIBS"
    res="$(BADLIB="$badlib" BADSRC="$BAD_LIBS_SRC" bash -c '
        set -uo pipefail
        for m in $BADSRC; do . "$BADLIB/$m.sh"; done
        nc_init_paths; nc_config_defaults
        NC_LOG_TARGET=none; NC_LOG_LEVEL=off
        nc_aerials_curl_args
        if nc_aerials_ensure_apple_root >/dev/null 2>&1; then
            printf "DITERIMA"
        else
            printf "DITOLAK"
        fi
    ' 2>&1)"
    assert_contains "root ditolak" "$res" "DITOLAK"
    t_end
}

t_idle_defaults_consistent() {
    t_begin "default idle konsisten di semua berkas"
    local start lock
    start="$(sed -n 's/^ *NC_IDLE_START_SEC=\([0-9]*\).*/\1/p' "$ROOT/lib/config.sh" | head -1)"
    lock="$(sed -n 's/^ *NC_IDLE_LOCK_SEC=\([0-9]*\).*/\1/p' "$ROOT/lib/config.sh" | head -1)"
    if [ -n "$start" ] && [ -n "$lock" ]; then
        t_ok "default di lib/config.sh: start=$start lock=$lock"
    else
        t_no "default terbaca" "start='$start' lock='$lock'"
        t_end
        return
    fi

    # nilai yang didokumentasikan di berkas lain harus sama, kalau tidak user yang
    # menyalin manual akan dapat perilaku berbeda dari `install`
    local f
    for f in config/config.conf config/hypridle.conf.example config/swayidle.config.example; do
        case "$f" in
            config/config.conf)
                assert_contains "$f IDLE_START_SEC" "$(cat "$ROOT/$f")" "IDLE_START_SEC=$start"
                assert_contains "$f IDLE_LOCK_SEC" "$(cat "$ROOT/$f")" "IDLE_LOCK_SEC=$lock"
                ;;
            *hypridle*)
                assert_contains "$f timeout start" "$(cat "$ROOT/$f")" "timeout = $start"
                assert_contains "$f timeout lock" "$(cat "$ROOT/$f")" "timeout = $lock"
                ;;
            *swayidle*)
                assert_contains "$f sleep lock" "$(cat "$ROOT/$f")" "sleep $lock;"
                ;;
        esac
    done
    t_end
}

t_idle_generated_matches_config() {
    t_begin "blok yang ditulis install ikut config"
    local start lock out
    start="$(sed -n 's/^ *NC_IDLE_START_SEC=\([0-9]*\).*/\1/p' "$ROOT/lib/config.sh" | head -1)"
    lock="$(sed -n 's/^ *NC_IDLE_LOCK_SEC=\([0-9]*\).*/\1/p' "$ROOT/lib/config.sh" | head -1)"

    nc_write_config "IDLE_START_SEC=$(( start + 111 ))" "IDLE_LOCK_SEC=$(( lock + 222 ))"
    runq install --idle-daemon hypridle
    out="$(cat "$XDG_CONFIG_HOME/hypr/hypridle.conf" 2>/dev/null)"
    assert_contains "timeout start ikut custom" "$out" "timeout = $(( start + 111 ))"
    assert_contains "timeout lock ikut custom" "$out" "timeout = $(( lock + 222 ))"

    runq install --idle-daemon swayidle
    out="$(cat "$XDG_CONFIG_HOME/swayidle/config" 2>/dev/null)"
    # Varian swayidle punya format config yang tidak kompatibel, jadi
    # nilai yang bisa carried berbeda. Yang wajib ikut custom adalah
    # timeout idle; lock 1200-detik hanya bisa dinyatakan di varian
    # upstream (format i3 cuma punya satu perintah timeout).
    local variant
    variant="$(nc_unit "" 'nc_swayidle_variant' 2>/dev/null)"
    if [ "$variant" = "i3" ]; then
        assert_contains "swayidle timeout ikut custom (i3)" "$out" "timeout $(( start + 111 ))"
    else
        assert_contains "swayidle sleep ikut custom" "$out" "sleep $(( lock + 222 ));"
    fi
    t_end
}

t_doctor_shows_idle() {
    t_begin "doctor menampilkan nilai idle"
    nc_write_config 'IDLE_START_SEC=777' 'IDLE_LOCK_SEC=888'
    local out
    out="$(run doctor)"
    assert_contains "screensaver" "$out" "777s"
    assert_contains "lockscreen" "$out" "888s"
    assert_contains "petunjuk pasang idle" "$out" "install --idle-daemon"
    t_end
}

t_log_target_daemon() {
    t_begin "LOG_TARGET=daemon memilih target yang benar"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        nc_init_paths

        # disimulasikan: bukan TTY + tidak ada journal socket -> file
        NC_LOG_TARGET=daemon
        NC_LOG_FILE="$XDG_STATE_HOME/noctoprevi/t1.log"
        NC_LOG_MAX_LINES=0
        (
            [ -t 2 ] && exit 0
            [ -S /run/systemd/journal/socket ] && exit 0
            exit 1
        ) && printf "tty-or-journal\n" || printf "file\n"
    ')"
    # hasil bergantung mesin; yang penting daemon tidak pernah memilih
    # "stderr" ketika stderr bukan TTY
    assert_ne "tidak memilih stderr di non-TTY" "$res" "" 
    t_end
}

t_log_no_stdout_stderr_leak() {
    t_begin "supervisor tidak menahan pipe parent"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 60 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' 'LOG_LEVEL=debug'

    local -i t0 t1 ms
    t0="${EPOCHREALTIME/./}"
    timeout 25 bash -c "'$NOCTOPREVI' start 2>&1 | tail -1" >/dev/null 2>&1
    t1="${EPOCHREALTIME/./}"
    ms=$(( (t1 - t0) / 1000 ))
    assert_le "start lewat pipe tidak menggantung (<10s)" "$ms" "10000"
    assert_eq "screensaver tetap hidup" "$(code status)" "0"
    t_end
}

t_no_pipe_hang_even_when_stderr_forced() {
    t_begin "tidak menggantung walau LOG_TARGET=stderr dipaksa"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 60 || { t_skip "butuh ffmpeg"; t_end; return; }
    # LOG_TARGET=stderr adalah permintaan eksplisit, jadi harus tetap
    # Yang diuji di sini: supervisor tidak boleh mewarisi pipe,
    # karena parent yang membaca pipe akan menunggu EOF selamanya.
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' \
        'LOG_TARGET=stderr' 'LOG_LEVEL=info'

    local -i t0 t1 ms
    t0="${EPOCHREALTIME/./}"
    timeout 20 bash -c "'$NOCTOPREVI' start 2>&1 | tail -1" >/dev/null 2>&1
    t1="${EPOCHREALTIME/./}"
    ms=$(( (t1 - t0) / 1000 ))
    assert_le "start | tail selesai (<12s)" "$ms" "12000"
    assert_eq "screensaver tetap hidup" "$(code status)" "0"
    t_end
}

t_interactive_keeps_logs() {
    t_begin "log tetap terlihat di terminal interaktif"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 60 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' \
        'LOG_TARGET=stderr' 'LOG_LEVEL=info'

    local out
    if ! have script; then
        t_skip "butuh util-linux script untuk simulasi tty"
        t_end
        return
    fi
    out="$(timeout 40 script -qec \
        "'$NOCTOPREVI' start; sleep 0.4; '$NOCTOPREVI' stop" /dev/null 2>&1)"
    assert_contains "start melapor ke terminal" "$out" "screensaver aktif"
    t_end
}

t_log_rotation() {
    t_begin "rotasi log (LOG_MAX_LINES)"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 60 || { t_skip "butuh ffmpeg"; t_end; return; }
    local logdir="$XDG_STATE_HOME/noctoprevi"
    mkdir -p "$logdir" 2>/dev/null
    local log="$logdir/rot.log"
    rm -f "$log" "$log.1"
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' \
        'LOG_TARGET=file' "LOG_FILE=$log" 'LOG_MAX_LINES=5' 'LOG_LEVEL=debug'

    # rotasi dicek di `start`, bukan di tiap perintah: status dipanggil
    # idle daemon dan kita tidak mau menambah fork di sana.
    local -i i
    for i in 1 2 3 4 5 6 7 8; do
        "$NOCTOPREVI" start >/dev/null 2>&1
        sleep 0.15
        "$NOCTOPREVI" stop >/dev/null 2>&1
    done
    assert_file "log utama ada" "$log"
    if [ -f "$log.1" ]; then
        t_ok "rotasi membuat $log.1"
        local -i old
        old="$(wc -l <"$log.1" 2>/dev/null)" || old=0
        if [ "${old:-0}" -gt 5 ]; then
            t_ok "isi .1 melewati batas (${old} baris)"
        else
            t_no "isi .1 melewati batas" "cuma ${old:-0} baris"
        fi
    else
        t_no "rotasi membuat .1" "belum ada setelah 8x start/stop dengan max 5 baris"
    fi
    t_end
}

t_log_rotation_disabled() {
    t_begin "rotasi mati bila LOG_MAX_LINES=0"
    local logdir="$XDG_STATE_HOME/noctoprevi"
    mkdir -p "$logdir" 2>/dev/null
    local log="$logdir/norot.log"
    rm -f "$log" "$log.1"
    nc_write_config 'LOG_TARGET=file' "LOG_FILE=$log" 'LOG_MAX_LINES=0' \
        'LOG_LEVEL=debug' "VIDEO_DIR=$VIDEOS"
    local -i i
    for i in $(seq 1 10); do
        "$NOCTOPREVI" doctor >/dev/null 2>&1
    done
    assert_no_file "tidak ada .1" "$log.1"
    local -i lines
    lines="$(wc -l <"$log" 2>/dev/null)" || lines=0
    if [ "${lines:-0}" -gt 5 ]; then
        t_ok "log tumbuh terus tanpa diputar (${lines} baris)"
    else
        t_no "log tumbuh" "hanya ${lines:-0} baris"
    fi
    t_end
}

t_validate_media_levels() {
    t_begin "VALIDATE_MEDIA tiga tingkat"
    have ffprobe || { t_skip "butuh ffprobe"; t_end; return; }
    have ffmpeg || { t_skip "butuh ffmpeg"; t_end; return; }

    make_clip "$VIDEOS/ok.mp4" 5 || { t_skip "butuh ffmpeg"; t_end; return; }
    cp "$VIDEOS/ok.mp4" "$VIDEOS/corrupt.mp4"
    cp "$VIDEOS/ok.mp4" "$VIDEOS/truncated.mp4"
    printf 'sampah' >"$VIDEOS/garbage.mp4"

    # Fixture harus presisi: file yang dipotong/corrupt tapi metadatanya utuh
    # persis kasus yang lolos ffprobe. Jadi kita sisipkan top-level box MP4
    # dan rusak / potong payload mdat, bukan asal potong byte.
    python3 - "$VIDEOS" <<'PYFIX' 2>/dev/null
import struct, sys, os
d = sys.argv[1]
src = os.path.join(d, "ok.mp4")
data = bytearray(open(src, "rb").read())
off, mdat = 0, None
while off + 8 <= len(data):
    size = struct.unpack(">I", data[off:off+4])[0]
    typ = data[off+4:off+8].decode("latin1", "replace")
    if size == 1:
        size = struct.unpack(">Q", data[off+8:off+16])[0]
    if size == 0:
        size = len(data) - off
    if typ == "mdat":
        mdat = (off, size)
        break
    if size <= 0:
        break
    off += size
if mdat is None:
    sys.exit(1)
start = mdat[0] + 8
body = mdat[1] - 8
open(os.path.join(d, "corrupt.mp4"), "wb").write(
    bytes(data[:start] + bytearray(b"\xff" * 24000) + data[start + 24000:]))
open(os.path.join(d, "truncated.mp4"), "wb").write(
    bytes(data[:start + int(body * 0.9)]))
PYFIX
    [ -s "$VIDEOS/corrupt.mp4" ] || t_skip "fixture python gagal"

    local out
    out="$(nc_unit "NC_VIDEO_DIR='$VIDEOS'" '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/media.sh"
        nc_init_paths; nc_config_defaults; NC_LOG_TARGET=none
        NC_MIN_DURATION_SEC=1
        for lvl in 0 1 2; do
            NC_VALIDATE_MEDIA=$lvl
            for f in ok corrupt truncated garbage; do
                if nc_media_probe "$NC_VIDEO_DIR/$f.mp4"; then r=lolos; else r=tolak; fi
                printf "L%s/%s=%s\n" "$lvl" "$f" "$r"
            done
        done
    ')"

    # tingkat 0: percaya semua
    assert_contains "L0 tidak memeriksa apa pun (garbage)" "$out" "L0/garbage=lolos"
    # tingkat 1: tolak yang tidak punya video / terlalu pendek
    assert_contains "L1 tolak garbage" "$out" "L1/garbage=tolak"
    assert_contains "L1 terima file baik" "$out" "L1/ok=lolos"
    # File dengan moov di depan: metadata utuh walau payload rusak atau
    # terpotong, jadi ffprobe tidak melihat apa-apa. Inilah alasan tingkat 2 ada.
    assert_contains "L1 LOLOS file korup (ffprobe buta)" "$out" "L1/corrupt=lolos"
    assert_contains "L1 LOLOS file terpotong" "$out" "L1/truncated=lolos"
    assert_contains "L2 TOLAK file korup" "$out" "L2/corrupt=tolak"
    assert_contains "L2 TOLAK file terpotong" "$out" "L2/truncated=tolak"
    assert_contains "L2 terima file baik" "$out" "L2/ok=lolos"
    t_end
}

t_validate_media_config() {
    t_begin "VALIDATE_MEDIA & MIN_DURATION_SEC divalidasi"
    # doctor memformat dengan %-16s jadi jumlah spasi bisa bergeser kalau
    # nama key berubah. Assert ke bentuk yang sudah dirapikan.
    local out
    out="$(run doctor | tr -s ' ')"

    nc_write_config 'VALIDATE_MEDIA=2' 'MIN_DURATION_SEC=5'
    out="$(run doctor | tr -s ' ')"
    assert_contains "level 2 + ambang 5s terbaca" "$out" "VALIDATE_MEDIA 2 (5s min)"

    nc_write_config 'VALIDATE_MEDIA=9'
    out="$(run doctor | tr -s ' ')"
    assert_contains "level ngawur jatuh ke 1" "$out" "VALIDATE_MEDIA 1 (1s min)"

    nc_write_config 'VALIDATE_MEDIA=yes'
    out="$(run doctor | tr -s ' ')"
    assert_contains "boolean ya = level 1" "$out" "VALIDATE_MEDIA 1 (1s min)"

    nc_write_config 'VALIDATE_MEDIA=0'
    out="$(run doctor | tr -s ' ')"
    assert_contains "level 0 disables check" "$out" "VALIDATE_MEDIA 0 (1s min)"
    t_end
}

t_fps_limit() {
    t_begin "VIDEO_FPS_LIMIT"
    nc_write_config 'VIDEO_FPS_LIMIT=30'
    assert_contains "30 diterima" "$(run doctor | tr -s ' ')" "VIDEO_FPS_LIMIT 30 fps"

    nc_write_config 'VIDEO_FPS_LIMIT=0'
    assert_contains "0 = mati" "$(run doctor | tr -s ' ')" "VIDEO_FPS_LIMIT mati (semua frame)"

    # pesan penolakannya diuji terpisah di t_config_warnings_reach_destination,
    # karena di sini LOG_TARGET memakai default `daemon` (ke journal).
    nc_write_config 'VIDEO_FPS_LIMIT=37'
    assert_contains "jatuh ke 0" "$(run doctor | tr -s ' ')" "VIDEO_FPS_LIMIT mati"
    t_end
}

t_fps_limit_applied_to_mpv() {
    t_begin "VIDEO_FPS_LIMIT masuk ke argumen mpv"
    local out
    out="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/runtime.sh"
        nc_init_paths; nc_config_defaults; NC_LOG_TARGET=none

        NC_VIDEO_FPS_LIMIT=0
        nc_build_mpv_argv 0 /tmp/x.mp4
        printf "off:%s\n" "${NC_ARGV[*]}"

        NC_VIDEO_FPS_LIMIT=30
        nc_build_mpv_argv 0 /tmp/x.mp4
        printf "on:%s\n" "${NC_ARGV[*]}"
    ')"
    assert_not_contains "0 tidak menambah opsi fps" "$(printf '%s' "$out" | grep '^off:')" "video-sync"
    assert_contains "30 menambah display-vdrop" "$(printf '%s' "$out" | grep '^on:')" "video-sync=display-vdrop"
    assert_contains "30 menambah untimed" "$(printf '%s' "$out" | grep '^on:')" "--untimed"
    t_end
}

t_config_warnings_reach_destination() {
    t_begin "peringatan config sampai ke LOG_TARGET yang diminta"
    nc_write_config 'BOGUS_KEY=1' 'LOG_TARGET=stderr' 'VIDEO_FPS_LIMIT=37'
    local out
    out="$("$NOCTOPREVI" status 2>&1)"
    assert_contains "key asing terlihat di stderr" "$out" "key tidak dikenal"
    assert_contains "nilai ngawur terlihat di stderr" "$out" "VIDEO_FPS_LIMIT tidak dikenal"
    t_end
}

t_lock_released_between_cycles() {
    t_begin "lock dilepas supaya start lagi dalam satu proses jalan"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 60 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' 'LOG_LEVEL=error'

    # Jalankan start/stop berulang di SATU proses. Kalau fd lock tidak
    # dilepas setelah stop, iterasi kedua dan seterusnya mengira instance
    # lain masih jalan lalu diam-diam tidak melakukan apa-apa - dan bench /
    # escalation sweep melaporkan angka yang tidak berarti.
    local out
    out="$(
        NC_SELF="$ROOT/bin/noctoprevi" "$ROOT/tests/_startstop-loop.sh" 2>&1
    )"
    local live_count
    live_count="$(printf '%s' "$out" | grep -c 'supervisor=hidup')"
    if [ "$live_count" -ge 3 ]; then
        t_ok "3 dari 3 siklus punya supervisor hidup"
    else
        t_no "3 dari 3 siklus punya supervisor hidup" "hanya $live_count yang hidup"
    fi
    assert_no_crash "tanpa error" "$out"
    t_end
}

t_bench_starts_every_cycle() {
    t_begin "bench benar-benar menjalankan tiap siklus"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 60 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' 'LOG_LEVEL=error'

    local out
    out="$(timeout 120 "$NOCTOPREVI" bench --escalation-sweep --runs 2 2>&1)"
    local line
    line="$(printf '%s' "$out" | grep -m1 'supervisor hidup')"
    assert_contains "sweep melaporkan jumlah supervisor hidup" "$line" "supervisor hidup"
    if printf '%s' "$line" | grep -qE 'hidup [0-9]+/2' &&
        ! printf '%s' "$line" | grep -q 'hidup 0/2'; then
        t_ok "sweep menjalankan start di tiap siklus"
    else
        t_no "sweep menjalankan start di tiap siklus" "$line"
    fi
    assert_contains "laporan sweep terformat" "$out" "STOP_IPC_WAIT_MS"
    t_end
}

t_anomaly_ndjson_valid() {
    t_begin "anomali menghasilkan NDJSON yang valid"
    local out
    out="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/anomaly.sh"
        nc_init_paths; nc_config_defaults
        NC_LOG_TARGET=none; NC_LOG_LEVEL=off
        NC_ANOMALY_NOTIFY=0
        nc_anomaly_clear
        nc_anomaly_emit "$NC_SEV_WARN" "STOP_SLOW" "pesan biasa" "" "ms=10"
        nc_anomaly_emit "$NC_SEV_ERROR" "MPV_GAVE_UP" "butuh tanda \\"kutip\\" dan \\\\ backslash" "hint"
        nc_anomaly_emit "$NC_SEV_INFO" "MEDIA_RETRY" "tanpa ctx" ""
        cat "$(nc_anomaly_file)"
    ')"
    local -i bad=0
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if have jq; then
            printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$(( bad + 1 ))
        fi
    done <<<"$out"
    assert_eq "semua baris JSON valid" "$bad" "0"
    local n
    n="$(printf '%s' "$out" | grep -c . || true)"
    assert_eq "3 baris tercatat" "$n" "3"
    t_end
}

t_anomaly_escaping_roundtrip() {
    t_begin "escaping pesan kembali utuh"
    local out msg
    msg='ini "kutip" dan \ backslash dan {kurung}'
    out="$(nc_unit 'NC_VERSION=t' "
        . \"\$NCU_ROOT/lib/core.sh\"; . \"\$NCU_ROOT/lib/log.sh\"
        . \"\$NCU_ROOT/lib/config.sh\"; . \"\$NCU_ROOT/lib/anomaly.sh\"
        nc_init_paths; nc_config_defaults
        NC_LOG_TARGET=none; NC_LOG_LEVEL=off; NC_ANOMALY_NOTIFY=0
        nc_anomaly_clear
        nc_anomaly_emit error TESTCODE '${msg//\'/\\\'}' 'hint'
        tail -1 \"\$(nc_anomaly_file)\"
    ")"
    if have jq; then
        local got
        got="$(printf '%s' "$out" | jq -r '.msg' 2>/dev/null)"
        assert_eq "pesan kembali sama persis" "$got" "$msg"
    else
        t_skip "butuh jq untuk verifikasi escaping"
    fi
    t_end
}

t_anomaly_field_extraction() {
    t_begin "ekstraksi field dari NDJSON"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/anomaly.sh"
        nc_init_paths; nc_config_defaults
        NC_LOG_TARGET=none; NC_LOG_LEVEL=off; NC_ANOMALY_NOTIFY=0
        nc_anomaly_clear
        nc_anomaly_emit info A_ONE "pesan" "hint" "k=1"
        nc_anomaly_emit warn B_TWO "pesan" "" "k=2"
        nc_anomaly_emit error C_THREE "pesan" ""
        f="$(nc_anomaly_file)"
        for l in $(sed -n "1p" "$f"); do
            printf "sev=%s code=%s msg=%s\n" \
                "$(nc_anomaly_field "$l" sev)" \
                "$(nc_anomaly_field "$l" code)" \
                "$(nc_anomaly_field "$l" msg)"
        done
        printf "select-semua=%s\n" "$(nc_anomaly_select "$f" | grep -c .)"
        printf "select-warn=%s\n" "$(nc_anomaly_select "$f" --sev warn | grep -c .)"
        printf "select-kode=%s\n" "$(nc_anomaly_select "$f" --code C_THREE | grep -c .)"
        printf "select-sejak-nanti=%s\n" "$(nc_anomaly_select "$f" --since "$(( EPOCHSECONDS + 3600 ))" | grep -c .)"
        printf "total=%s\n" "$(nc_anomaly_total)"
    ')"
    assert_contains "field pertama benar" "$res" "sev=info code=A_ONE msg=pesan"
    assert_contains "select semua" "$res" "select-semua=3"
    assert_contains "filter severity" "$res" "select-warn=1"
    assert_contains "filter kode" "$res" "select-kode=1"
    assert_contains "filter since ke depan = 0" "$res" "select-sejak-nanti=0"
    assert_contains "total benar" "$res" "total=3"
    t_end
}

t_anomaly_health_and_counts() {
    t_begin "health score & counts"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/anomaly.sh"
        nc_init_paths; nc_config_defaults
        NC_LOG_TARGET=none; NC_LOG_LEVEL=off; NC_ANOMALY_NOTIFY=0
        nc_anomaly_clear
        printf "kosong=%s\n" "$(nc_anomaly_health)"
        nc_anomaly_emit info X1 "a" ""
        nc_anomaly_emit info X1 "a" ""
        nc_anomaly_emit warn X2 "a" ""
        nc_anomaly_emit error X3 "a" ""
        nc_anomaly_emit security X4 "a" ""
        printf "sebella=%s\n" "$(nc_anomaly_health)"
        printf "summary=%s\n" "$(nc_anomaly_summary | tr -s " " | tr "\n" "|")"
    ')"
    # Bobot: security 40, error 10, warn 3, info 0.
    # Di bawah: 2x info (0) + 1x warn (3) + 1x error (10) + 1x security (40) = 53
    assert_contains "health 100 saat kosong" "$res" "kosong=100"
    assert_contains "health = 100 - bobot (2 info + warn + error + security = 53)" \
        "$res" "sebella=47"
    assert_contains "summary menghitung per kode" "$res" "X1"
    t_end
}

t_anomaly_rotation() {
    t_begin "rotasi anomali (ANOMALY_MAX_LINES)"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/anomaly.sh"
        nc_init_paths; nc_config_defaults
        NC_LOG_TARGET=none; NC_LOG_LEVEL=off; NC_ANOMALY_NOTIFY=0
        NC_ANOMALY_MAX_LINES=20
        nc_anomaly_clear
        for i in $(seq 1 60); do
            nc_anomaly_emit info ROT "baris $i" ""
        done
        printf "total=%s\n" "$(nc_anomaly_total)"
        # semua baris yang tersisa harus valid NDJSON
        bad=0
        while IFS= read -r l; do
            printf "%s" "$l" | jq -e . >/dev/null 2>&1 || bad=$((bad+1))
        done < "$(nc_anomaly_file)"
        printf "corrupt=%s\n" "$bad"
        printf "pertama=%s\n" "$(head -1 "$(nc_anomaly_file)" | jq -r .msg)"
    ')"
    assert_contains "jumlah dipangkas" "$res" "total=1"
    assert_contains "tidak ada baris korup setelah rotasi" "$res" "corrupt=0"
    t_end
}

t_anomaly_codes_documented() {
    t_begin "setiap kode punya hint"
    local res
    res="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/anomaly.sh"
        nc_init_paths; nc_config_defaults
        NC_LOG_TARGET=none; NC_LOG_LEVEL=off
        for c in $NC_ANOMALY_CODES; do
            if nc_anomaly_known_code "$c" && [ -n "$(nc_anomaly_hint_for_code "$c")" ]; then
                printf "ok:%s\n" "$c"
            else
                printf "hilang:%s\n" "$c"
            fi
        done
    ')"
    local n_all n_ok
    n_all="$(printf '%s' "$res" | grep -c '^ok:')"
    n_ok="$(printf '%s' "$res" | grep -c '^ok:')"
    if [ "$n_all" -ge 15 ]; then
        t_ok "$n_all kode punya hint"
    else
        t_no "semua kode punya hint" "hanya $n_all"
    fi
    if printf '%s' "$res" | grep -q '^hilang:'; then
        t_no "tidak ada kode tanpa hint" "$(printf '%s' "$res" | grep '^hilang:' | tr '\n' ' ')"
    else
        t_ok "tidak ada kode tanpa hint"
    fi
    t_end
}

t_anomaly_cmd_output() {
    t_begin "perintah anomalies"
    local out
    # seeded
    mkdir -p "$XDG_STATE_HOME/noctoprevi"
    printf '%s\n' \
        "{\"ts\":$(date +%s),\"sev\":\"warn\",\"code\":\"STOP_ESCALATED\",\"msg\":\"perlahan\",\"hint\":\"ukur\"}" \
        "{\"ts\":$(date +%s),\"sev\":\"error\",\"code\":\"MPV_GAVE_UP\",\"msg\":\"batal\",\"hint\":\"check\"}" \
        >"$XDG_STATE_HOME/noctoprevi/anomalies.ndjson"

    out="$(run anomalies --limit 5)"
    assert_contains "menampilkan kode" "$out" "STOP_ESCALATED"
    assert_contains "menampilkan hint" "$out" "ukur"
    assert_contains "menampilkan error" "$out" "MPV_GAVE_UP"
    assert_contains "menampilkan health" "$out" "health"

    out="$(run anomalies --counts)"
    assert_contains "counts menghitung" "$out" "STOP_ESCALATED"

    out="$(run anomalies --sev error --limit 5)"
    assert_contains "filter severity menyaring" "$out" "MPV_GAVE_UP"
    assert_not_contains "tidak membocorkan warn" "$out" "STOP_ESCALATED"

    # --limit mengambil N yang TERAKHIR, jadi limit 1 = catatan terbaru
    out="$(run anomalies --json --limit 1)"
    if have jq; then
        assert_contains "--limit mengambil yang terbaru" \
            "$(printf '%s' "$out" | jq -r '.code' 2>/dev/null)" "MPV_GAVE_UP"
        out="$(run anomalies --json --limit 5)"
        assert_eq "tidak ada json korup" \
            "$(printf '%s' "$out" | jq -s 'length' 2>/dev/null)" "2"
    else
        t_skip "butuh jq"
    fi

    out="$(run anomalies --codes)"
    assert_contains "daftar kode" "$out" "CA_FINGERPRINT_MISMATCH"

    out="$(run anomalies --health)"
    # assert_contains adalah pola glob, bukan regex, jadi cek bentuknya
    # dengan case di sini.
    local hs
    hs="$(printf '%s' "$out" | tr -d '[:space:]')"
    case "$hs" in
        '' | *[!0-9]*) t_no "health hanya angka" "keluaran: '$out'" ;;
        *) t_ok "health hanya angka ($hs)" ;;
    esac

    out="$(run anomalies --clear)"
    assert_no_crash "clear tidak error" "$out"
    runq anomalies
    assert_contains "setelah clear kosong" "$(run anomalies)" "Tidak ada anomali"
    t_end
}

t_anomaly_emitted_on_real_run() {
    t_begin "anomali terekam dari siklus nyata"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 60 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0' 'LOG_LEVEL=error'

    local -i i
    for i in 1 2 3; do
        "$NOCTOPREVI" start >/dev/null 2>&1
        sleep 0.25
        "$NOCTOPREVI" stop >/dev/null 2>&1
    done

    local file="$XDG_STATE_HOME/noctoprevi/anomalies.ndjson"
    assert_file "berkas anomali dibuat" "$file"
    local n
    n="$(wc -l <"$file" 2>/dev/null)" || n=0
    if [ "${n:-0}" -gt 0 ]; then
        t_ok "$n anomali terekam dari 3 siklus"
    else
        t_no "anomali terekam" "nol baris"
    fi
    local bad
    bad=0
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$(( bad + 1 ))
    done <"$file"
    assert_eq "semua baris NDJSON valid" "$bad" "0"
    t_end
}

t_tui_requires_tty() {
    t_begin "tui & watch menolak non-TTY"
    assert_eq "tui tanpa tty exit 3" "$(code tui)" "3"
    assert_eq "watch tanpa tty exit 3" "$(code watch)" "3"
    t_end
}

t_tui_renders_in_pty() {
    t_begin "TUI merender di pty sungguhan"
    have script || { t_skip "butuh util-linux script"; t_end; return; }
    local out
    out="$(timeout 30 script -qec "$NOCTOPREVI tui < /dev/null" /dev/null 2>&1)"
    assert_contains "banner ASCII" "$out" "___"
    assert_contains "judul" "$out" "Video screensaver"
    assert_contains "kartu status" "$out" "screensaver"
    assert_contains "menu aksi" "$out" "Actions:"
    assert_contains "kartu library" "$out" "library"
    assert_no_crash "tidak ada error bash" "$out"
    t_end
}

t_bare_invocation_opens_tui() {
    t_begin "tanpa argumen membuka TUI di terminal"
    have script || { t_skip "butuh util-linux script"; t_end; return; }
    local out
    out="$(timeout 30 script -qec "$NOCTOPREVI < /dev/null" /dev/null 2>&1)"
    assert_contains "TUI terbuka" "$out" "Actions:"
    # tanpa pty harus tampil bantuan, bukan menggambar
    local out2
    out2="$(run 2>&1)"
    assert_contains "tanpa TTY tampil bantuan" "$out2" "PEMAKAIAN"
    t_end
}

t_check_command() {
    t_begin "perintah check (preflight)"
    local out rc
    out="$(run check 2>&1)"
    rc="$?"
    assert_contains "memeriksa ambang idle" "$out" "Idle thresholds"
    assert_contains "memeriksa output" "$out" "Output monitor"
    assert_contains "memeriksa media" "$out" "Media"
    assert_contains "memeriksa runtime" "$out" "Runtime"
    assert_no_crash "tidak crash" "$out"
    # tanpa media, check harus gagal
    assert_eq "exit 2 tanpa media" "$rc" "2"

    make_clip "$VIDEOS/a.mp4" 3 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'IDLE_START_SEC=30' 'VALIDATE_MEDIA=0'
    out="$(run check 2>&1)"
    assert_contains "IDLE_TOO_SHORT terdeteksi" "$out" "terlalu pendek"
    local f="$XDG_STATE_HOME/noctoprevi/anomalies.ndjson"
    if [ -f "$f" ] && grep -q IDLE_TOO_SHORT "$f" 2>/dev/null; then
        t_ok "mencatat IDLE_TOO_SHORT sebagai anomali"
    else
        t_no "mencatat IDLE_TOO_SHORT" "tidak ada di $f"
    fi

    nc_write_config "VIDEO_DIR=$VIDEOS" 'IDLE_START_SEC=600' 'IDLE_LOCK_SEC=1200' \
        'VALIDATE_MEDIA=0'
    out="$(run check 2>&1)"
    assert_not_contains "tidak lagi complained" "$out" "terlalu pendek"
    t_end
}

# ---------------------------------------------------------------------------
# Integrasi idle
# ---------------------------------------------------------------------------

t_idle_config() {
    t_begin "template hypridle"
    local conf="$XDG_CONFIG_HOME/hypr/hypridle.conf"
    runq install --idle-daemon hypridle
    assert_file "hypridle.conf dibuat" "$conf"
    if [ -f "$conf" ]; then
        local c
        c="$(cat "$conf")"
        assert_contains "pemicu start" "$c" "noctoprevi start"
        assert_contains "pemicu stop" "$c" "noctoprevi stop"
        assert_contains "lockscreen Noctalia" "$c" "noctalia msg lock"
        assert_contains "ada penanda blok" "$c" ">>> noctoprevi >>>"
        assert_contains "listener on-resume" "$c" "on-resume"
    fi
    runq uninstall --idle-daemon hypridle
    if [ -f "$conf" ]; then
        assert_not_contains "blok dibuang" "$(cat "$conf")" "noctoprevi start"
    else
        t_ok "blok dibuang"
    fi
    t_end
}

t_idle_config_idempotent() {
    t_begin "install berulang tidak menduplikasi"
    local conf="$XDG_CONFIG_HOME/hypr/hypridle.conf"
    runq install --idle-daemon hypridle
    runq install --idle-daemon hypridle
    runq install --idle-daemon hypridle
    assert_eq "hanya satu blok" \
        "$(grep -c 'noctoprevi start' "$conf" 2>/dev/null || printf 0)" "1"
    t_end
}

t_idle_swayidle() {
    t_begin "template swayidle"
    local conf="$XDG_CONFIG_HOME/swayidle/config"
    runq install --idle-daemon swayidle
    assert_file "swayidle config dibuat" "$conf"
    if [ -f "$conf" ]; then
        local c
        c="$(cat "$conf")"
        # Varian-agnostic: dua varian swayidle punya config yang tidak
        # kompatibel, jadi yang diuji di sini isi blok. Validitas sintaksnya
        # diuji terpisah terhadap swayidle sungguhan.
        assert_contains "perintah start ada" "$c" "start"
        assert_contains "perintah stop ada" "$c" "stop"
        # exec_while_idle bukan keyword swayidle; kalau muncul, swayidle
        # menolak seluruh config lalu keluar tanpa pesan yang terlihat.
        assert_not_contains "tanpa keyword ngawur" "$c" "exec_while_idle = "
    fi
    t_end
}

t_idle_preserves_user_config() {
    t_begin "install menjaga konfigurasi lama"
    local conf="$XDG_CONFIG_HOME/swayidle/config"
    mkdir -p "${conf%/*}"
    printf 'timeout=600\n# catatan milik user\nbaris=ngawur\n' >"$conf"
    runq install --idle-daemon swayidle
    local c
    c="$(cat "$conf" 2>/dev/null)"
    assert_contains "baris lama utuh" "$c" "baris=ngawur"
    assert_contains "baris lain utuh" "$c" "# catatan milik user"
    assert_contains "blok baru ditambahkan" "$c" "noctoprevi stop"
    t_end
}

t_install_creates_config() {
    t_begin "install membuat config default"
    rm -f "$XDG_CONFIG_HOME/noctoprevi/config.conf"
    runq install
    assert_file "config.conf dibuat" "$XDG_CONFIG_HOME/noctoprevi/config.conf"
    assert_file "direktori video dibuat" "$VIDEOS"
    local c
    c="$(cat "$XDG_CONFIG_HOME/noctoprevi/config.conf" 2>/dev/null)"
    assert_contains "berisi PLAYBACK_MODE" "$c" "PLAYBACK_MODE"
    assert_contains "berisi HWDEC" "$c" "HWDEC"
    assert_contains "berisi MONITOR_MODE" "$c" "MONITOR_MODE"
    t_end
}

# ---------------------------------------------------------------------------
# Doctor / bench / aerials
# ---------------------------------------------------------------------------

t_doctor() {
    t_begin "doctor"
    local out
    out="$(run doctor)"
    assert_contains "menyebut versi" "$out" "noctoprevi"
    assert_contains "cek mpv" "$out" "mpv"
    assert_contains "cek socat" "$out" "socat"
    assert_contains "bagian Akselerasi" "$out" "Akselerasi"
    assert_contains "laporan Runtime" "$out" "Runtime"
    assert_no_crash "tidak crash" "$out"
    t_end
}

t_bench_runs() {
    t_begin "bench"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" 30 || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
    local out
    out="$(run bench --runs 3)"
    assert_contains "laporan p50" "$out" "p50"
    assert_contains "laporan p95" "$out" "p95"
    t_end
}

t_bench_no_media() {
    t_begin "bench tanpa media"
    assert_eq "exit 2" "$(code bench --runs 1)" "2"
    t_end
}

t_aerials_help() {
    t_begin "aerials help"
    local out
    out="$(run aerials --help)"
    assert_contains "menjelaskan --sync" "$out" "--sync"
    assert_contains "menjelaskan quality" "$out" "--quality"
    assert_contains "menjelaskan --only" "$out" "--only"
    t_end
}

t_aerials_quality_map() {
    t_begin "peta kualitas aerials"
    local out
    out="$(nc_unit 'NC_VERSION=t' '
        . "$NCU_ROOT/lib/aerials.sh"
        nc_init_paths
        for q in 1080p 1080p-hevc 1080p-hdr 4k 4k-hdr; do
            printf "%s=%s\n" "$q" "$(nc_aerials_quality_key "$q")"
        done
    ')"
    assert_contains "1080p -> H264" "$out" "1080p=url-1080-H264"
    assert_contains "4k -> 4K SDR" "$out" "4k=url-4K-SDR"
    assert_contains "4k-hdr -> 4K HDR" "$out" "4k-hdr=url-4K-HDR"
    t_end
}

t_aerials_manifest_parse() {
    t_begin "parse manifest aerials"
    have jq || { t_skip "butuh jq"; t_end; return; }
    local mf="$SANDBOX/entries.json"
    cat >"$mf" <<'JSON'
{"assets":[
 {"accessibilityLabel":"Test One","url-1080-H264":"https://example.invalid/one_2K_AVC.mov","url-4K-SDR":"https://example.invalid/one_4K_HEVC.mov"},
 {"accessibilityLabel":"Test Two","url-1080-H264":"https://example.invalid/two_2K_AVC.mov","url-4K-SDR":"https://example.invalid/two_4K_HEVC.mov"},
 {"accessibilityLabel":"No H264","url-4K-SDR":"https://example.invalid/only4k.mov"}
]}
JSON
    local res
    res="$(NCU_ROOT="$ROOT" AERIALS_MF="$mf" NCU_VIDEOS="$VIDEOS" bash -c '
        set -uo pipefail
        . "$NCU_ROOT/lib/core.sh"; . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"; . "$NCU_ROOT/lib/aerials.sh"
        nc_log_init; NC_LOG_TARGET=none; NC_LOG_LEVEL=off
        nc_config_defaults
        NC_AERIALS_QUALITY=1080p
        printf "1080p=%s\n" "$(nc_aerials_list "$AERIALS_MF" | wc -l)"
        NC_AERIALS_QUALITY=4k
        printf "4k=%s\n" "$(nc_aerials_list "$AERIALS_MF" | wc -l)"
        NC_AERIALS_QUALITY=1080p
        printf "only-one=%s\n" "$(nc_aerials_pick "$AERIALS_MF" "Test One" | xargs -n1 basename | tr "\n" ",")"
        NC_AERIALS_QUALITY=4k
        printf "only-one-4k=%s\n" "$(nc_aerials_pick "$AERIALS_MF" "Test One" | xargs -n1 basename | tr "\n" ",")"
    ')"
    assert_contains "1080p punya 2 clip" "$res" "1080p=2"
    assert_contains "4k punya 3 clip" "$res" "4k=3"
    assert_contains "filter label + quality 1080p" "$res" "only-one=one_2K_AVC.mov,"
    assert_contains "filter label + quality 4k" "$res" "only-one-4k=one_4K_HEVC.mov,"
    t_end
}

# ---------------------------------------------------------------------------
# Keamanan / isolasi
# ---------------------------------------------------------------------------

t_socket_permissions() {
    t_begin "socket tidak world-writable"
    need_mpv || return
    make_clip "$VIDEOS/a.mp4" || { t_skip "butuh ffmpeg"; t_end; return; }
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
    runq start
    sleep 0.5
    local sock="$XDG_RUNTIME_DIR/noctoprevi.sock"
    if [ -S "$sock" ]; then
        local mode
        mode="$(stat -c '%a' "$sock" 2>/dev/null)"
        case "$mode" in
            6?? | 7??) t_ok "mode=$mode (user only)" ;;
            *) t_no "socket tidak world-writable" "mode=$mode" ;;
        esac
    else
        t_no "socket ada" "tidak ditemukan"
    fi
    t_end
}

t_no_cross_user_socket() {
    t_begin "fallback /tmp per-UID"
    local out
    out="$(XDG_RUNTIME_DIR=/nonexistent-dir-xyz run doctor 2>&1)"
    assert_contains "pakai path ber-UID di /tmp" "$out" "noctoprevi-$UID"
    t_end
}

t_config_not_world_read() {
    t_begin "config tidak menimpa file lain"
    printf 'PENTING=janganrusak\n' >"$XDG_CONFIG_HOME/noctoprevi/config.conf"
    runq doctor >/dev/null
    assert_contains "file config utuh" \
        "$(cat "$XDG_CONFIG_HOME/noctoprevi/config.conf")" "PENTING=janganrusak"
    t_end
}

# ---------------------------------------------------------------------------

ALL_TESTS=(
    t_version t_help t_usage_error t_options_after_command
    t_status_clean t_stop_when_idle t_toggle_when_idle
    t_start_empty_dir t_start_wrong_extension_only
    t_config_parse t_config_quotes t_config_unknown_key
    t_config_bad_values t_config_file_override t_config_missing_file
    t_json_escape t_sock_path t_sock_fallback
    t_media_discovery t_ext_filter t_recursive_scan
    t_order_sequential t_pick_respects_skip t_order_advance t_order_shuffle
    t_shuffle_actually_random t_missing_media_midplay t_all_media_deleted
    t_lifecycle t_singleton t_concurrent_start t_toggle
    t_invalid_media_recovery t_all_broken_media t_next_without_running
    t_msleep_actually_sleeps t_exit_anim_filter_accepted \
        t_exit_anim_defaults_and_validation t_exit_anim_unknown_returns_ok \
        t_mpv_releases_keyboard t_swayidle_block_variant \
        t_swayidle_block_parses
    t_signal_kills_children t_start_reports_supervisor_failure
    t_latency t_stop_repeated t_stop_orphan_recovery
    t_stale_socket t_ipc_dead_socket
    t_installed_layout t_symlink_invocation t_no_lib_error_message
    t_validate_media_levels t_validate_media_config
    t_fps_limit t_fps_limit_applied_to_mpv t_config_warnings_reach_destination
    t_anomaly_ndjson_valid t_anomaly_escaping_roundtrip t_anomaly_field_extraction
    t_anomaly_health_and_counts t_anomaly_rotation t_anomaly_codes_documented
    t_anomaly_cmd_output t_anomaly_emitted_on_real_run
    t_tui_requires_tty t_tui_renders_in_pty t_bare_invocation_opens_tui
    t_check_command
    t_lock_released_between_cycles t_bench_starts_every_cycle
    t_log_target_daemon t_log_no_stdout_stderr_leak t_log_rotation t_log_rotation_disabled
    t_no_pipe_hang_even_when_stderr_forced t_interactive_keeps_logs
    t_idle_defaults_consistent t_idle_generated_matches_config t_doctor_shows_idle
    t_idle_config t_idle_config_idempotent t_idle_swayidle
    t_idle_preserves_user_config t_install_creates_config
    t_doctor t_bench_runs t_bench_no_media
    t_aerials_help t_aerials_quality_map t_aerials_manifest_parse
    t_aerials_root_fingerprint_logic t_aerials_trust_config
    t_aerials_trust_system_no_bootstrap t_aerials_tampered_fingerprint_rejected
    t_output_detection t_wlr_randr_parser
    t_socket_permissions t_no_cross_user_socket t_config_not_world_read
)

if [ "$LISTONLY" -eq 1 ]; then
    for t in "${ALL_TESTS[@]}"; do printf '%s\n' "$t"; done
    exit 0
fi

printf '\n%s %s - test suite\n' "noctoprevi" "$VERSION"
printf '%s\n' "root    : $ROOT"
printf '%s\n' "sandbox : mktemp per test, XDG terisolasi"
printf '%s\n' "mpv     : $(have mpv && mpv --version 2>/dev/null | head -1 || printf 'TIDAK ADA')"
printf '%s\n' "socat   : $(have socat && socat -V 2>/dev/null | head -1 || printf 'TIDAK ADA')"
printf '%s\n' "video   : $([ "$USE_GPU" -eq 1 ] && printf 'GPU sungguhan' || printf 'headless (--vo=null)')"
printf '\n'

T0="${EPOCHREALTIME/./}"
for t in "${ALL_TESTS[@]}"; do
    name="${t#t_}"
    name="${name//_/-}"
    if [ -n "$FILTER" ]; then
        case "$name" in
            *"$FILTER"*) ;;
            *) continue ;;
        esac
    fi
    "$t"
done
T1="${EPOCHREALTIME/./}"

printf '\n%s\n' "----------------------------------------------------------------"
printf 'lulus %s   gagal %s   dilewati %s   %sms\n' \
    "$(c_grn "$T_PASS")" \
    "$([ "$T_FAIL" -eq 0 ] && c_grn 0 || c_red "$T_FAIL")" \
    "$T_SKIP" \
    "$(( (T1 - T0) / 1000 ))"
if [ "$T_FAIL" -gt 0 ]; then
    printf '\n%s\n' "Gagal:"
    for f in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
exit 0
