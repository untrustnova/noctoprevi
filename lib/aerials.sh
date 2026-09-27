# shellcheck shell=bash
#
# noctoprevi - aerials: unduh koleksi screensaver Apple TV Aerial.
#
# Sumber resmi Apple: sylvan.apple.com/Aerials/resources-16.tar (metadata
# 2 MB) berisi entries.json dengan URL video per kualitas. Video sendiri
# diunduh sesuai --quality.

NC_AERIALS_MANIFEST_URL="https://sylvan.apple.com/Aerials/resources-16.tar"
NC_AERIALS_FALLBACK_URL="https://sylvan.apple.com/Aerials/resources.tar"

# Apple Root CA tidak ada di trust list Mozilla mana pun - termasuk bundle
# resmi curl.se. sylvan.apple.com menantai ke root privat itu, jadi curl gagal
# dengan error (60) di semua distro.
#
# Solusinya: root yang sama dipublikasikan Apple di www.apple.com, dan host itu
# memakai TLS publik yang sudah tepercaya. Jadi kita ambil root lewat trust
# store sistem (bootstrap terverifikasi), lalu PIN sidik jarinya di sini.
# Kalau sidik jari tidak cocok, root ditolak.
#
# Sidik jari = SHA-256 atas file .cer (DER) apa adanya, sama dengan
# `openssl x509 -inform DER -noout -fingerprint -sha256` untuk sertifikat ini.
NC_APPLE_ROOT_URL="https://www.apple.com/appleca/AppleIncRootCertificate.cer"
NC_APPLE_ROOT_SHA256="B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024"
NC_APPLE_ROOT_SUBJECT="CN=Apple Root CA"

NC_CACERT_ARG=""

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

nc_apple_root_path() {
    printf '%s/apple-root.pem' "$NC_STATE_DIR"
}

# Terjemahkan DER ke PEM tanpa openssl: sebuah sertifikat PEM hanyalah
# base64 dari DER-nya yang dibungkus BEGIN/END CERTIFICATE.
nc_der_to_pem() {
    local src="$1" dest="$2"
    {
        printf -- '-----BEGIN CERTIFICATE-----\n'
        base64 <"$src" 2>/dev/null | tr -d '\n'
        printf '\n-----END CERTIFICATE-----\n'
    } >"$dest" 2>/dev/null
}

# Ambil isi base64 dari berkas PEM, decode balik ke DER, lalu hash.
# Ini yang kita bandingkan dengan sidik jari yang di-pin, karena sidik jari
# dihitung atas DER - sedangkan berkas yang kita simpan adalah PEM.
nc_pem_der_sha256() {
    local pem="$1" tmp sha
    command -v base64 >/dev/null 2>&1 || return 1
    tmp="${TMPDIR:-/tmp}/.ncpem.$$.$RANDOM"
    if ! sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$pem" 2>/dev/null |
        grep -v -- '-----' | tr -d '\r\n' | base64 -d >"$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    sha="$(sha256sum "$tmp" 2>/dev/null)" || sha=""
    rm -f "$tmp" 2>/dev/null
    sha="${sha%% *}"
    [ -n "$sha" ] || return 1
    printf '%s' "${sha^^}"
}

# Dipakai untukibasahkan apakah pesan curl itu masalah sertifikat.
nc_is_tls_error() {
    case "${1:-}" in
        *certificate* | *SSL* | *"self signed"* | *"error 60"* | *"error 77"*)
            return 0
            ;;
    esac
    return 1
}

nc_aerials_ensure_apple_root() {
    local dest sha tmp pem
    dest="$(nc_apple_root_path)"
    local want="${NC_APPLE_ROOT_SHA256^^}"

    if [ -s "$dest" ]; then
        sha="$(nc_pem_der_sha256 "$dest")" || sha=""
        if [ -n "$sha" ] && [ "$sha" = "$want" ]; then
            NC_CACERT_ARG="--cacert=$dest"
            return 0
        fi
        nc_log_warn "berkas root CA Apple tidak cocok, diambil ulang"
        rm -f "$dest" 2>/dev/null
    fi

    if [ ! -d "$NC_STATE_DIR" ] && ! mkdir -p "$NC_STATE_DIR" 2>/dev/null; then
        nc_log_error "gagal membuat $NC_STATE_DIR"
        return 1
    fi

    tmp="$dest.dl.$$"
    pem="$dest.pem.$$"

    # Root diambil tanpa --cacert Apple: hostnya www.apple.com yang punya
    # TLS publik, jadi trust store sistem sudah cukup untuk langkah ini.
    nc_log_info "mengambil Apple Root CA dari apple.com (bootstrap TLS terverifikasi)"
    if ! curl -fsSL --connect-timeout 20 --max-time 60 \
        "${NC_CURL_ARGS[@]}" -o "$tmp" "$NC_APPLE_ROOT_URL" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        nc_log_error "gagal mengunduh root CA dari $NC_APPLE_ROOT_URL"
        nc_anomaly_emit "$NC_SEV_ERROR" "CA_FETCH_FAILED" \
            "gagal mengunduh Apple Root CA dari apple.com" \
            "cek koneksi, atau set AERIALS_CURL_ARGS=--cacert=..." \
            "url=$NC_APPLE_ROOT_URL"
        return 1
    fi

    sha="$(sha256sum "$tmp" 2>/dev/null)"
    sha="${sha%% *}"
    sha="${sha^^}"
    if [ "$sha" != "$want" ]; then
        rm -f "$tmp" 2>/dev/null
        nc_anomaly_emit "$NC_SEV_SECURITY" "CA_FINGERPRINT_MISMATCH" \
            "sidik jari Apple Root CA tidak cocok, root ditolak" \
            "PENTING: selidiki dulu sebelum mengulang. Sidik jari yang diterima: ${sha:-tidak-terbaca}" \
            "expected=$want" "actual=${sha:-unknown}" "url=$NC_APPLE_ROOT_URL"
        nc_log_error "sidik jari root CA tidak cocok, ditolak demi keamanan"
        nc_log_error "  diharapkan: $want"
        nc_log_error "  diterima  : ${sha:-<tidak terbaca>}"
        return 1
    fi

    if ! nc_der_to_pem "$tmp" "$pem"; then
        rm -f "$tmp" "$pem" 2>/dev/null
        nc_log_error "gagal mengubah DER ke PEM"
        return 1
    fi
    rm -f "$tmp" 2>/dev/null

    # Verifikasi ulang lewat jalur yang akan dipakai curl nanti: decode
    # body base64-nya kembali ke DER dan bandingkan sidik jarinya.
    sha="$(nc_pem_der_sha256 "$pem")" || sha=""
    if [ "$sha" != "$want" ]; then
        rm -f "$pem" 2>/dev/null
        nc_log_error "verifikasi ulang PEM gagal, root ditolak"
        nc_log_error "  dekode base64 menghasilkan sidik jari yang tidak sama"
        nc_log_error "  hasil: ${sha:-<tidak terbaca>}"
        return 1
    fi

    if ! mv -f "$pem" "$dest" 2>/dev/null; then
        rm -f "$pem" 2>/dev/null
        nc_log_error "gagal menyimpan $dest"
        return 1
    fi
    chmod 0600 "$dest" 2>/dev/null

    NC_CACERT_ARG="--cacert=$dest"
    nc_log_info "root CA Apple siap: $dest (mode 0600, sidik jari cocok)"
    return 0
}

# Pasang --cacert hanya untuk host sylvan.apple.com. Sesiapa pun yang mengatur
# --cacert sendiri lewat AERIALS_CURL_ARGS tidak kita sentuh.
nc_aerials_use_apple_root() {
    local has_cacert=0 a
    for a in "${NC_CURL_ARGS[@]}"; do
        case "$a" in
            --cacert | --cacert=*) has_cacert=1 ;;
        esac
    done
    [ "$has_cacert" -eq 1 ] && return 0
    [ -n "$NC_CACERT_ARG" ] || return 1
    NC_CURL_ARGS+=("$NC_CACERT_ARG")
    return 0
}

nc_aerials_fetch_manifest_once() {
    local dest="$1"
    local url tmp
    tmp="$dest.tmp"
    for url in "$NC_AERIALS_MANIFEST_URL" "$NC_AERIALS_FALLBACK_URL"; do
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
    return 1
}

nc_aerials_has_user_cacert() {
    local a
    for a in "${NC_CURL_ARGS[@]}"; do
        case "$a" in
            --cacert | --cacert=*) return 0 ;;
        esac
    done
    return 1
}

nc_aerials_trust_marker() {
    printf '%s/apple-trust-ok' "$NC_STATE_DIR"
}

# Host sylvan.apple.com bisa dipercaya trust store sistem?
nc_aerials_host_trusted() {
    local marker
    marker="$(nc_aerials_trust_marker)"
    [ -f "$marker" ] && return 0
    if curl -sS -I -o /dev/null --connect-timeout 15 --max-time 30 \
        "${NC_CURL_ARGS[@]}" "$NC_AERIALS_MANIFEST_URL" 2>/dev/null; then
        mkdir -p "$NC_STATE_DIR" 2>/dev/null
        : >"$marker" 2>/dev/null
        return 0
    fi
    return 1
}

# Dipanggil sekali di awal, sebelum manifest maupun clip diunduh.
# Penting: kalau manifest sudah ada di cache, jalur bootstrap tidak terpakai
# dan clip lalu diunduh tanpa --cacert dan gagal dengan error sertifikat.
nc_aerials_prepare_trust() {
    NC_CACERT_ARG=""
    nc_aerials_curl_args

    nc_aerials_has_user_cacert && return 0

    case "${NC_AERIALS_TRUST:-auto}" in
        apple)
            nc_aerials_ensure_apple_root || return 1
            nc_aerials_use_apple_root
            ;;
        system)
            : ;;
        *)
            if nc_aerials_host_trusted; then
                return 0
            fi
            nc_log_warn "sertifikat Apple tidak dipercaya trust store sistem"
            nc_log_warn "mengambil Apple Root CA dari apple.com (sidik jari di-pin)"
            nc_aerials_ensure_apple_root || return 1
            nc_aerials_use_apple_root
            ;;
    esac
    return 0
}

nc_aerials_report_tls_hint() {
    nc_log_error "gagal mengambil manifest aerials dari server Apple"
    nc_log_error "AERIALS_TRUST=system tidak memakai root CA Apple bawaan"
    nc_log_error "coba: AERIALS_TRUST=apple   (atau --curl-arg=--cacert=...)"
    return 0
}

nc_aerials_fetch_manifest() {
    local dest="$1"

    nc_have curl || {
        nc_log_error "curl tidak ditemukan, perlu untuk mengunduh aerials"
        return "$NC_EXIT_ERROR"
    }

    if nc_aerials_prepare_trust; then
        if nc_aerials_fetch_manifest_once "$dest"; then
            return 0
        fi
    fi
    nc_aerials_report_tls_hint
    return "$NC_EXIT_ERROR"
}

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

    nc_have curl || {
        nc_log_error "curl tidak ditemukan, perlu untuk aerials"
        return "$NC_EXIT_ERROR"
    }

    local manifest="$NC_STATE_DIR/aerials-entries.json"
    mkdir -p "$NC_STATE_DIR" 2>/dev/null

    nc_aerials_prepare_trust || return "$NC_EXIT_ERROR"
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
