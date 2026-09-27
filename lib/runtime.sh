# shellcheck shell=bash
#
# noctoprevi - runtime: singleton, supervisor, dan siklus hidup.
#
# Model proses:
#   bin/noctoprevi __supervise            (memegang flock selama hidup)
#     └── mpv --input-ipc-server=<sock> --loop-file=inf <file>
#
# Supervisor memegang flock pada $RUNTIME/noctoprevi.lock selama hidup,
# sehingga deteksi "sudah jalan?" atomik dan tahan PID reuse. Bila mpv
# keluar dengan error sebelum sempat memutar, supervisor mencoba file
# berikutnya (FR-02 graceful fallback) dengan batas RETRY_LIMIT kali.

NC_MAX_SOCKETS=8
NC_CHILD_PIDS=()

NC_LOCK_FD=200

nc_singleton_try_lock() {
    [ -d "$NC_RUNTIME_DIR" ] || mkdir -p "$NC_RUNTIME_DIR" 2>/dev/null
    { eval "exec ${NC_LOCK_FD}>\"\$NC_LOCKFILE\""; } 2>/dev/null || return 1
    flock -n "$NC_LOCK_FD" 2>/dev/null || return 1
    return 0
}

nc_lock_probe_free() {
    local rc
    (
        exec 9>"$NC_LOCKFILE" 2>/dev/null || exit 1
        flock -n 9 || exit 1
    ) >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ]
}

nc_is_running() {
    local pid
    pid="$(nc_read_pid "$NC_PIDFILE" 2>/dev/null)" || pid=""
    if [ -n "$pid" ] && nc_pid_alive "$pid"; then
        return 0
    fi
    if [ -e "$NC_SOCK" ]; then
        return 0
    fi
    if [ -e "$NC_LOCKFILE" ] && ! nc_lock_probe_free; then
        return 0
    fi
    return 1
}

nc_supervisor_pid() {
    nc_read_pid "$NC_PIDFILE"
}

nc_mpv_pid_file() {
    printf '%s.%s.pid' "${NC_PIDFILE%.pid}" "${1:-0}"
}

nc_inst_file() {
    printf '%s.instances' "${NC_PIDFILE%.pid}"
}

nc_mpv_pid() {
    nc_read_pid "$(nc_mpv_pid_file "${1:-0}")"
}

nc_current_media() {
    local v=""
    [ -r "$NC_MEDIA_FILE" ] || return 1
    IFS= read -r v <"$NC_MEDIA_FILE" 2>/dev/null
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

nc_instance_count() {
    local n
    n="$(nc_read_pid "$(nc_inst_file)")" || n=0
    [ "$n" -ge 0 ] && [ "$n" -le "$NC_MAX_SOCKETS" ] || n=0
    printf '%s' "$n"
}

nc_sock_is_stale() {
    local sock="$1"
    [ -e "$sock" ] || return 1
    nc_ipc_property "$sock" "idle-active" "0.2" >/dev/null 2>&1 && return 1
    return 0
}

nc_remove_runtime_files() {
    local -i n i
    n="$(nc_instance_count)"
    for (( i = 0; i <= n && i < NC_MAX_SOCKETS; i++ )); do
        rm -f "$(nc_ipc_sock_for "$i")" "$(nc_mpv_pid_file "$i")" 2>/dev/null
    done
    rm -f "$NC_PIDFILE" "$NC_INDEX_FILE" "$NC_MEDIA_FILE" "$(nc_inst_file)" 2>/dev/null
    return 0
}

nc_cleanup_stale() {
    local -i i n
    if [ "${1:-}" != "force" ] && nc_is_running; then
        return 0
    fi
    n="$(nc_instance_count)"
    [ "$n" -eq 0 ] && n=1
    for (( i = 0; i < n && i < NC_MAX_SOCKETS; i++ )); do
        local s
        s="$(nc_ipc_sock_for "$i")"
        if [ -e "$s" ] && nc_sock_is_stale "$s"; then
            rm -f "$s" 2>/dev/null
            nc_log_debug "socket basi dibersihkan: $s"
        fi
    done
    nc_remove_runtime_files
    return 0
}

nc_detect_outputs_wlr() {
    NC_OUTPUTS=()
    local raw="" line first cur=""

    raw="$(wlr-randr --json 2>/dev/null)" || raw=""
    if [ -n "$raw" ] && nc_have jq; then
        mapfile -t NC_OUTPUTS < <(printf '%s' "$raw" |
            jq -r '.[] | select(.enabled == true) | .name' 2>/dev/null)
        [ "${#NC_OUTPUTS[@]}" -gt 0 ] && return 0
        NC_OUTPUTS=()
    fi

    raw="$(wlr-randr 2>/dev/null)" || raw=""
    [ -n "$raw" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            ' '*) ;;
            '') cur=""; continue ;;
            *)
                read -r first _ <<<"$line"
                cur="$first"
                continue
                ;;
        esac
        case "$line" in
            *'Enabled: yes'*)
                [ -n "$cur" ] && NC_OUTPUTS+=("$cur")
                ;;
        esac
    done <<<"$raw"

    [ "${#NC_OUTPUTS[@]}" -gt 0 ]
}

nc_detect_outputs() {
    NC_OUTPUTS=()

    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && nc_have hyprctl; then
        local raw
        raw="$(hyprctl monitors -j 2>/dev/null)"
        if [ -n "$raw" ] && nc_have jq; then
            mapfile -t NC_OUTPUTS < <(printf '%s' "$raw" |
                jq -r '.[] | select(.disabled != true) | .name' 2>/dev/null)
        fi
    elif [ -n "${NIRI_SOCKET:-}" ] && nc_have niri; then
        local raw
        raw="$(niri msg --json outputs 2>/dev/null)"
        if [ -n "$raw" ] && nc_have jq; then
            mapfile -t NC_OUTPUTS < <(printf '%s' "$raw" |
                jq -r '(.outputs? // .)[] | select(.disabled != true)
                       | select(.logical != null) | .name // empty' 2>/dev/null)
        fi
    elif [ -n "${SWAYSOCK:-}" ] && nc_have swaymsg; then
        local raw
        raw="$(swaymsg -t get_outputs -r 2>/dev/null)"
        if [ -n "$raw" ] && nc_have jq; then
            mapfile -t NC_OUTPUTS < <(printf '%s' "$raw" |
                jq -r '.[] | .name' 2>/dev/null)
        fi
    fi

    if [ "${#NC_OUTPUTS[@]}" -eq 0 ] && nc_have wlr-randr; then
        nc_detect_outputs_wlr && return 0
    fi

    [ "${#NC_OUTPUTS[@]}" -gt 0 ] || return 1
    return 0
}

nc_build_mpv_argv() {
    local idx="$1" file="$2"
    local -a extra=()
    NC_ARGV=()

    NC_ARGV+=(--no-config)
    NC_ARGV+=(--no-terminal)
    NC_ARGV+=("--input-ipc-server=$(nc_ipc_sock_for "$idx")")
    NC_ARGV+=(--idle=no)
    NC_ARGV+=(--force-window=immediate)
    NC_ARGV+=(--no-keepaspect)
    NC_ARGV+=(--no-input-terminal)
    NC_ARGV+=(--osd-level="$NC_OSD_LEVEL")
    NC_ARGV+=(--really-quiet)

    [ "$NC_FULLSCREEN" -eq 1 ] && NC_ARGV+=(--fullscreen)
    [ "$NC_BORDER" -eq 1 ] || NC_ARGV+=(--no-border)

    case "$NC_AUDIO" in
        none | no | off | false) NC_ARGV+=(--no-audio) ;;
        *) NC_ARGV+=("--audio=$NC_AUDIO") ;;
    esac

    if [ -n "$NC_HWDEC" ] && [ "$NC_HWDEC" != "none" ]; then
        NC_ARGV+=("--hwdec=$NC_HWDEC")
    fi
    case "$NC_CURSOR_AUTOHIDE" in
        always) NC_ARGV+=(--cursor-autohide=always) ;;
        never) NC_ARGV+=(--cursor-autohide=never) ;;
    esac
    [ -n "$NC_LOOP_FILE" ] && NC_ARGV+=("--loop-file=$NC_LOOP_FILE")

    if [ -n "$NC_MPV_ARGS" ]; then
        set -f
        read -r -a extra <<<"$NC_MPV_ARGS"
        set +f
        [ "${#extra[@]}" -gt 0 ] && NC_ARGV+=("${extra[@]}")
    fi
    if [ -n "$NC_EXTRA_MPV_ARGS" ]; then
        set -f
        read -r -a extra <<<"$NC_EXTRA_MPV_ARGS"
        set +f
        [ "${#extra[@]}" -gt 0 ] && NC_ARGV+=("${extra[@]}")
    fi
    if [ -n "${NOCTOPREVI_TEST_ARGS:-}" ]; then
        set -f
        read -r -a extra <<<"$NOCTOPREVI_TEST_ARGS"
        set +f
        [ "${#extra[@]}" -gt 0 ] && NC_ARGV+=("${extra[@]}")
    fi

    NC_ARGV+=("$file")
    return 0
}

nc_resolve_mpv() {
    NC_MPV_BIN="${NOCTOPREVI_MPV:-}"
    if [ -n "$NC_MPV_BIN" ]; then
        if [ -x "$NC_MPV_BIN" ]; then
            return 0
        fi
        nc_log_error "NOCTOPREVI_MPV menunjuk binary yang tidak bisa jalan: $NC_MPV_BIN"
        return 1
    fi
    NC_MPV_BIN="$(nc_which mpv)"
    if [ -z "$NC_MPV_BIN" ] || [ ! -x "$NC_MPV_BIN" ]; then
        return 1
    fi
    return 0
}

nc_supervisor_on_exit() {
    nc_remove_runtime_files
    return 0
}

nc_supervisor_kill_children() {
    local -i i
    for (( i = 0; i < ${#NC_CHILD_PIDS[@]}; i++ )); do
        nc_pid_alive "${NC_CHILD_PIDS[i]}" || continue
        kill -TERM "${NC_CHILD_PIDS[i]}" 2>/dev/null
    done
    for (( i = 0; i < ${#NC_CHILD_PIDS[@]}; i++ )); do
        wait "${NC_CHILD_PIDS[i]}" 2>/dev/null
    done
    NC_CHILD_PIDS=()
    return 0
}

nc_supervisor_on_signal() {
    nc_log_debug "supervisor menerima sinyal, menghentikan anak mpv"
    nc_supervisor_kill_children
    exit 0
}

nc_supervise_main() {
    local -i i idx rc one dur t0 attempts=0
    local file="" previous="" sock
    local -a socks=()

    NC_CHILD_PIDS=()

    trap 'nc_supervisor_on_exit' EXIT
    trap 'nc_supervisor_on_signal' TERM INT HUP

    if ! nc_resolve_mpv; then
        nc_log_error "mpv tidak ditemukan di PATH"
        nc_log_error "pasang dengan: sudo pacman -S mpv"
        exit "$NC_EXIT_ERROR"
    fi

    printf '%s\n' "$$" >"$NC_PIDFILE" 2>/dev/null || {
        nc_log_error "tidak bisa menulis pidfile: $NC_PIDFILE"
        exit "$NC_EXIT_ERROR"
    }

    nc_cleanup_stale force
    printf '%s\n' "$$" >"$NC_PIDFILE" 2>/dev/null

    case "$NC_MONITOR_MODE" in
        all | per-monitor | permonitor)
            if nc_detect_outputs; then
                NC_MAX_INSTANCES="${#NC_OUTPUTS[@]}"
                [ "$NC_MAX_INSTANCES" -gt "$NC_MAX_SOCKETS" ] && NC_MAX_INSTANCES="$NC_MAX_SOCKETS"
            else
                nc_log_warn "MONITOR_MODE=$NC_MONITOR_MODE, output tidak terdeteksi -> 1 instance"
                NC_MAX_INSTANCES=1
            fi
            ;;
        *) NC_MAX_INSTANCES=1 ;;
    esac

    printf '%s\n' "$NC_MAX_INSTANCES" >"$(nc_inst_file)" 2>/dev/null
    nc_log_info "supervisor aktif (pid $$), instance=$NC_MAX_INSTANCES, mode=$NC_PLAYBACK_MODE, dir=$NC_VIDEO_DIR"

    while :; do
        file="$(nc_media_pick_from_order "$NC_ORDER_FILE" "$NC_INDEX_FILE" "$previous")"
        if [ -z "$file" ]; then
            nc_log_error "tidak ada media yang bisa diputar"
            nc_log_error "isi $NC_VIDEO_DIR dengan .mp4/.mkv/.webm/.mov, atau jalankan: $NC_APP aerials --sync"
            exit "$NC_EXIT_ERROR"
        fi

        if [ "$NC_VALIDATE_MEDIA" -eq 1 ] && ! nc_media_probe "$file"; then
            nc_log_warn "bukan video yang bisa dibaca, dilewati: $file"
            previous="$file"
            attempts=$(( attempts + 1 ))
            nc_media_write_index "$NC_INDEX_FILE" "$(( $(nc_media_read_index "$NC_INDEX_FILE") + 1 ))"
            if [ "$attempts" -gt "$NC_RETRY_LIMIT" ]; then
                nc_log_error "$attempts file tidak valid berturut-turut, keluar"
                exit "$NC_EXIT_ERROR"
            fi
            continue
        fi

        NC_CHILD_PIDS=()
        socks=()
        for (( idx = 0; idx < NC_MAX_INSTANCES; idx++ )); do
            sock="$(nc_ipc_sock_for "$idx")"
            rm -f "$sock" 2>/dev/null
            nc_build_mpv_argv "$idx" "$file"
            # mpv mewarisi stdout/stderr dari parent. Kalau parent memakai
            # pipe, proses mpv yang berumur panjang akan menahan pipe itu
            # tetap terbuka sehingga parent yang menunggu EOF bisa menggantung.
            # mpv sudah --really-quiet --no-terminal, jadi tidak ada output
            # yang hilang dengan dialihkan ke /dev/null.
            "$NC_MPV_BIN" "${NC_ARGV[@]}" >/dev/null 2>&1 &
            NC_CHILD_PIDS+=("$!")
            socks+=("$sock")
            printf '%s\n' "$!" >"$(nc_mpv_pid_file "$idx")" 2>/dev/null
        done

        printf '%s\n' "$file" >"$NC_MEDIA_FILE" 2>/dev/null
        nc_log_info "memutar (${NC_MAX_INSTANCES}x): $file"

        if nc_ipc_wait_ready "${socks[0]}" "$(( NC_STARTUP_GRACE_MS * 2 ))"; then
            nc_log_info "IPC siap: ${socks[0]}"
        else
            nc_log_warn "socket IPC belum merespons: ${socks[0]}"
        fi

        rc=0
        t0="${EPOCHSECONDS}"
        for (( idx = 0; idx < ${#NC_CHILD_PIDS[@]}; idx++ )); do
            wait "${NC_CHILD_PIDS[idx]}"
            one=$?
            if [ "$idx" -eq 0 ] || [ "$one" -ne 0 ]; then
                rc="$one"
            fi
        done
        dur=$(( ${EPOCHSECONDS} - t0 ))

        nc_supervisor_kill_children
        for (( idx = 0; idx < ${#socks[@]}; idx++ )); do
            rm -f "${socks[idx]}" "$(nc_mpv_pid_file "$idx")" 2>/dev/null
        done
        rm -f "$NC_MEDIA_FILE" 2>/dev/null

        if [ "$rc" -eq 0 ]; then
            nc_log_info "mpv keluar normal, screensaver selesai"
            exit 0
        fi
        if [ "$rc" -ge 128 ] && [ "$rc" -le 192 ]; then
            nc_log_debug "dihentikan oleh sinyal (rc=$rc)"
            exit 0
        fi

        attempts=$(( attempts + 1 ))
        previous="$file"
        if [ "$attempts" -gt "$NC_RETRY_LIMIT" ]; then
            nc_log_error "mpv gagal $attempts kali berturut-turut (rc=$rc), keluar"
            exit "$NC_EXIT_ERROR"
        fi
        if [ "$(( dur * 1000 ))" -lt "$NC_STARTUP_GRACE_MS" ]; then
            nc_log_warn "mpv gagal setelah ${dur}ms (rc=$rc), coba file berikutnya"
        else
            nc_log_warn "mpv berhenti setelah ${dur}s (rc=$rc), coba file berikutnya"
        fi
    done
}

nc_spawn_supervisor() {
    local self="$1"
    (
        trap - EXIT TERM INT HUP
        exec "$self" __supervise
    ) &
    printf '%s' "$!"
    disown 2>/dev/null
    return 0
}
