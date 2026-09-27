#!/usr/bin/env bash
# shellcheck shell=bash
#
# noctoprevi - terminal interface.
#
# Mengikuti pola nocatoo: ASCII banner, kartu status, menu angka, loop
# clear + read. Bahasa TUI ini English; pesan diagnostik di dalam program
# tetap Bahasa Indonesia supaya konsisten dengan log.
#
# Yang dibuat lebih baik dari nocatoo:
#   - guard TTY di stdout juga, bukan cuma stdin. `clear` di non-TTY itu
#     merusak - penting karena tool ini sering dipanggil daemon.
#   - trap untuk mengembalikan kursor dan leaving alternate state saat keluar.
#   - NO_COLOR dihormati.

NC_TUI_C_RESET=""
NC_TUI_C_BOLD=""
NC_TUI_C_DIM=""
NC_TUI_C_CYAN=""
NC_TUI_C_GREEN=""
NC_TUI_C_YELLOW=""
NC_TUI_C_RED=""
NC_TUI_C_MAGENTA=""
NC_TUI_COLOR=0

nc_tui_setup_colors() {
    NC_TUI_COLOR=0
    [ -t 1 ] || return 0
    case "${NO_COLOR:-}" in
        '' | 0) ;;
        *) return 0 ;;
    esac
    [ "${NC_TUI_FORCE_COLOR:-0}" = "1" ] || [ -t 1 ] || return 0
    NC_TUI_COLOR=1
    NC_TUI_C_RESET=$'\033[0m'
    NC_TUI_C_BOLD=$'\033[1m'
    NC_TUI_C_DIM=$'\033[2m'
    NC_TUI_C_CYAN=$'\033[38;5;51m'
    NC_TUI_C_GREEN=$'\033[38;5;82m'
    NC_TUI_C_YELLOW=$'\033[38;5;220m'
    NC_TUI_C_RED=$'\033[38;5;196m'
    NC_TUI_C_MAGENTA=$'\033[38;5;141m'
    return 0
}

nc_tui_plain() {
    if [ "$NC_TUI_COLOR" -eq 1 ]; then
        printf '%s' "$NC_TUI_C_RESET"
    fi
}

nc_tui_have_tty() {
    [ -t 1 ]
}

# Nama file yang pendek supaya tidak membanjiri layar dengan path penuh.
nc_tui_short_path() {
    local p="${1:-}"
    [ -n "$p" ] || {
        printf '-'
        return 0
    }
    p="${p##*/}"
    [ "${#p}" -gt 44 ] && p="...${p: -41}"
    printf '%s' "$p"
}

nc_tui_human_bytes() {
    local b="${1:-0}"
    case "$b" in
        '' | *[!0-9]*) printf '0B'; return 0 ;;
    esac
    if [ "$b" -lt 1024 ]; then
        printf '%sB' "$b"
    elif [ "$b" -lt 1048576 ]; then
        printf '%sK' "$(( b / 1024 ))"
    elif [ "$b" -lt 1073741824 ]; then
        printf '%sM' "$(( b / 1048576 ))"
    else
        printf '%s.%sG' "$(( b / 1073741824 ))" "$(( (b % 1073741824) * 10 / 1073741824 ))"
    fi
}

nc_tui_human_duration() {
    local s="${1:-0}"
    [ "$s" -ge 0 ] 2>/dev/null || s=0
    if [ "$s" -lt 3600 ]; then
        printf '%sm%02ds' "$(( s / 60 ))" "$(( s % 60 ))"
    else
        printf '%sh%02dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
    fi
}

# ------------------------------------------------------------------ banner

nc_tui_banner() {
    local c=$NC_TUI_C_CYAN b=$NC_TUI_C_BOLD p=$NC_TUI_C_MAGENTA d=$NC_TUI_C_DIM
    printf '%s%s' "$c" "$b"
    cat <<'EOF'
 _   _  ___   ____    _  _____ ___   ___
| \ | |/ _ \ / ___|  / \|_   _/ _ \ / _ \
|  \| | | | | |     / _ \ | || | | | | |
| |\  | |_| | |___ / ___ \| || |_| | |_|
|_| \_|\___/ \____/_/   \_|_| \___/ \___/
EOF
    nc_tui_plain
    printf '%s Video screensaver for Noctalia, Hyprland, Sway and Niri%s\n' \
        "$p" "$NC_TUI_C_RESET"
    printf '%s v%s | config: %s%s\n' "$d" "$NC_VERSION" "$NC_CONFIG_FILE" "$NC_TUI_C_RESET"
    printf '\n'
}

# ------------------------------------------------------------------ kartu

nc_tui_card() {
    local label="$1" value="$2" color="${3:-}"
    printf '  %-14s %s%s%s\n' "$label" "$color" "$value" "$NC_TUI_C_RESET"
}

nc_tui_status_card() {
    local state color icon
    local total health e w s
    local -a counts

    if nc_is_running; then
        state="active"
        color=$NC_TUI_C_GREEN
        icon="*"
    else
        state="stopped"
        color=$NC_TUI_C_DIM
        icon="o"
    fi

    local -a counts=()
    read -r -a counts <<<"$(nc_anomaly_recent_counts)"
    e="${counts[0]:-0}"
    w="${counts[1]:-0}"
    s="${counts[2]:-0}"
    health="$(nc_anomaly_health)"

    local hcolor=$NC_TUI_C_GREEN
    [ "$health" -lt 80 ] 2>/dev/null && hcolor=$NC_TUI_C_YELLOW
    [ "$health" -lt 50 ] 2>/dev/null && hcolor=$NC_TUI_C_RED

    printf '%sStatus:%s\n' "$NC_TUI_C_BOLD" "$NC_TUI_C_RESET"
    nc_tui_card "screensaver" "$icon $state" "$color"
    nc_tui_card "supervisor" "$(nc_supervisor_pid 2>/dev/null || printf '-')"

    if nc_is_running; then
        nc_tui_card "media" "$(nc_tui_short_path "$(nc_current_media 2>/dev/null)")"
        local hwnd
        hwnd="$(nc_ipc_property "$(nc_ipc_sock_for 0)" "hwdec-current" 0.4 2>/dev/null)"
        [ -n "$hwnd" ] && nc_tui_card "hwdec" "$hwnd"
    fi

    nc_tui_card "library" "$(nc_tui_library_summary)"
    nc_tui_card "anomalies" "$e error / $w warn / $s security"
    nc_tui_card "health" "$health/100" "$hcolor"
    nc_tui_card "idle" "${NC_IDLE_START_SEC}s screensaver / ${NC_IDLE_LOCK_SEC}s lock"
    printf '\n'
}

nc_tui_library_summary() {
    local -i n=0 bytes=0
    local f="" sz=0
    for f in "$NC_VIDEO_DIR"/*; do
        [ -f "$f" ] || continue
        n=$(( n + 1 ))
        sz="$(stat -c %s "$f" 2>/dev/null)" || sz=0
        bytes=$(( bytes + sz ))
    done
    if [ "$n" -eq 0 ]; then
        printf 'empty (%s)' "$(nc_tui_short_path "$NC_VIDEO_DIR")"
    else
        printf '%s file, %s' "$n" "$(nc_tui_human_bytes "$bytes")"
    fi
}

# ------------------------------------------------------------------ menu

nc_tui_menu() {
    local b=$NC_TUI_C_BOLD c=$NC_TUI_C_CYAN d=$NC_TUI_C_DIM
    printf '%sActions:%s\n' "$b" "$NC_TUI_C_RESET"
    printf '  %s[1]%s start / stop      %s[6]%s doctor\n' "$c" "$NC_TUI_C_RESET" "$c" "$NC_TUI_C_RESET"
    printf '  %s[2]%s next              %s[7]%s check (preflight)\n' "$c" "$NC_TUI_C_RESET" "$c" "$NC_TUI_C_RESET"
    printf '  %s[3]%s previous          %s[8]%s watch (live)\n' "$c" "$NC_TUI_C_RESET" "$c" "$NC_TUI_C_RESET"
    printf '  %s[4]%s library            %s[9]%s anomalies\n' "$c" "$NC_TUI_C_RESET" "$c" "$NC_TUI_C_RESET"
    printf '  %s[5]%s bench latency      %s[0]%s quit\n' "$c" "$NC_TUI_C_RESET" "$c" "$NC_TUI_C_RESET"
    printf '%s  [e] edit config   [a] aerials   [d] install idle daemon%s\n\n' "$d" "$NC_TUI_C_RESET"
}

nc_tui_pause() {
    printf '\n'
    read -r -p "Press Enter to continue..." _ || true
    printf '\n'
}

nc_tui_library() {
    local f="" sz="" meta=""
    printf '%sLibrary%s  %s\n' "$NC_TUI_C_BOLD" "$NC_TUI_C_RESET" "$NC_VIDEO_DIR"
    printf -- '--------------------------------------------------------------------------------\n'
    local -i n=0
    for f in "$NC_VIDEO_DIR"/*; do
        [ -f "$f" ] || continue
        n=$(( n + 1 ))
        sz="$(stat -c %s "$f" 2>/dev/null)" || sz=0
        meta=""
        if have ffprobe; then
            meta="$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=width,height:format=duration \
                -of default=nw=1:nk=1 -- "$f" 2>/dev/null | tr '\n' ' ')"
        fi
        printf '%2d. %-46s %8s  %s\n' "$n" "$(nc_tui_short_path "$f")" \
            "$(nc_tui_human_bytes "$sz")" "$meta"
    done
    if [ "$n" -eq 0 ]; then
        printf '  (empty)\n'
        printf '  Fill it with: %s aerials --sync\n' "$NC_APP"
    else
        printf '\n%d file(s)\n' "$n"
    fi
    printf '\n'
}

nc_tui_anomalies() {
    nc_anomalies_cmd --limit 12
    printf '\n'
}

# ------------------------------------------------------------------ loop

nc_tui_cleanup() {
    local t="$NC_TUI_C_RESET"
    printf '%s\033[?25h\033[?1049l' "$t" 2>/dev/null
    return 0
}

nc_tui_main() {
    if ! nc_tui_have_tty; then
        nc_die "tui butuh terminal interaktif. Pakai: $NC_APP --help" "$NC_EXIT_USAGE"
    fi

    nc_tui_setup_colors
    trap 'nc_tui_cleanup; exit 130' INT
    trap 'nc_tui_cleanup; exit 143' TERM
    trap 'nc_tui_cleanup' EXIT

    local choice
    while true; do
        clear 2>/dev/null || printf '\033[H\033[2J\033[3J'
        nc_tui_banner
        nc_tui_status_card
        nc_tui_menu

        choice=""
        read -r choice || break

        case "$choice" in
            1)
                if nc_is_running; then
                    nc_cmd_stop
                else
                    nc_cmd_start
                fi
                nc_tui_pause
                ;;
            2) nc_cmd_next >/dev/null 2>&1; nc_tui_pause ;;
            3) nc_cmd_prev >/dev/null 2>&1; nc_tui_pause ;;
            4) nc_tui_library; nc_tui_pause ;;
            5) nc_cmd_bench --runs 5; nc_tui_pause ;;
            6) nc_cmd_doctor; nc_tui_pause ;;
            7) nc_cmd_check; nc_tui_pause ;;
            8) nc_tui_watch_once; nc_tui_pause ;;
            9) nc_tui_anomalies; nc_tui_pause ;;
            e)
                ${EDITOR:-nano} "$NC_CONFIG_FILE" 2>/dev/null || printf 'set EDITOR first\n'
                nc_tui_pause
                ;;
            a) nc_cmd_aerials; nc_tui_pause ;;
            d) nc_cmd_install; nc_tui_pause ;;
            0 | q | Q | exit | quit) break ;;
            "") ;;
            *)
                printf 'Unknown choice: %s\n' "$choice"
                nc_msleep 700
                ;;
        esac
    done
    return "$NC_EXIT_OK"
}

# ------------------------------------------------------------------ watch

nc_tui_watch_once() {
    clear 2>/dev/null || printf '\033[H\033[2J'
    nc_tui_banner

    local -i i=0
    local -a vals=()
    if nc_is_running; then
        local start_ts=""
        start_ts="$(nc_read_pid "$NC_PIDFILE" 2>/dev/null)" || start_ts=""
        local boot
        boot="$(awk '{print int($22/100)}' "/proc/stat" 2>/dev/null)" || boot=""
        printf '%sLive:%s\n' "$NC_TUI_C_BOLD" "$NC_TUI_C_RESET"
        nc_tui_card "uptime" "$(nc_tui_human_duration $(( ${EPOCHSECONDS:-0} - ${start_ts:-0} )))" "$NC_TUI_C_GREEN"
        nc_tui_card "media" "$(nc_tui_short_path "$(nc_current_media 2>/dev/null)")"
        local p v
        for p in hwdec-current video-params/w video-params/h estimated-display-fps dropped-frames; do
            v="$(nc_ipc_property "$(nc_ipc_sock_for 0)" "$p" 0.4 2>/dev/null)"
            [ -n "$v" ] && vals+=("$p=$v")
        done
        for i in "${!vals[@]}"; do
            nc_tui_card "${vals[i]%%=*}" "${vals[i]#*=}"
        done
        [ -n "$boot" ] || boot=0
    else
        printf '%sLive:%s\n' "$NC_TUI_C_BOLD" "$NC_TUI_C_RESET"
        nc_tui_card "screensaver" "stopped" "$NC_TUI_C_DIM"
    fi
    printf '\n'
    nc_tui_status_card
}

nc_tui_watch() {
    if ! nc_tui_have_tty; then
        nc_die "watch butuh terminal. Pakai: $NC_APP watch" "$NC_EXIT_USAGE"
    fi
    nc_tui_setup_colors
    trap 'nc_tui_cleanup; exit 130' INT
    trap 'nc_tui_cleanup; exit 143' TERM
    trap 'nc_tui_cleanup' EXIT

    local -i interval=2
    while true; do
        nc_tui_watch_once
        printf '%sCtrl-C untuk keluar%s' "$NC_TUI_C_DIM" "$NC_TUI_C_RESET"
        nc_msleep $(( interval * 1000 )) 2>/dev/null || sleep 2
    done
}
