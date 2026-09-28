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

# Animasi keluar: geser gambar ke luar pakai filter crop, beberapa langkah.
#
# Kenapa bertahap, bukan satu ekspresi `x=iw*t/0.2`: `t` pada filter mpv
# adalah PTS absolut video, bukan waktu sejak filter dipasang. Video yang
# sudah berjalan 5 menit akan langsung terlempar keluar layar. Mengirim
# beberapa langkah dengan offset yang kita hitung sendiri Deterministik dan
# tidak bergantung versi mpv.
#
# Koma DILARANG di dalam filter mpv - parser-nya memakai koma sebagai
# pemisah opsi, sehingga ekspresi `min(1,t/0.2)` ditolak dengan "error
# running command". Karena itu semua ekspresi di bawah bebas koma.
nc_ipc_slide() {
    local sock="$1" anim="$2" ms="$3"
    local -i steps=8 i off
    local filter=""

    # Mode dicek LEBIH DAHULU dari socket. Mode tak dikenal itu no-op yang
    # sah - bukan kegagalan - jadi tidak boleh berubah jadi error hanya
    # karena socket-nya sudah hilang.
    case "$anim" in
        slideleft | slideright | slideup | slidedown) ;;
        *)
            nc_log_debug "EXIT_ANIM tidak dikenal: '$anim' -> none"
            return 0
            ;;
    esac

    nc_ipc_socat || return 127
    nc_ipc_sock_exists "$sock" || return 1

    # Koma DILARANG di dalam filter mpv - parser-nya memakai koma sebagai
    # pemisah opsi, sehingga ekspresi `min(1,t/0.2)` ditolak dengan "error
    # running command". Semua filter di bawah bebas koma.

    local -i step_ms=$(( ms / steps ))
    [ "$step_ms" -lt 1 ] && step_ms=1

    # SATU socat untuk semua langkah. Versi yang spawn socat per langkah
    # menambah ~370ms; connect-nya yang mahal, bukan sleeps-nya. Jawaban
    # tidak dibutuhkan di tengah animasi, jadi socat dibuat dua arah dan
    # stdin-nya dis-feeding lewat FIFO supaya ritme Its bisa dikontrol.
    local fifo="${sock##*/}.exit.$$.fifo"
    rm -f "$fifo" 2>/dev/null
    mkfifo "$fifo" 2>/dev/null || return 1

    socat -u -t0.05 - "UNIX-CONNECT:$sock" <"$fifo" 2>/dev/null &
    local spid=$!
    # Membuka FIFO untuk tulis akan menunggu sampai socat membacanya, jadi
    # kedua sisipan ini harus berpasangan.
    exec 9>"$fifo" || {
        rm -f "$fifo" 2>/dev/null
        kill "$spid" 2>/dev/null
        return 1
    }

    for (( i = 1; i <= steps; i++ )); do
        case "$anim" in
            # meluncur ke kiri: jendela crop bergerak ke kanan
            slideleft) off="$i" ;;
            # meluncur ke kanan: jendela crop bergerak ke kiri
            slideright) off=$(( steps - i )) ;;
            # meluncur ke atas: jendela crop bergerak ke bawah
            slideup) off="$i" ;;
            slidedown) off=$(( steps - i )) ;;
        esac
        if [ "$anim" = "slideup" ] || [ "$anim" = "slidedown" ]; then
            filter="crop=w=iw:h=ih:x=0:y=ih*$off/$steps"
        else
            filter="crop=w=iw:h=ih:x=iw*$off/$steps:y=0"
        fi
        printf '{"command":["vf","set","@exit:%s"]}\n' "$filter" >&9
        nc_msleep "$step_ms"
    done

    exec 9>&-
    wait "$spid" 2>/dev/null
    rm -f "$fifo" 2>/dev/null
    return 0
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
