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
    NCU_SETUP="$setup" NCU_BODY="$body" NCU_ROOT="$ROOT" bash -c '
        set -uo pipefail
        . "$NCU_ROOT/lib/core.sh"
        . "$NCU_ROOT/lib/log.sh"
        . "$NCU_ROOT/lib/config.sh"
        . "$NCU_ROOT/lib/media.sh"
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
    assert_contains "versi tercetak" "$(run version)" "noctoprevi"
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
    nc_write_config "VIDEO_DIR=$VIDEOS" 'VALIDATE_MEDIA=0'
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
    for l in core log config media ipc runtime cmd setup aerials; do
        install -m 644 "$ROOT/lib/$l.sh" "$prefix/lib/noctoprevi/$l.sh"
    done
    install -m 644 "$ROOT/config/config.conf" "$prefix/share/noctoprevi/config.conf"

    local out rc
    out="$("$prefix/bin/noctoprevi" version 2>&1)"
    assert_contains "binary Prefix menemukan lib-nya" "$out" "noctoprevi 1.0.0"
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
    assert_contains "symlink tetap menemukan lib" "$out" "noctoprevi 1.0.0"
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
        assert_contains "exec_while_idle" "$c" "exec_while_idle = noctoprevi start"
        assert_contains "exec_on_resume" "$c" "exec_on_resume = noctoprevi stop"
    fi
    t_end
}

t_idle_preserves_user_config() {
    t_begin "install menjaga konfigurasi lama"
    local conf="$XDG_CONFIG_HOME/swayidle/config"
    mkdir -p "${conf%/*}"
    printf 'timeout=600\nexec_while_idle=htop\n' >"$conf"
    runq install --idle-daemon swayidle
    local c
    c="$(cat "$conf" 2>/dev/null)"
    assert_contains "baris lama utuh" "$c" "exec_while_idle=htop"
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
    t_signal_kills_children t_start_reports_supervisor_failure
    t_latency t_stop_repeated t_stop_orphan_recovery
    t_stale_socket t_ipc_dead_socket
    t_installed_layout t_symlink_invocation t_no_lib_error_message
    t_idle_config t_idle_config_idempotent t_idle_swayidle
    t_idle_preserves_user_config t_install_creates_config
    t_doctor t_bench_runs t_bench_no_media
    t_aerials_help t_aerials_quality_map t_aerials_manifest_parse
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
