# shellcheck shell=bash
#
# noctoprevi - IPC JSON mpv lewat Unix Domain Socket (FR-04).
#
# Semua perintah dikirim sebagai satu baris JSON ke
# $XDG_RUNTIME_DIR/noctoprevi.sock yang dibuat oleh mpv --input-ipc-server.

NC_IPC_REQID=0

nc_ipc_next_reqid() {
    NC_IPC_REQID=$(( (NC_IPC_REQID + 1) % 100000 ))
    printf '%s' "$NC_IPC_REQID"
}

nc_ipc_sock_for() {
    local idx="${1:-0}"
    if [ "$idx" -eq 0 ]; then
        printf '%s' "$NC_SOCK"
    else
        printf '%s.%s.sock' "${NC_SOCK%.sock}" "$idx"
    fi
}

nc_ipc_sock_exists() {
    [ -S "${1:-}" ]
}

nc_ipc_socat() {
    nc_have socat
}

nc_ipc_send() {
    local sock="$1" payload="$2" timeout="${3:-0.5}"
    nc_ipc_socat || return 127
    nc_ipc_sock_exists "$sock" || return 1
    printf '%s\n' "$payload" |
        socat -u -t0.1 -T"$timeout" - "UNIX-CONNECT:$sock" 2>/dev/null
}

nc_ipc_request() {
    local sock="$1" payload="$2" timeout="${3:-1.0}"
    nc_ipc_socat || return 127
    nc_ipc_sock_exists "$sock" || return 1
    printf '%s\n' "$payload" |
        socat -t"$timeout" - "UNIX-CONNECT:$sock" 2>/dev/null
}

nc_ipc_cmd() {
    local sock="$1"
    local json="$2"
    local reqid resp payload
    reqid="$(nc_ipc_next_reqid)"
    payload="{\"command\":$json,\"request_id\":$reqid}"
    resp="$(nc_ipc_request "$sock" "$payload" "${NC_IPC_TIMEOUT:-1.0}")" || return 1
    case "$resp" in
        *'"error":"success"'*) return 0 ;;
        *) return 1 ;;
    esac
}

nc_ipc_quit() {
    local sock="$1"
    nc_ipc_send "$sock" '{"command":["quit"]}' "${NC_IPC_QUIT_TIMEOUT:-0.3}"
}

nc_ipc_loadfile() {
    local sock="$1" file="$2"
    nc_ipc_cmd "$sock" "[\"loadfile\",$(nc_json_string "$file"),\"replace\"]"
}

nc_ipc_property() {
    local sock="$1" prop="$2" timeout="${3:-0.6}"
    local reqid resp
    reqid="$(nc_ipc_next_reqid)"
    resp="$(nc_ipc_request "$sock" \
        "{\"command\":[\"get_property\",$(nc_json_string "$prop")],\"request_id\":$reqid}" \
        "$timeout")" || return 1
    nc_ipc_extract_data "$resp"
}

nc_ipc_extract_data() {
    local resp="${1:-}"
    [ -n "$resp" ] || return 1
    case "$resp" in
        *'"error":"success"'*) ;;
        *) return 1 ;;
    esac
    if nc_have jq; then
        printf '%s' "$resp" | jq -r '.data // empty' 2>/dev/null
        return $?
    fi
    local rest="${resp#*\"data\":}"
    [ "$rest" != "$resp" ] || return 1
    case "$rest" in
        '"'*'"')
            rest="${rest#\"}"
            printf '%s' "${rest%%\"*}"
            ;;
        *)
            printf '%s' "$rest"
            ;;
    esac
    return 0
}

nc_ipc_wait_ready() {
    local sock="$1" budget_ms="${2:-3000}"
    local -i waited=0 probe=0
    local step_ms=5 probe_budget=40

    while [ "$waited" -lt "$budget_ms" ]; do
        if [ -S "$sock" ]; then
            break
        fi
        nc_msleep "$step_ms"
        waited=$(( waited + step_ms ))
    done
    [ -S "$sock" ] || return 1

    while [ "$waited" -lt "$budget_ms" ] && [ "$probe" -lt "$probe_budget" ]; do
        if nc_ipc_property "$sock" "idle-active" "0.25" >/dev/null 2>&1; then
            return 0
        fi
        nc_msleep "$step_ms"
        waited=$(( waited + step_ms ))
        probe=$(( probe + 1 ))
    done
    return 1
}
