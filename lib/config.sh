# shellcheck shell=bash
#
# noctoprevi - parser ~/.config/noctoprevi/config.conf
#
# Format: KEY=VALUE, satu per baris, '#' memulai komentar baris penuh.
# Nilai boleh diapit ' atau ". Baris kosong diabaikan.
# Key yang tidak dikenal dicatat sebagai warning, bukan error.

NC_CFG_KEYS="START_WARN_MS STOP_WARN_MS ANOMALY_ENABLED ANOMALY_MAX_LINES ANOMALY_NOTIFY ANOMALY_NOTIFY_INTERVAL VIDEO_FPS_LIMIT MIN_DURATION_SEC AERIALS_TRUST AERIALS_CURL_ARGS STOP_IPC_WAIT_MS VIDEO_DIR PLAYBACK_MODE VIDEO_EXTENSIONS VIDEO_RECURSIVE VALIDATE_MEDIA RETRY_LIMIT STARTUP_GRACE_MS HWDEC AUDIO LOOP_FILE CURSOR_AUTOHIDE FULLSCREEN BORDER OSD_LEVEL MONITOR_MODE MPV_ARGS EXTRA_MPV_ARGS LOG_LEVEL LOG_TARGET LOG_FILE LOG_MAX_LINES IDLE_START_SEC IDLE_LOCK_SEC AERIALS_QUALITY AERIALS_DIR MAX_INSTANCES"

nc_config_defaults() {
    NC_VIDEO_DIR="${NC_CONFIG_DIR:-$HOME/.config/$NC_APP}/videos"
    NC_PLAYBACK_MODE="shuffle"
    NC_VIDEO_EXTENSIONS="mp4,mkv,webm,mov"
    NC_VIDEO_RECURSIVE=0
    NC_VALIDATE_MEDIA=1
    NC_MIN_DURATION_SEC=1
    NC_RETRY_LIMIT=3
    NC_STARTUP_GRACE_MS=2500
    NC_HWDEC="auto"
    NC_AUDIO="none"
    NC_LOOP_FILE="inf"
    NC_CURSOR_AUTOHIDE="always"
    NC_FULLSCREEN=1
    NC_BORDER=0
    NC_OSD_LEVEL=0
    NC_VIDEO_FPS_LIMIT=0
    NC_ANOMALY_ENABLED=1
    NC_START_WARN_MS=1500
    NC_STOP_WARN_MS=150
    NC_ANOMALY_MAX_LINES=2000
    NC_ANOMALY_NOTIFY=0
    NC_ANOMALY_NOTIFY_INTERVAL=3600
    NC_MONITOR_MODE="focused"
    NC_MPV_ARGS=""
    NC_EXTRA_MPV_ARGS=""
    NC_LOG_MAX_LINES=2000
    NC_STOP_IPC_WAIT_MS=20
    NC_IDLE_START_SEC=600
    NC_IDLE_LOCK_SEC=1200
    NC_AERIALS_QUALITY="1080p"
    NC_AERIALS_TRUST="auto"
    NC_AERIALS_CURL_ARGS=""
    NC_AERIALS_DIR=""
    NC_MAX_INSTANCES=1
    NC_CFG_LOADED=0
    NC_CFG_UNKNOWN=""
    NC_CFG_WARNINGS=()
}

# Peringatan yang terbit saat config dimuat dikumpulkan dulu, bukan langsung
# dicetak. Alasan: config itu sendiri yang menentukan ke mana log dikirim
# (LOG_TARGET), jadi peringatan yang terbit sebelum config dibaca tidak akan
# sampai ke tempat yang pengguna minta. Setelah log siap, baru dicetak.
nc_config_warn() {
    NC_CFG_WARNINGS+=("$1")
}

nc_config_flush_warnings() {
    local w
    for w in "${NC_CFG_WARNINGS[@]}"; do
        nc_log_warn "$w"
    done
    NC_CFG_WARNINGS=()
    return 0
}

nc_config_known_key() {
    local key="$1" k
    for k in $NC_CFG_KEYS; do
        [ "$k" = "$key" ] && return 0
    done
    return 1
}

# Semua helper di bawah murni operasi string bash. Kalau dipanggil lewat
# $(...) setiap invocation jadi satu fork, dan parsing ~50 baris config akan
# memakan puluhan milidetik. Karena itu parser utama tidak memakai $(...)
# sama sekali - semua inline.

nc_trim_var() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    NC_TRIMMED="$s"
}

nc_config_unquote_var() {
    local v="$1"
    case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    NC_TRIMMED="$v"
}

nc_config_bool() {
    local v
    v="$(nc_lower "$(nc_trim "${1:-}")")"
    case "$v" in
        1 | on | true | yes | y) return 0 ;;
        *) return 1 ;;
    esac
}

nc_config_is_int() {
    case "${1:-}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    return 0
}

nc_config_apply() {
    local key="$1" v="$2"
    nc_config_unquote_var "$v"
    v="$NC_TRIMMED"

    case "$key" in
        VIDEO_DIR)
            # shellcheck disable=SC2088
            case "$v" in
                "~") v="$HOME" ;;
                "~/"*) v="$HOME/${v#\~/}" ;;
            esac
            NC_VIDEO_DIR="$v"
            ;;
        PLAYBACK_MODE) NC_PLAYBACK_MODE="${v,,}" ;;
        VIDEO_EXTENSIONS) NC_VIDEO_EXTENSIONS="${v,,}" ;;
        VIDEO_RECURSIVE)
            if nc_config_bool "$v"; then NC_VIDEO_RECURSIVE=1; else NC_VIDEO_RECURSIVE=0; fi
            ;;
        VALIDATE_MEDIA)
            if nc_config_bool "$v"; then
                NC_VALIDATE_MEDIA=1
            else
                case "$v" in
                    0) NC_VALIDATE_MEDIA=0 ;;
                    1) NC_VALIDATE_MEDIA=1 ;;
                    2) NC_VALIDATE_MEDIA=2 ;;
                    *) NC_VALIDATE_MEDIA=1 ;;
                esac
            fi
            ;;
        MIN_DURATION_SEC)
            if nc_config_is_int "$v"; then
                NC_MIN_DURATION_SEC="$v"
            else
                NC_MIN_DURATION_SEC=1
            fi
            ;;
        RETRY_LIMIT)
            if nc_config_is_int "$v"; then NC_RETRY_LIMIT="$v"; else NC_RETRY_LIMIT=3; fi
            ;;
        STARTUP_GRACE_MS)
            if nc_config_is_int "$v"; then NC_STARTUP_GRACE_MS="$v"; else NC_STARTUP_GRACE_MS=2500; fi
            ;;
        HWDEC) NC_HWDEC="$v" ;;
        AUDIO) NC_AUDIO="${v,,}" ;;
        LOOP_FILE) NC_LOOP_FILE="$v" ;;
        CURSOR_AUTOHIDE) NC_CURSOR_AUTOHIDE="${v,,}" ;;
        FULLSCREEN)
            if nc_config_bool "$v"; then NC_FULLSCREEN=1; else NC_FULLSCREEN=0; fi
            ;;
        BORDER)
            if nc_config_bool "$v"; then NC_BORDER=1; else NC_BORDER=0; fi
            ;;
        OSD_LEVEL)
            if nc_config_is_int "$v"; then NC_OSD_LEVEL="$v"; else NC_OSD_LEVEL=0; fi
            ;;
        START_WARN_MS)
            if nc_config_is_int "$v"; then NC_START_WARN_MS="$v"; else NC_START_WARN_MS=1500; fi
            ;;
        STOP_WARN_MS)
            if nc_config_is_int "$v"; then NC_STOP_WARN_MS="$v"; else NC_STOP_WARN_MS=150; fi
            ;;
        ANOMALY_ENABLED)
            if nc_config_bool "$v"; then NC_ANOMALY_ENABLED=1; else NC_ANOMALY_ENABLED=0; fi
            ;;
        ANOMALY_MAX_LINES)
            if nc_config_is_int "$v"; then
                NC_ANOMALY_MAX_LINES="$v"
            else
                NC_ANOMALY_MAX_LINES=2000
            fi
            ;;
        ANOMALY_NOTIFY)
            if nc_config_bool "$v"; then NC_ANOMALY_NOTIFY=1; else NC_ANOMALY_NOTIFY=0; fi
            ;;
        ANOMALY_NOTIFY_INTERVAL)
            if nc_config_is_int "$v"; then
                NC_ANOMALY_NOTIFY_INTERVAL="$v"
            else
                NC_ANOMALY_NOTIFY_INTERVAL=3600
            fi
            ;;
        VIDEO_FPS_LIMIT)
            case "$v" in
                0 | 15 | 24 | 25 | 30 | 50 | 60)
                    NC_VIDEO_FPS_LIMIT="$v"
                    ;;
                *)
                    nc_config_warn "VIDEO_FPS_LIMIT tidak dikenal: '$v' -> 0 (mati)"
                    NC_VIDEO_FPS_LIMIT=0
    NC_ANOMALY_ENABLED=1
    NC_START_WARN_MS=1500
    NC_STOP_WARN_MS=150
    NC_ANOMALY_MAX_LINES=2000
    NC_ANOMALY_NOTIFY=0
    NC_ANOMALY_NOTIFY_INTERVAL=3600
                    ;;
            esac
            ;;
        MONITOR_MODE) NC_MONITOR_MODE="${v,,}" ;;
        MPV_ARGS) NC_MPV_ARGS="$v" ;;
        EXTRA_MPV_ARGS) NC_EXTRA_MPV_ARGS="$v" ;;
        LOG_LEVEL) NC_LOG_LEVEL="$v" ;;
        LOG_TARGET) NC_LOG_TARGET="${v,,}" ;;
        LOG_FILE)
            # shellcheck disable=SC2088
            case "$v" in
                "~") v="$HOME" ;;
                "~/"*) v="$HOME/${v#\~/}" ;;
            esac
            NC_LOG_FILE="$v"
            ;;
        LOG_MAX_LINES)
            if nc_config_is_int "$v"; then NC_LOG_MAX_LINES="$v"; else NC_LOG_MAX_LINES=2000; fi
            ;;
        STOP_IPC_WAIT_MS)
            if nc_config_is_int "$v"; then
                NC_STOP_IPC_WAIT_MS="$v"
            else
                NC_STOP_IPC_WAIT_MS=20
            fi
            ;;
        IDLE_START_SEC)
            if nc_config_is_int "$v"; then NC_IDLE_START_SEC="$v"; else NC_IDLE_START_SEC=600; fi
            ;;
        IDLE_LOCK_SEC)
            if nc_config_is_int "$v"; then NC_IDLE_LOCK_SEC="$v"; else NC_IDLE_LOCK_SEC=1200; fi
            ;;
        AERIALS_QUALITY) NC_AERIALS_QUALITY="$v" ;;
        AERIALS_TRUST) NC_AERIALS_TRUST="${v,,}" ;;
        AERIALS_CURL_ARGS) NC_AERIALS_CURL_ARGS="$v" ;;
        AERIALS_DIR)
            # shellcheck disable=SC2088
            case "$v" in
                "~") v="$HOME" ;;
                "~/"*) v="$HOME/${v#\~/}" ;;
            esac
            NC_AERIALS_DIR="$v"
            ;;
        MAX_INSTANCES)
            if nc_config_is_int "$v" && [ "$v" -ge 1 ]; then
                NC_MAX_INSTANCES="$v"
            else
                NC_MAX_INSTANCES=1
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

nc_config_validate() {
    local bad=0
    case "$NC_PLAYBACK_MODE" in
        shuffle | random) NC_PLAYBACK_MODE="shuffle" ;;
        sequential | seq | order | playlist) NC_PLAYBACK_MODE="sequential" ;;
        *)
            nc_log_warn "PLAYBACK_MODE tidak dikenal: '$NC_PLAYBACK_MODE' -> shuffle"
            NC_PLAYBACK_MODE="shuffle"
            ;;
    esac
    case "$NC_MONITOR_MODE" in
        focused | active | single | all | per-monitor | permonitor) ;;
        *)
            nc_log_warn "MONITOR_MODE tidak dikenal: '$NC_MONITOR_MODE' -> focused"
            NC_MONITOR_MODE="focused"
            ;;
    esac
    case "$NC_VALIDATE_MEDIA" in
        0 | 1 | 2) ;;
        *)
            nc_log_warn "VALIDATE_MEDIA tidak dikenal: '$NC_VALIDATE_MEDIA' -> 1"
            NC_VALIDATE_MEDIA=1
            ;;
    esac
    case "$NC_AUDIO" in
        none | no | off | false)
            NC_AUDIO="none"
            ;;
    esac
    if [ -z "$NC_VIDEO_EXTENSIONS" ]; then
        nc_log_warn "VIDEO_EXTENSIONS kosong -> memakai default mp4,mkv,webm,mov"
        NC_VIDEO_EXTENSIONS="mp4,mkv,webm,mov"
    fi
    case "$NC_AERIALS_TRUST" in
        auto | system | apple) ;;
        *)
            nc_log_warn "AERIALS_TRUST tidak dikenal: '$NC_AERIALS_TRUST' -> auto"
            NC_AERIALS_TRUST="auto"
            ;;
    esac
    if [ -n "$NC_AERIALS_DIR" ]; then
        :
    else
        NC_AERIALS_DIR="$NC_VIDEO_DIR"
    fi
    return $bad
}

nc_config_load() {
    local file="${1:-$NC_CONFIG_FILE}"
    NC_CFG_LOADED=0

    if [ ! -e "$file" ]; then
        nc_log_debug "config tidak ada, memakai default: $file"
        return 0
    fi
    if [ ! -r "$file" ]; then
        nc_log_warn "config tidak bisa dibaca: $file"
        return 0
    fi

    local line key val lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$(( lineno + 1 ))
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in
            '#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *)
                nc_config_warn "$file:$lineno: baris tanpa '=': $line"
                continue
                ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        nc_config_unquote_var "$val"
        val="$NC_TRIMMED"
        if [ -z "$key" ]; then
            nc_config_warn "$file:$lineno: key kosong"
            continue
        fi
        if ! nc_config_known_key "$key"; then
            NC_CFG_UNKNOWN="${NC_CFG_UNKNOWN:+$NC_CFG_UNKNOWN,}$key"
            nc_config_warn "$file:$lineno: key tidak dikenal, diabaikan: $key"
            continue
        fi
        nc_config_apply "$key" "$val"
    done < "$file"

    NC_CFG_LOADED=1
    nc_log_debug "config dimuat: $file"
    return 0
}

nc_config_ext_array() {
    NC_EXT_ARR=()
    local part
    local -a raw
    IFS=',' read -r -a raw <<<"${NC_VIDEO_EXTENSIONS:-}"
    for part in "${raw[@]}"; do
        part="${part// /}"
        part="${part,,}"
        part="${part#\.}"
        part="${part##*/}"
        [ -n "$part" ] && NC_EXT_ARR+=("$part")
    done
    [ "${#NC_EXT_ARR[@]}" -gt 0 ] || NC_EXT_ARR=(mp4 mkv webm mov)
    return 0
}

nc_config_write_default() {
    local file="${1:-$NC_CONFIG_FILE}"
    local dir="${file%/*}"
    [ "$dir" = "$file" ] && dir="."
    mkdir -p "$dir" 2>/dev/null || {
        nc_log_error "gagal membuat direktori config: $dir"
        return 1
    }
    [ -e "$file" ] && return 0

    local tpl="${NOCTOPREVI_TEMPLATE_DIR:-$NC_CONFIG_DIR}/config.conf"
    if [ -r "$tpl" ] && [ "$tpl" != "$file" ]; then
        cp -f "$tpl" "$file" 2>/dev/null && return 0
    fi
    nc_log_error "template config tidak ditemukan: $tpl"
    return 1
}
