# shellcheck shell=bash
#
# noctoprevi - media: penemuan file video, urutan putar, validasi.
#
# Strategi: daftar putar (playlist) diserialisasi sekali ke
# $XDG_RUNTIME_DIR/noctoprevi.order. Perintah `next` hanya membaca file
# itu, jadi tidak perlu glob ulang dan tidak perlu fork subprocess.

nc_media_glob() {
    local dir="$1"
    local -a hits=()
    local ext

    NC_MEDIA_COLLECT=()
    [ -d "$dir" ] || return 1
    [ -r "$dir" ] || return 1

    shopt -s nullglob
    if [ "$NC_VIDEO_RECURSIVE" -eq 1 ]; then
        shopt -s globstar
        for ext in "${NC_EXT_ARR[@]}"; do
            local g
            for g in "$dir"/**/*."$ext"; do
                hits+=("$g")
            done
        done
        shopt -u globstar
    else
        for ext in "${NC_EXT_ARR[@]}"; do
            local g
            for g in "$dir"/*."$ext"; do
                hits+=("$g")
            done
        done
    fi
    shopt -u nullglob

    local f
    for f in "${hits[@]}"; do
        nc_is_regular_file "$f" || continue
        NC_MEDIA_COLLECT+=("$f")
    done

    [ "${#NC_MEDIA_COLLECT[@]}" -gt 0 ] || return 1

    if [ "$NC_VIDEO_RECURSIVE" -eq 1 ] && [ "${#NC_MEDIA_COLLECT[@]}" -gt 1 ]; then
        NC_MEDIA_COLLECT=()
        mapfile -t NC_MEDIA_COLLECT < <(printf '%s\n' "${hits[@]}" | LC_ALL=C sort)
        local -a keep=()
        for f in "${NC_MEDIA_COLLECT[@]}"; do
            nc_is_regular_file "$f" || continue
            keep+=("$f")
        done
        NC_MEDIA_COLLECT=("${keep[@]}")
    fi
    return 0
}

nc_media_shuffle() {
    local -n _arr_ref="$1"
    local n="${#_arr_ref[@]}"
    local i j tmp
    [ "$n" -gt 1 ] || return 0
    for (( i = n - 1; i > 0; i-- )); do
        j=$(( (RANDOM * 32768 + RANDOM) % (i + 1) ))
        tmp="${_arr_ref[i]}"
        _arr_ref[i]="${_arr_ref[j]}"
        _arr_ref[j]="$tmp"
    done
}

nc_media_write_order() {
    local file="$1"
    shift
    [ "$#" -gt 0 ] || return 1
    printf '%s\n' "$@" >"$file" 2>/dev/null
}

nc_media_read_order() {
    local file="$1"
    NC_ORDER=()
    [ -r "$file" ] || return 1
    mapfile -t NC_ORDER < "$file" 2>/dev/null
    [ "${#NC_ORDER[@]}" -gt 0 ] || return 1
    return 0
}

nc_media_probe() {
    local file="$1" out
    [ "$NC_VALIDATE_MEDIA" -eq 1 ] || return 0
    nc_have ffprobe || return 0
    out="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_type \
        -of csv=p=0 -- "$file" 2>/dev/null)"
    case "$out" in
        *video*) return 0 ;;
        *) return 1 ;;
    esac
}

nc_media_build_order() {
    local order_file="$1"

    if ! nc_media_glob "$NC_VIDEO_DIR"; then
        nc_log_error "tidak ada file video yang valid di: $NC_VIDEO_DIR"
        nc_log_error "format yang dicari: ${NC_EXT_ARR[*]}"
        return 1
    fi

    if [ "$NC_PLAYBACK_MODE" = "sequential" ]; then
        nc_media_write_order "$order_file" "${NC_MEDIA_COLLECT[@]}"
    else
        nc_media_shuffle NC_MEDIA_COLLECT
        nc_media_write_order "$order_file" "${NC_MEDIA_COLLECT[@]}"
    fi

    nc_log_info "playlist: ${#NC_MEDIA_COLLECT[@]} file, mode=$NC_PLAYBACK_MODE, dir=$NC_VIDEO_DIR"
    return 0
}

nc_media_read_index() {
    local file="$1" idx
    idx=0
    if [ -r "$file" ]; then
        IFS= read -r idx < "$file" 2>/dev/null || idx=0
    fi
    case "$idx" in
        '' | *[!0-9]*) idx=0 ;;
    esac
    printf '%s' "$idx"
}

nc_media_write_index() {
    local file="$1" idx="$2"
    printf '%s\n' "$idx" >"$file" 2>/dev/null
}

nc_media_pick_from_order() {
    local order_file="$1" index_file="$2"
    local skip="$3"
    local -i idx tries n
    local candidate

    nc_media_read_order "$order_file" || return 1
    n="${#NC_ORDER[@]}"
    [ "$n" -gt 0 ] || return 1
    idx="$(nc_media_read_index "$index_file")"
    [ "$idx" -lt "$n" ] || idx=0

    tries=0
    while [ "$tries" -lt "$n" ]; do
        candidate="${NC_ORDER[idx]}"
        if [ -n "$skip" ] && [ "$candidate" = "$skip" ] && [ "$n" -gt 1 ]; then
            :
        elif nc_is_regular_file "$candidate"; then
            nc_media_write_index "$index_file" "$idx"
            printf '%s' "$candidate"
            return 0
        fi
        idx=$(( (idx + 1) % n ))
        tries=$(( tries + 1 ))
    done

    if nc_media_build_order "$order_file"; then
        n="${#NC_ORDER[@]:-0}"
        if nc_media_read_order "$order_file" && [ "${#NC_ORDER[@]}" -gt 0 ]; then
            nc_media_write_index "$index_file" 0
            printf '%s' "${NC_ORDER[0]}"
            return 0
        fi
    fi
    return 1
}

nc_media_advance() {
    local order_file="$1" index_file="$2" direction="${3:-1}"
    local -a order=()
    local -i idx n i steps found

    if ! nc_media_read_order "$order_file" || [ "${#NC_ORDER[@]}" -eq 0 ]; then
        nc_log_warn "order file tidak ada, membangun ulang"
        nc_media_build_order "$order_file" || return 1
        nc_media_read_order "$order_file" || return 1
    fi
    order=("${NC_ORDER[@]}")
    n="${#order[@]}"
    [ "$n" -gt 0 ] || return 1

    idx="$(nc_media_read_index "$index_file")"
    [ "$idx" -lt "$n" ] || idx=0

    found=0
    for (( steps = 1; steps <= n; steps++ )); do
        i=$(( (idx + steps * direction) % n ))
        [ "$i" -lt 0 ] && i=$(( i + n ))
        if nc_is_regular_file "${order[i]}"; then
            idx="$i"
            found=1
            break
        fi
    done
    [ "$found" -eq 1 ] || return 1

    nc_media_write_index "$index_file" "$idx"
    printf '%s' "${order[idx]}"
    return 0
}
