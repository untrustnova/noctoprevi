# shellcheck shell=bash
#
# noctoprevi - aerials: unduh koleksi screensaver Apple TV Aerial.
#
# Sumber resmi Apple: sylvan.apple.com/Aerials/resources-16.tar (metadata
# 2 MB) berisi entries.json dengan URL video per kualitas. Video sendiri
# diunduh sesuai --quality.

NC_AERIALS_MANIFEST_URL="https://sylvan.apple.com/Aerials/resources-16.tar"
NC_AERIALS_FALLBACK_URL="https://sylvan.apple.com/Aerials/resources.tar"

nc_aerials_quality_key() {
    case "$(nc_lower "${1:-$NC_AERIALS_QUALITY}")" in
        1080p | h264 | avc | compat) printf 'url-1080-H264' ;;
        1080p-hevc | 2k | 1080) printf 'url-1080-SDR' ;;
        1080p-hdr) printf 'url-1080-HDR' ;;
        4k | 4k-hevc | uhd) printf 'url-4K-SDR' ;;
        4k-hdr) printf 'url-4K-HDR' ;;
        *) printf 'url-1080-H264' ;;
    esac
}

nc_aerials_quality_label() {
    case "$(nc_aerials_quality_key "${1:-}")" in
        url-1080-H264) printf '1080p H.264' ;;
        url-1080-SDR) printf '1080p HEVC' ;;
        url-1080-HDR) printf '1080p HDR' ;;
        url-4K-SDR) printf '4K HEVC' ;;
        url-4K-HDR) printf '4K HDR' ;;
    esac
}

nc_aerials_slug() {
    local s
    s="$(nc_lower "$1")"
    s="${s//[^a-z0-9 ]/}"
    s="${s//  / }"
    s="${s// /_}"
    s="${s//_/_}"
    printf '%s' "${s:-aerial}"
}

nc_aerials_fetch_manifest() {
    local dest="$1" url
    nc_have curl || {
        nc_log_error "curl tidak ditemukan, perlu untuk mengunduh aerials"
        return "$NC_EXIT_ERROR"
    }
    local tmp="$dest.tmp"
    local err
    nc_aerials_curl_args
    for url in "${NC_AERIALS_MANIFEST_URL}" "$NC_AERIALS_FALLBACK_URL"; do
        nc_log_info "mengambil manifest: $url"
        if curl -fsSL --connect-timeout 15 --max-time 180 \
            "${NC_CURL_ARGS[@]}" -o "$tmp" "$url" 2>/dev/null; then
            if tar -xOf "$tmp" entries.json >"$dest" 2>/dev/null && [ -s "$dest" ]; then
                rm -f "$tmp" 2>/dev/null
                nc_log_info "manifest ok: $(wc -c <"$dest") byte"
                return 0
            fi
        fi
        rm -f "$tmp" 2>/dev/null
    done
    err="$(curl -sSL --connect-timeout 15 "${NC_CURL_ARGS[@]}" \
        -o /dev/null "$NC_AERIALS_MANIFEST_URL" 2>&1 >/dev/null)"
    nc_log_error "gagal mengambil manifest aerials dari server Apple"
    case "$err" in
        *certificate* | *SSL* | *issuer*)
            nc_log_error "kesalahan sertifikat TLS. Trust store sistem belum punya"
            nc_log_error "root CA Apple. Perbaiki dengan:"
            nc_log_error "  sudo pacman -S ca-certificates-mozilla"
            nc_log_error "atau set AERIALS_CURL_ARGS=--cacert=/path/ke/bundle.pem"
            ;;
        *)
            [ -n "$err" ] && nc_log_error "curl: $err"
            nc_log_error "cek koneksi internet, atau pakai proxy lewat AERIALS_CURL_ARGS"
            ;;
    esac
    return "$NC_EXIT_ERROR"
}

nc_aerials_list() {
    local manifest="$1" key
    key="$(nc_aerials_quality_key)"
    if ! nc_have jq; then
        nc_log_error "jq diperlukan untuk membaca manifest aerials"
        return "$NC_EXIT_ERROR"
    fi
    jq -r --arg k "$key" '
        .assets[]
        | select(.[$k] != null)
        | [ .accessibilityLabel, .[$k] ]
        | @tsv
    ' "$manifest" 2>/dev/null
}

nc_aerials_pick() {
    local manifest="$1" key want="$2" only
    key="$(nc_aerials_quality_key)"
    only=0
    case "$(nc_lower "$want")" in
        4k | 4k-hdr | 1080p | 1080p-hevc | 1080p-hdr | h264) only=1 ;;
    esac

    if [ "$only" -eq 1 ]; then
        jq -r --arg k "$key" '
            .assets[] | select(.[$k] != null) | .[$k]
        ' "$manifest" 2>/dev/null
        return 0
    fi

    jq -r --arg k "$key" --arg l "$want" '
        .assets[]
        | select(.[$k] != null)
        | select((.accessibilityLabel | ascii_downcase) | contains($l | ascii_downcase))
        | .[$k]
    ' "$manifest" 2>/dev/null
}

nc_aerials_curl_args() {
    NC_CURL_ARGS=()
    [ -n "${NC_AERIALS_CURL_ARGS:-}" ] || return 0
    local -a extra=()
    set -f
    read -r -a extra <<<"$NC_AERIALS_CURL_ARGS"
    set +f
    [ "${#extra[@]}" -gt 0 ] && NC_CURL_ARGS=("${extra[@]}")
    return 0
}

nc_aerials_download() {
    local url="$1" dest="$2"
    NC_CURL_ERR=""
    curl -fL --connect-timeout 20 --max-time 1800 \
        --retry 3 --retry-delay 2 --retry-connrefused \
        -C - -o "$dest" "${NC_CURL_ARGS[@]}" -- "$url" 2>"${NC_CURL_ERR_FILE:-/dev/null}"
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -n "${NC_CURL_ERR_FILE:-}" ] && [ -s "$NC_CURL_ERR_FILE" ]; then
        NC_CURL_ERR="$(tail -n 2 "$NC_CURL_ERR_FILE" 2>/dev/null | tr '\n' ' ')"
    fi
    return "$rc"
}

nc_aerials_fetch_head() {
    curl -sSLI --connect-timeout 20 "${NC_CURL_ARGS[@]}" -- "$1" 2>/dev/null
}

nc_aerials_worker() {
    local url="$1" dest="$2"
    local tmp="$dest.part"
    local errf="${TMPDIR:-/tmp}/.nco-aerials.$$.$RANDOM"
    if NC_CURL_ERR_FILE="$errf" nc_aerials_download "$url" "$tmp" && [ -s "$tmp" ]; then
        rm -f "$errf" 2>/dev/null
        if mv -f "$tmp" "$dest" 2>/dev/null; then
            printf 'OK\t%s\t%s\n' "$dest" "$(du -h "$dest" 2>/dev/null | cut -f1)"
            return 0
        fi
    fi
    rm -f "$tmp" 2>/dev/null
    if [ -s "$errf" ]; then
        printf 'FAIL\t%s\t%s\n' "$dest" \
            "$(tail -n 1 "$errf" 2>/dev/null | tr -d '\r' | cut -c1-120)"
    else
        printf 'FAIL\t%s\t-curl gagal tanpa pesan\n' "$dest"
    fi
    rm -f "$errf" 2>/dev/null
    return 1
}

nc_cmd_aerials() {
    local action="list" quality="" only="" dest_dir=""
    local -i jobs=3
    local -a pick=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --sync | sync | download) action="sync"; shift ;;
            --list | list) action="list"; shift ;;
            --quality | -q)
                quality="${2:-}"
                [ -n "$quality" ] && NC_AERIALS_QUALITY="$quality"
                shift 2
                ;;
            --quality=* | -q=*)
                NC_AERIALS_QUALITY="${1#*=}"
                shift
                ;;
            --only)
                only="${2:-}"
                shift 2
                ;;
            --only=*)
                only="${1#*=}"
                shift
                ;;
            --dest)
                dest_dir="${2:-}"
                shift 2
                ;;
            --dest=*)
                dest_dir="${1#*=}"
                shift
                ;;
            --jobs | -j)
                jobs="${2:-3}"
                shift 2
                ;;
            --jobs=* | -j=*)
                jobs="${1#*=}"
                shift
                ;;
            --curl-arg)
                NC_AERIALS_CURL_ARGS="${NC_AERIALS_CURL_ARGS:+$NC_AERIALS_CURL_ARGS }${2:-}"
                shift 2
                ;;
            --curl-arg=*)
                NC_AERIALS_CURL_ARGS="${NC_AERIALS_CURL_ARGS:+$NC_AERIALS_CURL_ARGS }${1#*=}"
                shift
                ;;
            -h | --help)
                printf 'Pakai: %s aerials <aksi> [opsi]\n' "$NC_APP"
                printf '\nAKSI\n'
                printf '  list            Tampilkan katalog clip yang tersedia\n'
                printf '  --sync          Unduh semua clip sesuai --quality\n'
                printf '\nOPSI\n'
                printf '  -q, --quality    1080p | 1080p-hevc | 1080p-hdr | 4k | 4k-hdr\n'
                printf '  --only "label"   Hanya clip yang namanya mengandung label\n'
                printf '  --dest DIR       Tujuan unduhan (default VIDEO_DIR)\n'
                printf '  -j, --jobs N     Jumlah unduhan paralel (default 3)\n'
                printf '  --curl-arg ARG   Argumen tambahan untuk curl (proxy, --cacert)\n'
                printf '\nCATATAN\n'
                printf '  Unduhan memakai server resmi Apple (sylvan.apple.com).\n'
                printf '  4K HEVC butuh GPU dengan decode HEVC; 1080p H.264 paling aman.\n'
                return "$NC_EXIT_OK"
                ;;
            *) shift ;;
        esac
    done

    nc_aerials_curl_args

    local manifest="$NC_STATE_DIR/aerials-entries.json"
    mkdir -p "$NC_STATE_DIR" 2>/dev/null
    [ -s "$manifest" ] || nc_aerials_fetch_manifest "$manifest" || return $?

    if [ "$action" = "list" ]; then
        printf 'Katalog Apple TV Aerial (%s), sumber: %s\n\n' \
            "$(nc_aerials_quality_label)" "$NC_AERIALS_MANIFEST_URL"
        nc_aerials_list "$manifest" | while IFS=$'\t' read -r label url; do
            printf '  %-40s %s\n' "$label" "$url"
        done
        return "$NC_EXIT_OK"
    fi

    dest_dir="${dest_dir:-$NC_AERIALS_DIR}"
    [ -n "$dest_dir" ] || dest_dir="$NC_VIDEO_DIR"
    mkdir -p "$dest_dir" 2>/dev/null || {
        nc_log_error "gagal membuat $dest_dir"
        return "$NC_EXIT_ERROR"
    }

    if [ -n "$only" ]; then
        mapfile -t pick < <(nc_aerials_pick "$manifest" "$only")
    else
        mapfile -t pick < <(jq -r --arg k "$(nc_aerials_quality_key)" \
            '.assets[] | select(.[$k] != null) | .[$k]' "$manifest" 2>/dev/null)
    fi

    if [ "${#pick[@]}" -eq 0 ]; then
        nc_log_error "tidak ada clip yang cocok untuk '$only'"
        return "$NC_EXIT_ERROR"
    fi

    printf 'Mengunduh %d clip (%s) ke %s\n' \
        "${#pick[@]}" "$(nc_aerials_quality_label)" "$dest_dir"
    printf 'Paralel: %s unduhan. File yang sudah ada dilewati. Ctrl-C untuk batal.\n\n' "$jobs"

    local -i ok=0 skip=0 fail=0 running=0
    local results="$NC_STATE_DIR/aerials.$$.results"
    : >"$results" 2>/dev/null
    local url base dest label

    for url in "${pick[@]}"; do
        [ -n "$url" ] || continue
        base="${url##*/}"
        label="$(nc_aerials_slug "${base%.mov}")"
        dest="$dest_dir/$label.mov"

        if [ -s "$dest" ]; then
            skip=$(( skip + 1 ))
            printf '  [skip] %s\n' "$label"
            continue
        fi

        printf '  [get ] %-40s\n' "$label"
        nc_aerials_worker "$url" "$dest" >>"$results" 2>/dev/null &
        running=$(( running + 1 ))

        while [ "$running" -ge "$jobs" ]; do
            wait -n 2>/dev/null || wait
            running=$(( running - 1 ))
        done
    done

    wait 2>/dev/null

    local st name size
    while IFS=$'\t' read -r st name size; do
        case "$st" in
            OK)
                ok=$(( ok + 1 ))
                printf '  [ ok ] %-38s %s\n' "$(nc_aerials_slug "${name%.mov}")" "$size"
                ;;
            *)
                fail=$(( fail + 1 ))
                printf '  [FAIL] %-38s %s\n' "$(nc_aerials_slug "${name%.mov}")" "$size"
                ;;
        esac
    done <"$results"
    rm -f "$results" 2>/dev/null

    printf '\nRingkasan: %d terunduh, %d dilewati, %d gagal\n' "$ok" "$skip" "$fail"
    printf 'Folder siap pakai: %s\n' "$dest_dir"
    if [ "$fail" -gt 0 ] || [ "$ok" -eq 0 ]; then
        return "$NC_EXIT_ERROR"
    fi
    return "$NC_EXIT_OK"
}
