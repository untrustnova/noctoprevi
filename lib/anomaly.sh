# shellcheck shell=bash
#
# noctoprevi - lapisan anomali terstruktur.
#
# Log manusia (nc_log_*) dibaca berurutan dan hanya berisi yang enak dibaca.
# Anomali di sini ditulis sebagai NDJSON: satu objek per baris, dengan kode
# yang stabil, tingkat severity, dan - yang paling penting - hint berupa
# langkah konkret yang bisa dijalankan.
#
# Kenapa tidak pakai log teks saja: TUI (atau skrip, atau alias) tidak bisa
# menghitung "berapa kali eskalasi stop terjadi sejam terakhir" kalau itu cuma
# prosa. Kode stabil + NDJSON membuatnya bisa dihitung, ditrending, dan
# difilter.
#
# Berkas: $XDG_STATE_HOME/noctoprevi/anomalies.ndjson

NC_SEV_INFO="info"
NC_SEV_WARN="warn"
NC_SEV_ERROR="error"
NC_SEV_SECURITY="security"

# Nama file saja untuk ctx: path penuh membocorkan struktur direktori
# pengguna ke log yang sering di-pipe ke issue tracker.
nc_anomaly_basename() {
    local p="${1:-}"
    p="${p##*/}"
    printf '%s' "$p"
}

nc_anomaly_file() {
    if [ -n "${NC_ANOMALY_FILE:-}" ]; then
        printf '%s' "${NC_ANOMALY_FILE}"
        return 0
    fi
    printf '%s/anomalies.ndjson' "$NC_STATE_DIR"
}

# Daftar kode yang dip program's Suggestion. Dipakai juga sebagai daftar
# resmi: kode yang tidak ada di sini akan dianggap tidak dikenal saat
# `anomalies --codes`.
# Daftar kode yang dikenal program. Dipakai juga sebagai daftar resmi: kode yang
# tidak ada di sini dianggap tidak dikenal.
NC_ANOMALY_CODES="STOP_ESCALATED STOP_SLOW START_SLOW START_REFUSED SUPERVISOR_DIED \
MEDIA_REJECTED MEDIA_EMPTY_DIR MEDIA_RETRY MPV_GAVE_UP HWDEC_FALLBACK \
CA_FINGERPRINT_MISMATCH CA_FETCH_FAILED ORPHAN_MPV LOCK_BUSY IPC_UNREACHABLE \
IDLE_TOO_SHORT SOCKET_PERMISSIONS"

nc_anomaly_known_code() {
    local code="$1" c
    for c in $NC_ANOMALY_CODES; do
        [ "$c" = "$code" ] && return 0
    done
    return 1
}

# Fallback hint kalau pemanggil tidak memberikan sendiri.
nc_anomaly_hint_for_code() {
    case "$1" in
        STOP_ESCALATED)
            printf 'Measure first: noctoprevi bench --escalation-sweep. A smaller STOP_IPC_WAIT_MS is usually faster.'
            ;;
        STOP_SLOW)
            printf 'Compare against the budget: raise STOP_GRACE_MS, or check whether the compositor is busy.'
            ;;
        START_SLOW)
            printf 'Usually VALIDATE_MEDIA=2 or a slow video dir. Time it with: time noctoprevi start'
            ;;
        START_REFUSED | LOCK_BUSY)
            printf 'Another instance is alive. Check: noctoprevi status'
            ;;
        SUPERVISOR_DIED)
            printf 'The supervisor exited on its own. Read the last log lines; then: noctoprevi start'
            ;;
        MEDIA_REJECTED)
            printf 'Undecodable or too short. Re-download, or set VALIDATE_MEDIA=1 to accept it anyway.'
            ;;
        MEDIA_EMPTY_DIR)
            printf 'Fill VIDEO_DIR, or run: noctoprevi aerials --sync'
            ;;
        MEDIA_RETRY | MPV_GAVE_UP)
            printf 'Run: noctoprevi check   to find out which file is broken.'
            ;;
        HWDEC_FALLBACK)
            printf 'GPU decoding fell back to software. Install the driver, or set HWDEC=vaapi / nvdec explicitly.'
            ;;
        CA_FINGERPRINT_MISMATCH)
            printf 'SECURITY: the Apple root CA did not match the pinned fingerprint. Investigate before retrying.'
            ;;
        CA_FETCH_FAILED)
            printf 'Could not fetch the Apple root CA. Check connectivity, or set AERIALS_CURL_ARGS=--cacert=...'
            ;;
        ORPHAN_MPV)
            printf 'An mpv process survived its supervisor. It has been cleaned up automatically.'
            ;;
        IPC_UNREACHABLE)
            printf 'The mpv control socket did not answer. Raise STARTUP_GRACE_MS, or check the log.'
            ;;
        IDLE_TOO_SHORT)
            printf 'Below ~120s the screen will flicker while you read. Raise IDLE_START_SEC.'
            ;;
        SOCKET_PERMISSIONS)
            printf 'The IPC socket is too permissive. Check the permissions of $XDG_RUNTIME_DIR.'
            ;;
        *)
            printf ''
            ;;
    esac
}

nc_anomaly_ensure_dir() {
    local dir="${NC_STATE_DIR:-}"
    [ -n "$dir" ] || return 1
    [ -d "$dir" ] && return 0
    mkdir -p "$dir" 2>/dev/null
}

# nc_anomaly_emit <sev> <code> <msg> [hint] [k=v ...]
nc_anomaly_emit() {
    local sev="$1" code="$2" msg="$3"
    local hint="${4:-}"
    shift 4 2>/dev/null || shift $#

    [ -n "$sev" ] && [ -n "$code" ] || return 1
    [ -n "$NC_ANOMALY_ENABLED" ] && [ "$NC_ANOMALY_ENABLED" != "0" ] || return 0

    nc_anomaly_known_code "$code" ||
        nc_log_debug "kode anomali tidak dikenal: $code"

    if [ -z "$hint" ]; then
        hint="$(nc_anomaly_hint_for_code "$code")"
    fi

    nc_anomaly_ensure_dir || return 1

    local ts line pair key val first=1
    ts="${EPOCHREALTIME:-0}"

    # nc_json_string sudah mengembalikan nilai BERKUTIP, jadi jangan dibungkus
    # tanda kutip lagi di sini.
    line="{\"ts\":$ts,\"sev\":$(nc_json_string "$sev")"
    line="$line,\"code\":$(nc_json_string "$code")"
    line="$line,\"msg\":$(nc_json_string "$msg")"
    line="$line,\"hint\":$(nc_json_string "$hint")"

    for pair in "$@"; do
        [ -n "$pair" ] || continue
        case "$pair" in
            *=*) ;;
            *) continue ;;
        esac
        key="${pair%%=*}"
        val="${pair#*=}"
        [ -n "$key" ] || continue
        if [ "$first" -eq 1 ]; then
            line="$line,\"ctx\":{"
            first=0
        else
            line="$line,"
        fi
        # nc_json_string sudah memberi tanda kutip untuk key DAN value, jadi
        # di sini tidak ada tanda kutip tambahan sama sekali.
        line="$line$(nc_json_string "$key"):$(nc_json_string "$val")"
    done
    # Dua kurung penutup kalau ada ctx (menutup ctx lalu objek), satu kalau tidak.
    if [ "$first" -eq 0 ]; then
        line="$line}}"
    else
        line="$line}"
    fi

    printf '%s\n' "$line" >>"$(nc_anomaly_file)" 2>/dev/null || return 1

    nc_anomaly_rotate
    nc_anomaly_maybe_notify "$sev" "$code" "$msg" "$hint"
    return 0
}

# Buang baris paling depan sampai jumlahnya di bawah batas. Satu generasi: file yang lama dipangkas, tanpa arsip bertingkat. Log screensaver
# tidak butuh riwayat yang lebih dalam.
nc_anomaly_rotate() {
    local file max lines
    file="$(nc_anomaly_file)"
    [ -f "$file" ] || return 0
    max="${NC_ANOMALY_MAX_LINES:-2000}"
    case "$max" in
        '' | *[!0-9]*) return 0 ;;
    esac
    [ "$max" -gt 0 ] || return 0

    lines="$(wc -l <"$file" 2>/dev/null)" || return 0
    lines="${lines// /}"
    case "$lines" in
        '' | *[!0-9]*) return 0 ;;
    esac
    [ "$lines" -gt "$max" ] || return 0

    local keep=$(( max / 2 ))
    [ "$keep" -ge 1 ] || keep=1
    tail -n "$keep" "$file" >"$file.tmp.$$" 2>/dev/null || {
        rm -f "$file.tmp.$$" 2>/dev/null
        return 0
    }
    mv -f "$file.tmp.$$" "$file" 2>/dev/null || rm -f "$file.tmp.$$" 2>/dev/null
    return 0
}

nc_anomaly_clear() {
    local file
    file="$(nc_anomaly_file)"
    [ -f "$file" ] || return 0
    : >"$file" 2>/dev/null
    return 0
}

# ------------------------------------------------------------------ notifikasi

nc_anomaly_notify_count_file() {
    printf '%s/anomaly-notify.count' "$NC_STATE_DIR"
}

# Kirim notifikasi desktop, tapi jangan lebih dari sekali per jendela waktu.
# Tanpa ini, satu error yang berulang tiap idle cycle akan membanjiri
# notifikasi.
nc_anomaly_maybe_notify() {
    local sev="$1" code="$2" msg="$3" hint="$4"
    [ "$NC_ANOMALY_NOTIFY" = "1" ] || return 0

    case "$sev" in
        error | security) ;;
        *) return 0 ;;
    esac
    nc_have notify-send || return 0

    local cf last now interval
    cf="$(nc_anomaly_notify_count_file)"
    interval="${NC_ANOMALY_NOTIFY_INTERVAL:-3600}"
    case "$interval" in
        '' | *[!0-9]*) interval=3600 ;;
    esac
    now="${EPOCHSECONDS:-0}"
    last="$(nc_read_pid "$cf" 2>/dev/null)" || last=""
    if [ -n "$last" ] && [ "$(( now - last ))" -lt "$interval" ] 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$now" >"$cf" 2>/dev/null

    local body="$msg"
    [ -n "$hint" ] && body="$msg  |  $hint"
    notify-send -a "noctoprevi" -u critical \
        --icon="$NC_APP" "noctoprevi: $code" "$body" >/dev/null 2>&1
    return 0
}

# ------------------------------------------------------------------ pembaca

nc_anomaly_total() {
    local file
    file="$(nc_anomaly_file)"
    [ -f "$file" ] || {
        printf '0'
        return 0
    }
    local n
    n="$(wc -l <"$file" 2>/dev/null)" || n=0
    n="${n// /}"
    printf '%s' "${n:-0}"
}

# Field dari satu baris NDJSON. Pakai jq kalau ada; kalau tidak,regex
# bash. Pesan bisa mengandung tanda kutip yang sudah di-escape, jadi regex
# dibuat tidak rakus (non-greedy via [^"]*).
nc_anomaly_field() {
    local line="$1" key="$2"
    if nc_have jq; then
        printf '%s' "$line" |
            jq -r --arg k "$key" '.[$k] // ""' 2>/dev/null
        return $?
    fi
    local re
    re="\"$key\":\"([^\"]*)\""
    if [[ "$line" =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf ''
    return 1
}

nc_anomaly_field_ts() {
    local line="$1"
    if nc_have jq; then
        printf '%s' "$line" | jq -r '.ts // 0' 2>/dev/null
        return $?
    fi
    if [[ "$line" =~ \"ts\":([0-9.]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf '0'
}

# Cetak baris yang cocok filter. Filter: severity (bisa diulang, dipisah
# koma) dan/atau kode, dan/atau since (unix epoch).
# Catatan: `local x` tanpa `=NIL` menyisakan variabel sebagai UNSET di bash,
# jadi `set -u` akan gagal saat dibaca. Semua local di file ini diberi nilai
# awal.
nc_anomaly_select() {
    local file="" sev_filter="" code_filter="" since=""
    local -i n=0
    # Argumen pertama adalah path berkas; sisanya filter. Kalau tidak di-shift
    # dulu, loop di bawah akan memakainya sebagai filter dan menggigit path-nya.
    [ "$#" -gt 0 ] && file="$1" && shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --sev)
                sev_filter="${sev_filter:+$sev_filter,}$2"
                shift 2
                ;;
            --code)
                code_filter="${code_filter:+$code_filter,}$2"
                shift 2
                ;;
            --since)
                since="$2"
                shift 2
                ;;
            --) shift ;;
            *) shift ;;
        esac
    done
    [ -f "$file" ] || return 0

    local line ts code sev keep
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -n "$sev_filter" ]; then
            sev="$(nc_anomaly_field "$line" sev)"
            case ",$sev_filter," in
                *",$sev,"*) ;;
                *) continue ;;
            esac
        fi
        if [ -n "$code_filter" ]; then
            code="$(nc_anomaly_field "$line" code)"
            case ",$code_filter," in
                *",$code,"*) ;;
                *) continue ;;
            esac
        fi
        if [ -n "$since" ]; then
            ts="$(nc_anomaly_field_ts "$line")"
            case "$ts" in
                '' | *[!0-9.]*) continue ;;
            esac
            awk -v a="$ts" -v b="$since" 'BEGIN{exit !(a+0 >= b+0)}' 2>/dev/null || continue
        fi
        printf '%s\n' "$line"
        n=$(( n + 1 ))
    done <"$file"
    return 0
}

# Ringkasan per kode: "CODE=count", diurut dari yang paling sering.
nc_anomaly_summary() {
    local file
    file="$(nc_anomaly_file)"
    [ -f "$file" ] || return 0

    local line code
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        code="$(nc_anomaly_field "$line" code)"
        [ -n "$code" ] || continue
        printf '%s\n' "$code"
    done <"$file" | sort | uniq -c | sort -rn
}

# 0..100, diturunkan dari jumlah anomali di jendela waktu. Mirip health score
# nocatoo supaya konsisten sebagai sinyal "sekali lihat".
nc_anomaly_health() {
    local file total
    file="$(nc_anomaly_file)"
    total="$(nc_anomaly_total)"

    if [ "$total" -eq 0 ]; then
        printf '100'
        return 0
    fi

    # Bobotnya disengaja: satu anomali security langsung terasa berat, info
    # tidak dihitung sama sekali supaya STOP_ESCALATED yang terjadi di setiap
    # stop tidak menarik health ke bawah tanpa alasan.
    local -A weight=([security]=40 [error]=10 [warn]=3 [info]=0)
    local score=0 line sev
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        sev="$(nc_anomaly_field "$line" sev)"
        score=$(( score + ${weight[$sev]:-1} ))
    done < <(nc_anomaly_select "$file" --since "$(( ${EPOCHSECONDS:-0} - 86400 ))")

    [ "$score" -le 0 ] && {
        printf '100'
        return 0
    }
    local health=$(( 100 - score ))
    [ "$health" -lt 0 ] && health=0
    printf '%s' "$health"
}

# Ringkasan satu baris untuk kartu status TUI.
nc_anomaly_recent_counts() {
    local file
    file="$(nc_anomaly_file)"
    local e w s
    e="$(nc_anomaly_select "$file" --sev error | grep -c . || true)"
    w="$(nc_anomaly_select "$file" --sev warn | grep -c . || true)"
    s="$(nc_anomaly_select "$file" --sev security | grep -c . || true)"
    printf '%s %s %s' "${e:-0}" "${w:-0}" "${s:-0}"
}
