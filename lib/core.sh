# shellcheck shell=bash
#
# noctoprevi - core: konstanta, path XDG, utilitas dasar.
# Di-source oleh bin/noctoprevi. Tidak boleh keluar/exit di sini.

NC_VERSION="1.1.0"
NC_APP="noctoprevi"
NC_TAGLINE="Modular Wayland video screensaver for Noctalia, Hyprland, Sway and Niri"

NC_EXIT_OK=0
NC_EXIT_RUNNING=0
NC_EXIT_NOT_RUNNING=1
NC_EXIT_ERROR=2
NC_EXIT_USAGE=3

NC_SUN_PATH_MAX=100

# $1 = pesan, $2 = kode keluar (opsional). Pesannya hanya $1 - bukan $* -
# kalau pakai $*, kode keluarnya ikut tercetak di pesan.
nc_die() {
    local msg="${1:-}"
    local code="${2:-$NC_EXIT_ERROR}"
    printf '%s: %s\n' "$NC_APP" "$msg" >&2
    exit "$code"
}

nc_have() {
    command -v "$1" >/dev/null 2>&1
}

nc_which() {
    command -v "$1" 2>/dev/null
}

nc_now_us() {
    local t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then
        printf '%s' "${t/./}"
    else
        printf '%s' "$(( ${EPOCHSECONDS:-0} * 1000000 ))"
    fi
}

# Sleep milidetik tanpa fork.
# `sleep` adalah binary eksternal, jadi tiap poll di jalur stop costing ~1ms
# per iterasi. Setelah fd timer dibuat sekali, semua penundaan lewat read -t
# yang murni internal bash.
NC_TIMER_FD=""

nc_timer_init() {
    [ -n "$NC_TIMER_FD" ] && return 0
    local fifo="${TMPDIR:-/tmp}/.nocotimer.$$"
    command -v mkfifo >/dev/null 2>&1 || return 1
    mkfifo "$fifo" 2>/dev/null || return 1
    # PENTING: harus `exec {NC_TIMER_FD}<>`, bukan `exec <>`.
    # Bentuk `exec <>file` membuka fd baru yang NOMORNYA dibuang, jadi
    # NC_TIMER_FD tetap kosong dan `read -u ""` langsung kembali tanpa
    # menunggu - artinya setiap nc_msleep di bawah 1 detik jadi no-op.
    if ! eval "exec {NC_TIMER_FD}<>\"\$fifo\"" 2>/dev/null; then
        rm -f "$fifo" 2>/dev/null
        NC_TIMER_FD=""
        return 1
    fi
    rm -f "$fifo" 2>/dev/null
    return 0
}

nc_msleep() {
    local ms="$1" d=""

    # >= 1 detik: pakai `sleep` langsung. PENTING: jangan `sleep "$ms"` -
    # argumen sleep adalah SATUAN, jadi `nc_msleep 2000` akan tidur 2000
    # detik. Nilai ms dipisah jadi detik + pecahan.
    case "$ms" in
        '' | *[!0-9]*)
            sleep 1 2>/dev/null || sleep 1
            return 0
            ;;
    esac
    if [ "$ms" -ge 1000 ]; then
        sleep "$(printf '%d.%03d' $((ms / 1000)) $((ms % 1000)))" 2>/dev/null ||
            sleep "$(printf '%d' $((ms / 1000)))" 2>/dev/null ||
            sleep 1
        return 0
    fi

    # < 1 detik: butuh timer fd. printf '%03d' menambah nol di depan supaya
    # `0.5` tidak jadi `0.5` -> read -t mau `0.5` yang valid, tapi `0.050`
    # untuk 50ms harus punya 3 desimal.
    d="$(printf '0.%03d' "$ms")"
    if [ -z "$NC_TIMER_FD" ]; then
        nc_timer_init || {
            sleep "$d" 2>/dev/null || sleep 1
            return 0
        }
    fi
    read -t "$d" -u "$NC_TIMER_FD" _ 2>/dev/null
    return 0
}

nc_us_to_ms() {
    printf '%d' "$(( $1 / 1000 ))"
}

nc_trim_var() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    NC_TRIMMED="$s"
}

nc_elapsed_ms() {
    local start="$1" now="${EPOCHREALTIME:-0}"
    now="${now/./}"
    printf '%d' "$(( (now - start) / 1000 ))"
}

nc_is_regular_file() {
    [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]
}

nc_pid_alive() {
    local pid="${1:-}"
    case "$pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$pid" -gt 0 ] 2>/dev/null || return 1
    kill -0 "$pid" 2>/dev/null
}

nc_read_pid() {
    local file="$1" pid
    [ -r "$file" ] || return 1
    IFS= read -r pid < "$file" 2>/dev/null || return 1
    case "$pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$pid"
}

nc_trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

nc_lower() {
    local s="${1:-}"
    printf '%s' "${s,,}"
}

nc_abspath() {
    local p="${1:-}"
    case "$p" in
        /*) ;;
        *) p="$PWD/$p" ;;
    esac
    printf '%s' "$p"
}

nc_expand_tilde() {
    local p="${1:-}"
    # shellcheck disable=SC2088
    case "$p" in
        '~') p="$HOME" ;;
        '~/'*) p="$HOME/${p#\~/}" ;;
    esac
    printf '%s' "$p"
}

nc_json_escape() {
    local s="${1:-}" out="" i ch code
    for (( i = 0; i < ${#s}; i++ )); do
        ch="${s:i:1}"
        case "$ch" in
            '\') out+='\\' ;;
            '"') out+='\"' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            *)
                printf -v code '%d' "'$ch" 2>/dev/null || code=32
                if [ "$code" -lt 32 ]; then
                    out+="$(printf '\\u%04x' "$code")"
                else
                    out+="$ch"
                fi
                ;;
        esac
    done
    printf '%s' "$out"
}

nc_json_string() {
    printf '"%s"' "$(nc_json_escape "${1:-}")"
}

nc_msec() {
    local t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then
        printf '%s' "${t/./}"
    else
        printf '%s000' "${EPOCHSECONDS:-0}"
    fi
}

# printf %()T adalah bawaan bash >= 4.2, jadi tanpa fork `date`.
nc_iso_stamp() {
    local sec="${EPOCHSECONDS:-0}" frac
    frac="${EPOCHREALTIME:-0}"
    frac="${frac#*.}"
    [ -n "$frac" ] || frac="000000"
    printf -v NC_STAMP '%(%Y-%m-%dT%H:%M:%S)T' "$sec"
    printf '%s.%s' "$NC_STAMP" "${frac:0:6}"
}

nc_init_paths() {
    local cfg_home="${XDG_CONFIG_HOME:-}"
    [ -n "$cfg_home" ] || cfg_home="$HOME/.config"
    local state_home="${XDG_STATE_HOME:-}"
    [ -n "$state_home" ] || state_home="$HOME/.local/state"
    local runtime="${XDG_RUNTIME_DIR:-}"
    [ -n "$runtime" ] || runtime=""

    NC_CONFIG_DIR="$cfg_home/$NC_APP"
    NC_CONFIG_FILE="${NOCTOPREVI_CONFIG_FILE:-$NC_CONFIG_DIR/config.conf}"
    NC_STATE_DIR="$state_home/$NC_APP"
    NC_LOG_FILE_DEFAULT="$NC_STATE_DIR/$NC_APP.log"
    NC_DOWNLOAD_DIR="$NC_STATE_DIR/aerials"

    NC_RUNTIME_DIR="$runtime"
    NC_RUNTIME_INFIX=""

    if [ -z "$NC_RUNTIME_DIR" ] || [ ! -d "$NC_RUNTIME_DIR" ] || [ ! -w "$NC_RUNTIME_DIR" ]; then
        NC_RUNTIME_DIR="/tmp"
        NC_RUNTIME_INFIX="-$UID"
    fi

    NC_SOCK="$NC_RUNTIME_DIR/$NC_APP$NC_RUNTIME_INFIX.sock"
    if [ "${#NC_SOCK}" -gt "$NC_SUN_PATH_MAX" ]; then
        if [ -z "$NC_RUNTIME_INFIX" ]; then
            NC_RUNTIME_DIR="/tmp"
            NC_RUNTIME_INFIX="-$UID"
            NC_SOCK="$NC_RUNTIME_DIR/$NC_APP$NC_RUNTIME_INFIX.sock"
        fi
    fi
    if [ "${#NC_SOCK}" -gt "$NC_SUN_PATH_MAX" ]; then
        NC_SOCK="/tmp/np$UID.sock"
    fi

    NC_PIDFILE="$NC_RUNTIME_DIR/$NC_APP$NC_RUNTIME_INFIX.pid"
    NC_LOCKFILE="$NC_RUNTIME_DIR/$NC_APP$NC_RUNTIME_INFIX.lock"
    NC_ORDER_FILE="$NC_RUNTIME_DIR/$NC_APP$NC_RUNTIME_INFIX.order"
    NC_INDEX_FILE="$NC_RUNTIME_DIR/$NC_APP$NC_RUNTIME_INFIX.index"
    NC_MEDIA_FILE="$NC_RUNTIME_DIR/$NC_APP$NC_RUNTIME_INFIX.media"
}
