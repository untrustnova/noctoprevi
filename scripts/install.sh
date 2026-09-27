#!/usr/bin/env bash
#
# noctoprevi - installer tanpa root.
#
#   ./scripts/install.sh              -> ~/.local/bin + config + integrasi idle
#   ./scripts/install.sh --prefix DIR -> prefix lain
#   ./scripts/install.sh --no-idle    -> lewati integrasi idle daemon
#   ./scripts/install.sh --uninstall  -> cabot semuanya
#
# Tidak butuh sudo. Semua masuk ke $HOME.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${HOME}/.local"
DO_IDLE=1
DO_UNINSTALL=0
INSTALL_LINKS=1

c_grn() { printf '\033[32m%s\033[0m' "$1"; }
c_yel() { printf '\033[33m%s\033[0m' "$1"; }
c_red() { printf '\033[31m%s\033[0m' "$1"; }
say() { printf '%s\n' "$*"; }
step() { printf '  %s %s\n' "$(c_grn '==>')" "$*"; }
warn() { printf '  %s %s\n' "$(c_yel '!!')" "$*"; }
die() {
    printf '  %s %s\n' "$(c_red 'xx')" "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --no-idle) DO_IDLE=0; shift ;;
        --uninstall) DO_UNINSTALL=1; shift ;;
        --no-links) INSTALL_LINKS=0; shift ;;
        -h | --help)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "opsi tidak dikenal: $1" ;;
    esac
done

BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/noctoprevi"
SHARE_DIR="$PREFIX/share/noctoprevi"
DOC_DIR="$PREFIX/share/doc/noctoprevi"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/noctoprevi"
VIDEO_DIR="$CFG_DIR/videos"

uninstall_all() {
    step "menghapus integrasi idle"
    for daemon in hypridle swayidle; do
        case "$daemon" in
            hypridle) conf="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hypridle.conf" ;;
            swayidle) conf="${XDG_CONFIG_HOME:-$HOME/.config}/swayidle/config" ;;
        esac
        [ -f "$conf" ] || continue
        if "$ROOT/bin/noctoprevi" uninstall --idle-daemon "$daemon" >/dev/null 2>&1; then
            say "      blok noctoprevi dibuang dari $conf"
        fi
    done

    step "menghentikan screensaver"
    "$ROOT/bin/noctoprevi" stop >/dev/null 2>&1

    step "menghapus file"
    rm -f "$BIN_DIR/noctoprevi"
    rm -rf "$LIB_DIR"
    rm -f "$SHARE_DIR/config.conf"
    rmdir "$SHARE_DIR" 2>/dev/null
    rmdir "$DOC_DIR" 2>/dev/null
    rm -f /tmp/noctoprevi-"$UID".sock /tmp/noctoprevi-"$UID".pid /tmp/noctoprevi-"$UID".lock 2>/dev/null
    say "      config dan video di $CFG_DIR TIDAK dihapus (data kamu)"
    say "      hapus manual:  rm -rf '$CFG_DIR'"
    say ""
    say "$(c_grn 'Selesai.') Alihkan shell baru agar PATH ter-update:"
    say "    exec \$SHELL"
    exit 0
}

[ "$DO_UNINSTALL" -eq 1 ] && uninstall_all

# ---------------------------------------------------------------------------

say ""
say "noctoprevi installer"
say "------------------------------------------------------------------"

step "memeriksa dependensi"
MISSING=0
for dep in mpv socat flock; do
    if command -v "$dep" >/dev/null 2>&1; then
        say "      $(c_grn 'ada')    $dep -> $(command -v "$dep")"
    else
        say "      $(c_red 'hilang') $dep"
        MISSING=$(( MISSING + 1 ))
    fi
done
for dep in ffprobe ffmpeg jq hypridle swayidle; do
    if command -v "$dep" >/dev/null 2>&1; then
        say "      $(c_grn 'ada')    $dep (opsional)"
    else
        say "      $(c_yel 'tidak') $dep (opsional)"
    fi
done
if [ "$MISSING" -gt 0 ]; then
    say ""
    die "dependensi wajib belum lengkap. Di CachyOS: sudo pacman -S mpv socat"
fi

step "memasang ke $PREFIX"
mkdir -p "$BIN_DIR" "$LIB_DIR" "$SHARE_DIR" "$DOC_DIR" || die "gagal membuat $PREFIX"
install -Dm755 "$ROOT/bin/noctoprevi" "$BIN_DIR/noctoprevi" || die "gagal memasang binari"
for lib in core log config media ipc runtime cmd setup aerials; do
    install -Dm644 "$ROOT/lib/$lib.sh" "$LIB_DIR/$lib.sh" || die "gagal memasang lib/$lib.sh"
done
install -Dm644 "$ROOT/config/config.conf" "$SHARE_DIR/config.conf"
install -Dm644 "$ROOT/config/hypridle.conf.example" "$DOC_DIR/hypridle.conf.example"
install -Dm644 "$ROOT/config/swayidle.config.example" "$DOC_DIR/swayidle.config.example"
[ -f "$ROOT/README.md" ] && install -Dm644 "$ROOT/README.md" "$DOC_DIR/README.md"
[ -f "$ROOT/LICENSE" ] && install -Dm644 "$ROOT/LICENSE" "$DOC_DIR/LICENSE"
say "      $(c_grn 'terpasang') $BIN_DIR/noctoprevi"

if [ "$INSTALL_LINKS" -eq 1 ]; then
    step "menautkan ke /usr/local/bin bila bisa ditulis"
    if [ -w /usr/local/bin ] 2>/dev/null; then
        ln -sf "$BIN_DIR/noctoprevi" /usr/local/bin/noctoprevi &&
            say "      $(c_grn 'tautan') /usr/local/bin/noctoprevi"
    else
        warn "/usr/local/bin tidak writable, lewati"
    fi
fi

step "menyiapkan konfigurasi"
mkdir -p "$CFG_DIR" "$VIDEO_DIR"
if [ -f "$CFG_DIR/config.conf" ]; then
    say "      config sudah ada, tidak ditimpa: $CFG_DIR/config.conf"
else
    cp "$SHARE_DIR/config.conf" "$CFG_DIR/config.conf" &&
        say "      $(c_grn 'dibuat')} $CFG_DIR/config.conf"
fi
say "      folder video: $VIDEO_DIR"

if [ "$DO_IDLE" -eq 1 ]; then
    step "menyiapkan integrasi idle"
    daemon=""
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hypridle >/dev/null 2>&1; then
        daemon="hypridle"
    elif { [ -n "${SWAYSOCK:-}" ] || [ -n "${NIRI_SOCKET:-}" ]; } &&
        command -v swayidle >/dev/null 2>&1; then
        daemon="swayidle"
    elif command -v hypridle >/dev/null 2>&1; then
        daemon="hypridle"
    elif command -v swayidle >/dev/null 2>&1; then
        daemon="swayidle"
    fi

    if [ -n "$daemon" ]; then
        "$BIN_DIR/noctoprevi" install --idle-daemon "$daemon" 2>&1 |
            sed 's/^/      /'
    else
        warn "daemon idle tidak ditemukan (hypridle / swayidle)"
        say "      pasang salah satu, lalu ulangi langkah ini:"
        say "        sudo pacman -S swayidle"
    fi
fi

step "menjalankan doctor"
"$BIN_DIR/noctoprevi" doctor 2>&1 | sed 's/^/      /'

say ""
say "------------------------------------------------------------------"
say "$(c_grn 'Instalasi selesai.') Langkah berikutnya:"
say ""
say "  1. Pastikan \$BIN_DIR ada di PATH:"
say "       export PATH=\"\$HOME/.local/bin:\$PATH\""
say ""
say "  2. Isi folder video dengan clip:"
say "       $BIN_DIR/noctoprevi aerials --sync --quality 1080p"
say "     atau salin file mp4/mkv/webm/mov sendiri ke:"
say "       $VIDEO_DIR"
say ""
say "  3. Uji manual:"
say "       $BIN_DIR/noctoprevi start"
say "       $BIN_DIR/noctoprevi status"
say "       $BIN_DIR/noctoprevi next"
say "       $BIN_DIR/noctoprevi stop"
say ""
say "  4. Ukur latensi stop (target <150ms):"
say "       $BIN_DIR/noctoprevi bench --runs 10"
say ""
