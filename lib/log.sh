# shellcheck shell=bash
#
# noctoprevi - logging: stderr, file, dan journald.

NC_LOG_LEVEL_DEBUG=0
NC_LOG_LEVEL_INFO=1
NC_LOG_LEVEL_WARN=2
NC_LOG_LEVEL_ERROR=3
NC_LOG_LEVEL_OFF=4

NC_LOG_LEVEL_NAME="debug info warn error off"

nc_log_level_parse() {
    local v
    v="$(nc_lower "$(nc_trim "${1:-}")")"
    case "$v" in
        debug | trace | verbose) printf '%d' "$NC_LOG_LEVEL_DEBUG" ;;
        info | notice) printf '%d' "$NC_LOG_LEVEL_INFO" ;;
        warn | warning) printf '%d' "$NC_LOG_LEVEL_WARN" ;;
        error | err | fatal | crit) printf '%d' "$NC_LOG_LEVEL_ERROR" ;;
        off | none | silent | quiet) printf '%d' "$NC_LOG_LEVEL_OFF" ;;
        *) return 1 ;;
    esac
}

nc_log_level_name() {
    case "${1:-$NC_LOG_LEVEL_INFO}" in
        0) printf 'debug' ;;
        1) printf 'info' ;;
        2) printf 'warn' ;;
        3) printf 'error' ;;
        *) printf 'off' ;;
    esac
}

nc_log_init() {
    NC_LOG_LEVEL="${NC_LOG_LEVEL:-$NC_LOG_LEVEL_INFO}"
    NC_LOG_TARGET="${NC_LOG_TARGET:-stderr}"
    NC_LOG_FILE="${NC_LOG_FILE:-}"
    NC_LOG_IDENT="${NC_LOG_IDENT:-$NC_APP}"
    local lvl
    if lvl="$(nc_log_level_parse "$NC_LOG_LEVEL")"; then
        NC_LOG_LEVEL="$lvl"
    else
        NC_LOG_LEVEL="$NC_LOG_LEVEL_INFO"
    fi

    case "$(nc_lower "$NC_LOG_TARGET")" in
        auto)
            if [ -n "${JOURNAL_STREAM:-}" ] || [ -S /run/systemd/journal/socket ]; then
                NC_LOG_TARGET="journal"
            else
                NC_LOG_TARGET="stderr"
            fi
            ;;
        journal | systemd) NC_LOG_TARGET="journal" ;;
        file) NC_LOG_TARGET="file" ;;
        both) NC_LOG_TARGET="both" ;;
        none | off | silent) NC_LOG_TARGET="none" ;;
        stderr | *) NC_LOG_TARGET="stderr" ;;
    esac

    if [ "$NC_LOG_TARGET" = "file" ] || [ "$NC_LOG_TARGET" = "both" ]; then
        [ -n "$NC_LOG_FILE" ] || NC_LOG_FILE="$NC_LOG_FILE_DEFAULT"
        NC_LOG_DIR="${NC_LOG_FILE%/*}"
        if [ "$NC_LOG_DIR" = "$NC_LOG_FILE" ]; then
            NC_LOG_DIR="."
        fi
        if [ ! -d "$NC_LOG_DIR" ] && ! mkdir -p "$NC_LOG_DIR" 2>/dev/null; then
            NC_LOG_TARGET="stderr"
            NC_LOG_FILE=""
        fi
    fi
}

nc_log_emit() {
    local level="$1" msg="$2"
    local threshold="${NC_LOG_LEVEL:-$NC_LOG_LEVEL_INFO}"
    local target="${NC_LOG_TARGET:-stderr}"
    local ident="${NC_LOG_IDENT:-${NC_APP:-noctoprevi}}"

    case "$threshold" in
        '' | *[!0-9]*) threshold="$(nc_log_level_parse "$threshold")" || threshold="$NC_LOG_LEVEL_INFO" ;;
    esac
    case "$target" in
        '' | *[!a-z]*) target="stderr" ;;
    esac

    [ "$threshold" -le "$level" ] || return 0

    local name line
    case "$level" in
        0) name="debug" ;;
        1) name="info" ;;
        2) name="warn" ;;
        3) name="error" ;;
        *) name="off" ;;
    esac
    local sec="${EPOCHSECONDS:-0}" frac="${EPOCHREALTIME:-0}" stamp
    frac="${frac#*.}"
    [ -n "$frac" ] || frac="000000"
    printf -v stamp '%(%Y-%m-%dT%H:%M:%S)T' "$sec"
    line="$stamp.${frac:0:6} ${ident}[$name]: $msg"

    case "$target" in
        none | off) ;;
        journal)
            printf '<%d>%s\n' "$(( level + 6 ))" "$line" | systemd-cat -t "$ident" 2>/dev/null ||
                printf '%s\n' "$line" >&2
            ;;
        file | both)
            local lf="${NC_LOG_FILE:-}"
            if [ -z "$lf" ]; then
                printf '%s\n' "$line" >&2
            else
                printf '%s\n' "$line" >>"$lf" 2>/dev/null
                [ "$target" = "both" ] && printf '%s\n' "$line" >&2
            fi
            ;;
        stderr | *) printf '%s\n' "$line" >&2 ;;
    esac
    return 0
}

nc_log_debug() { nc_log_emit "$NC_LOG_LEVEL_DEBUG" "$*"; }
nc_log_info() { nc_log_emit "$NC_LOG_LEVEL_INFO" "$*"; }
nc_log_warn() { nc_log_emit "$NC_LOG_LEVEL_WARN" "$*"; }
nc_log_error() { nc_log_emit "$NC_LOG_LEVEL_ERROR" "$*"; }
