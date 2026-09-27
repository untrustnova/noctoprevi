# shellcheck shell=bash
#
# noctoprevi - implementasi perintah CLI.

nc_cmd_start() {
    local -i t0
    t0="$(nc_now_us)"

    if nc_is_running; then
        nc_log_debug "sudah aktif, start diabaikan"
        return "$NC_EXIT_RUNNING"
    fi
    if ! nc_lock_probe_free; then
        nc_log_warn "instance lain masih berjalan (lock aktif)"
        return "$NC_EXIT_RUNNING"
    fi

    nc_config_ext_array
    if [ ! -d "$NC_VIDEO_DIR" ]; then
        mkdir -p "$NC_VIDEO_DIR" 2>/dev/null
        nc_log_info "direktori video dibuat: $NC_VIDEO_DIR"
    fi

    nc_remove_runtime_files
    if ! nc_media_build_order "$NC_ORDER_FILE"; then
        nc_log_error "gagal menyusun playlist dari $NC_VIDEO_DIR"
        return "$NC_EXIT_ERROR"
    fi
    nc_media_write_index "$NC_INDEX_FILE" 0

    if ! nc_singleton_try_lock; then
        nc_log_warn "lock tidak bisa diambil, instance lain aktif"
        return "$NC_EXIT_RUNNING"
    fi

    nc_spawn_supervisor "${NC_SELF:?}" >/dev/null

    local -i waited=0 sup_pid
    while [ "$waited" -lt 600 ]; do
        sup_pid="$(nc_read_pid "$NC_PIDFILE" 2>/dev/null)" || sup_pid=""
        if [ -n "$sup_pid" ] && nc_pid_alive "$sup_pid"; then
            break
        fi
        nc_msleep 10
        waited=$(( waited + 10 ))
    done

    if [ -z "$sup_pid" ] || ! nc_pid_alive "$sup_pid"; then
        nc_log_error "supervisor gagal start (tidak melaporkan pid hidup)"
        eval "exec ${NC_LOCK_FD}>&-" 2>/dev/null
        nc_remove_runtime_files
        return "$NC_EXIT_ERROR"
    fi

    nc_msleep 30
    if ! nc_pid_alive "$sup_pid"; then
        nc_log_error "supervisor langsung mati setelah start, lihat pesan di atas"
        eval "exec ${NC_LOCK_FD}>&-" 2>/dev/null
        nc_remove_runtime_files
        return "$NC_EXIT_ERROR"
    fi

    if ! nc_ipc_wait_ready "$NC_SOCK" "$(( NC_STARTUP_GRACE_MS * 2 ))"; then
        nc_log_warn "mpv belum siap menerima IPC, cek LOG_LEVEL=debug"
    fi

    nc_log_info "screensaver aktif dalam $(nc_elapsed_ms "$t0")ms"
    return "$NC_EXIT_OK"
}

nc_stop_pids_gone() {
    local -i i
    for i in "${@}"; do
        nc_pid_alive "$i" && return 1
    done
    return 0
}

nc_cmd_stop() {
    local -i t0 t_visible t_total i waited
    t0="$(nc_now_us)"

    local -a pids=() socks=() live=()
    local sup="" mp
    local -i n

    sup="$(nc_supervisor_pid 2>/dev/null)" || sup=""
    n="$(nc_instance_count)"
    [ "$n" -lt 1 ] && n=1
    for (( i = 0; i < n && i < NC_MAX_SOCKETS; i++ )); do
        socks+=("$(nc_ipc_sock_for "$i")")
        mp="$(nc_mpv_pid "$i" 2>/dev/null)" || mp=""
        [ -n "$mp" ] && pids+=("$mp")
    done

    if [ -z "$sup" ] && [ "${#pids[@]}" -eq 0 ]; then
        nc_log_debug "tidak aktif"
        return "$NC_EXIT_NOT_RUNNING"
    fi

    for i in "${!socks[@]}"; do
        nc_ipc_quit "${socks[i]}" &
    done

    for i in "${pids[@]}"; do
        nc_pid_alive "$i" && live+=("$i")
    done

    if [ "${#live[@]}" -eq 0 ]; then
        t_visible="$(nc_now_us)"
    else
        waited=0
        while [ "$waited" -lt "$NC_STOP_IPC_WAIT_MS" ] &&
            ! nc_stop_pids_gone "${live[@]}"; do
            nc_msleep 5
            waited=$(( waited + 5 ))
        done

        if ! nc_stop_pids_gone "${live[@]}"; then
            nc_log_debug "IPC quit belum selesai dalam ${NC_STOP_IPC_WAIT_MS}ms, eskalasi ke SIGTERM"
            for i in "${live[@]}"; do
                kill -TERM "$i" 2>/dev/null
            done
            waited=0
            while [ "$waited" -lt 80 ] && ! nc_stop_pids_gone "${live[@]}"; do
                nc_msleep 5
                waited=$(( waited + 5 ))
            done
        fi

        if ! nc_stop_pids_gone "${live[@]}"; then
            nc_log_debug "paksa: SIGKILL"
            for i in "${live[@]}"; do
                kill -KILL "$i" 2>/dev/null
            done
            waited=0
            while [ "$waited" -lt 40 ] && ! nc_stop_pids_gone "${live[@]}"; do
                nc_msleep 5
                waited=$(( waited + 5 ))
            done
        fi

        t_visible="$(nc_now_us)"
    fi

    if [ -n "$sup" ]; then
        waited=0
        while [ "$waited" -lt 60 ] && nc_pid_alive "$sup"; do
            nc_msleep 5
            waited=$(( waited + 5 ))
        done
        nc_pid_alive "$sup" && kill -KILL "$sup" 2>/dev/null
    fi

    nc_remove_runtime_files
    rm -f "$NC_ORDER_FILE" 2>/dev/null

    t_total="$(nc_now_us)"
    nc_log_debug "stop: layar bersih dalam $(nc_us_to_ms "$(( t_visible - t0 ))")ms, total $(nc_us_to_ms "$(( t_total - t0 ))")ms"
    return "$NC_EXIT_OK"
}

nc_cmd_toggle() {
    if nc_is_running; then
        nc_cmd_stop
        return $?
    fi
    nc_cmd_start
    return $?
}

nc_cmd_switch() {
    local direction="${1:-1}"

    if ! nc_is_running; then
        nc_log_error "screensaver tidak aktif"
        return "$NC_EXIT_ERROR"
    fi

    local -a socks=()
    local -i i n ok=0
    n="$(nc_instance_count)"
    [ "$n" -lt 1 ] && n=1
    for (( i = 0; i < n && i < NC_MAX_SOCKETS; i++ )); do
        socks+=("$(nc_ipc_sock_for "$i")")
    done

    local current target
    current="$(nc_ipc_property "${socks[0]}" "path" 0.5 2>/dev/null)" || current=""
    [ -n "$current" ] || current="$(nc_current_media 2>/dev/null)" || current=""

    if [ -n "$current" ]; then
        target="$(nc_media_advance "$NC_ORDER_FILE" "$NC_INDEX_FILE" "$direction")" || target=""
    else
        target="$(nc_media_pick_from_order "$NC_ORDER_FILE" "$NC_INDEX_FILE" "")" || target=""
    fi

    if [ -z "$target" ]; then
        nc_log_error "tidak ada media untuk dipindah"
        return "$NC_EXIT_ERROR"
    fi

    for i in "${!socks[@]}"; do
        if nc_ipc_loadfile "${socks[i]}" "$target"; then
            ok=$(( ok + 1 ))
        else
            nc_log_warn "loadfile gagal untuk ${socks[i]}"
        fi
    done

    if [ "$ok" -eq 0 ]; then
        nc_log_error "semua instance gagal pindah ke $target"
        return "$NC_EXIT_ERROR"
    fi

    printf '%s\n' "$target" >"$NC_MEDIA_FILE" 2>/dev/null
    if [ "$direction" -ge 0 ]; then
        nc_log_info "clip berikutnya: $target"
    else
        nc_log_info "clip sebelumnya: $target"
    fi
    printf '%s\n' "$target"
    return "$NC_EXIT_OK"
}

nc_cmd_next() {
    nc_cmd_switch 1
}

nc_cmd_prev() {
    nc_cmd_switch -1
}

nc_cmd_status() {
    local quiet=0
    [ "${1:-}" = "--quiet" ] || [ "${1:-}" = "-q" ] && quiet=1

    if ! nc_is_running; then
        [ "$quiet" -eq 1 ] || printf '%s: tidak aktif\n' "$NC_APP"
        return "$NC_EXIT_NOT_RUNNING"
    fi

    local sup media
    sup="$(nc_supervisor_pid 2>/dev/null)" || sup="?"
    media="$(nc_current_media 2>/dev/null)" || media="(tidak diketahui)"

    if [ "$quiet" -eq 1 ]; then
        printf '%s\n' "$sup"
        return "$NC_EXIT_RUNNING"
    fi

    printf '%s: aktif\n' "$NC_APP"
    printf '  supervisor : %s\n' "$sup"
    printf '  instance   : %s\n' "$(nc_instance_count)"
    printf '  media      : %s\n' "$media"
    printf '  socket     : %s\n' "$NC_SOCK"
    printf '  config     : %s\n' "$NC_CONFIG_FILE"
    printf '  video dir  : %s\n' "$NC_VIDEO_DIR"
    printf '  hwdec      : %s\n' "$NC_HWDEC"
    return "$NC_EXIT_RUNNING"
}
