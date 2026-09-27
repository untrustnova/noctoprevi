# shellcheck shell=bash
#
# noctoprevi - perintah `anomalies`: baca dan rangkum lapisan anomali.
#
# Dipakai tanpa TTY supaya bisa dipanggil dari skrip, alias, atau piping ke
# alat lain. TUI di lib/tui.sh memakai lapisan yang sama, bukan log terpisah.

nc_anomalies_usage() {
    cat <<EOF
Pakai: $NC_APP anomalies [opsi]

Menampilkan anomali yang tercatat. Anomali adalah kejadian yang tidak
biasa: file media ditolak, eskalasi stop, hwdec jatuh ke software, dan
sebagainya. Setiap baris punya kode, tingkat severity, dan hint tentang
apa yang harus dicoba.

OPSI
  -n, --limit N     Tampilkan N baris terakhir (default 20)
      --sev LIST    Filter severity, pisahkan koma: info,warn,error,security
      --code LIST   Filter kode, pisahkan koma. Lihat --codes
      --since SEC   Hanya 24 jam terakhir (default), atau "all"
      --json        Keluarkan NDJSON apa adanya (untuk di-pipe)
      --counts      Hanya ringkasan per kode
      --health      Hanya health score 0-100
      --codes       Daftar kode yang dikenal beserta artinya
      --clear       Hapus semua catatan
  -h, --help        Bantuan ini

CONTOH
  $NC_APP anomalies --limit 5
  $NC_APP anomalies --sev error,security --since all
  $NC_APP anomalies --code STOP_ESCALATED --counts
  journalctl --user -t $NC_APP | grep WARN
EOF
}

nc_anomaly_sev_label() {
    case "$1" in
        error) printf 'ERROR   ' ;;
        security) printf 'SECURITY' ;;
        warn) printf 'WARN    ' ;;
        info) printf 'INFO    ' ;;
        *) printf '%-8s' "$1" ;;
    esac
}

nc_anomaly_severity_rank() {
    case "$1" in
        security) printf '0' ;;
        error) printf '1' ;;
        warn) printf '2' ;;
        info) printf '3' ;;
        *) printf '9' ;;
    esac
}

nc_anomalies_print_codes() {
    local c
    printf 'Kode yang dikenal:\n\n'
    for c in $NC_ANOMALY_CODES; do
        printf '  %-24s %s\n' "$c" "$(nc_anomaly_hint_for_code "$c" | cut -c1-60)"
    done
}

nc_anomalies_cmd() {
    local -i limit=20
    local sev="" code="" since="86400" mode="list"
    local -a raw=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -n | --limit)
                case "${2:-}" in
                    '' | *[!0-9]*) limit=20 ;;
                    *) limit="$2" ;;
                esac
                shift 2
                ;;
            --sev)
                sev="${2:-}"
                shift 2
                ;;
            --code)
                code="${2:-}"
                shift 2
                ;;
            --since)
                since="$2"
                shift 2
                ;;
            --json) mode="json"; shift ;;
            --counts) mode="counts"; shift ;;
            --health) mode="health"; shift ;;
            --codes) mode="codes"; shift ;;
            --clear) mode="clear"; shift ;;
            -h | --help)
                nc_anomalies_usage
                return "$NC_EXIT_OK"
                ;;
            *) nc_die "opsi tidak dikenal: $1" "$NC_EXIT_USAGE" ;;
        esac
    done

    case "$since" in
        all | none | 0) since="" ;;
        '' | *[!0-9]*)
            case "$since" in
                *h) since=$(( ${since%h} * 3600 )) ;;
                *m) since=$(( ${since%m} * 60 )) ;;
                *d) since=$(( ${since%d} * 86400 )) ;;
                *) since=86400 ;;
            esac
            ;;
    esac
    [ -n "$since" ] && since=$(( ${EPOCHSECONDS:-0} - since ))

    case "$mode" in
        codes)
            nc_anomalies_print_codes
            return "$NC_EXIT_OK"
            ;;
        clear)
            nc_anomaly_clear
            nc_log_info "catatan anomali dihapus"
            return "$NC_EXIT_OK"
            ;;
        health)
            nc_anomaly_health
            printf '\n'
            return "$NC_EXIT_OK"
            ;;
        counts)
            local line n code
            local -i found=0
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                found=1
                n="${line%% *}"
                n="${n// /}"
                code="${line#* }"
                code="${code#"${code%%[![:space:]]*}"}"
                printf '  %6s  %s\n' "$n" "$code"
            done < <(nc_anomaly_summary)
            [ "$found" -eq 0 ] && printf 'Tidak ada anomali tercatat.\n'
            return "$NC_EXIT_OK"
            ;;
        json)
            mapfile -t raw < <(nc_anomaly_select "$(nc_anomaly_file)" \
                ${sev:+--sev "$sev"} ${code:+--code "$code"} ${since:+--since "$since"})
            if [ "${#raw[@]}" -gt "$limit" ]; then
                raw=("${raw[@]: -limit}")
            fi
            [ "${#raw[@]}" -gt 0 ] && printf '%s\n' "${raw[@]}"
            return "$NC_EXIT_OK"
            ;;
    esac

    mapfile -t raw < <(nc_anomaly_select "$(nc_anomaly_file)" \
        ${sev:+--sev "$sev"} ${code:+--code "$code"} ${since:+--since "$since"})

    if [ "${#raw[@]}" -eq 0 ]; then
        printf 'Tidak ada anomali%s.\n' \
            "$([ -n "$sev" ] || [ -n "$code" ] && printf ' yang cocok filter' || printf ' dalam 24 jam terakhir')"
        printf 'Lihat semua: %s anomalies --since all\n' "$NC_APP"
        return "$NC_EXIT_OK"
    fi

    local total health
    total="$(nc_anomaly_total)"
    health="$(nc_anomaly_health)"

    printf '%s anomali (%s total, health %s/100)\n' \
        "${#raw[@]}" "$total" "$health"
    printf -- '--------------------------------------------------------------------------------\n'

    local -i i start=$(( ${#raw[@]} - limit ))
    [ "$start" -lt 0 ] && start=0

    local line sev_of code_of msg_of hint_of ts_of
    for (( i = start; i < ${#raw[@]}; i++ )); do
        line="${raw[i]}"
        sev_of="$(nc_anomaly_field "$line" sev)"
        code_of="$(nc_anomaly_field "$line" code)"
        msg_of="$(nc_anomaly_field "$line" msg)"
        hint_of="$(nc_anomaly_field "$line" hint)"
        ts_of="$(nc_anomaly_field_ts "$line")"

        if [ "${NC_TUI_COLOR:-0}" = "1" ]; then
            local col reset
            reset=$'\033[0m'
            case "$sev_of" in
                error) col=$'\033[31m' ;;
                security) col=$'\033[35m' ;;
                warn) col=$'\033[33m' ;;
                *) col=$'\033[2m' ;;
            esac
            printf '%s%s%s %s\n' "$col" "$(nc_anomaly_sev_label "$sev_of")" "$reset" "$code_of"
        else
            printf '%s %s\n' "$(nc_anomaly_sev_label "$sev_of")" "$code_of"
        fi
        printf '  %s\n' "$msg_of"
        [ -n "$hint_of" ] && printf '  -> %s\n' "$hint_of"
        printf '  ts=%s\n' "$ts_of"
        [ "$i" -lt $(( ${#raw[@]} - 1 )) ] && printf '\n'
    done
    return "$NC_EXIT_OK"
}
