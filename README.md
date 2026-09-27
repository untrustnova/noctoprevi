# noctoprevi

Screensaver video modular untuk Wayland. Dipicu idle daemon, dimatikan seketika
saat ada input. Dibangun di atas `mpv` (VA-API / NVDEC) dengan kontrol proses
lewat JSON-IPC di Unix socket.

Dirancang untuk CachyOS + Noctalia Shell, jalan juga di Hyprland, Sway, dan Niri.

```
 hypridle / swayidle
   |
   |  idle 300 detik            +------------------+
   +--------------------------->|    supervisor    |   bash, memegang flock
   |                            |   +---------+----+|
   |  idle 900 detik            |             |     |  fork + exec
   +--------------------------->|   +---------v-+  |
   |                            |   |    mpv    |  |  --hwdec=auto --no-audio
   |  noctalia msg lock         |   |  (video)  |  |  --cursor-autohide=always
   v                            |   +----------+  |  --input-ipc-server=...
 lockscreen                     +---------|-------+
                                          |
            resume -->  socat {"command":["quit"]}  atau  SIGTERM
```

---

## Daftar isi

- [Cepat mulai](#cepat-mulai)
- [Perintah](#perintah)
- [Konfigurasi](#konfigurasi)
- [Integrasi idle](#integrasi-idle)
- [Koleksi video](#koleksi-video)
- [Cara kerja internal](#cara-kerja-internal)
- [Multi-monitor](#multi-monitor)
- [Mengukur latensi](#mengukur-latensi)
- [Pemecahan masalah](#pemecahan-masalah)
- [Arsitektur berkas](#arsitektur-berkas)
- [Pengembangan](#pengembangan)

---

## Cepat mulai

**Prasyarat:** `mpv`, `socat`, `flock` (util-linux). Opsional: `ffmpeg`,
`ffprobe`, `jq`, `hypridle` atau `swayidle`.

Di CachyOS / Arch:

```bash
sudo pacman -S mpv socat
```

Pasang tanpa root:

```bash
git clone <repo> ~/src/noctoprevi
cd ~/src/noctoprevi
./scripts/install.sh
export PATH="$HOME/.local/bin:$PATH"
```

Lalu isi folder video:

```bash
noctoprevi aerials --sync --quality 1080p
```

Dan pasang pemicu idle:

```bash
noctoprevi install --idle-daemon swayidle   # Sway / Niri
noctoprevi install --idle-daemon hypridle   # Hyprland
```

Cek semuanya:

```bash
noctoprevi doctor
```

---

## Perintah

| Perintah | Fungsi | Exit code |
| --- | --- | --- |
| `start` | Nyalakan screensaver. Singleton: kalau sudah aktif, tidak bikin jendela baru. | 0 |
| `stop` | Matikan + bersihkan socket. | 0 / 1 kalau tidak aktif |
| `toggle` | Kebalikan status. | 0 / 1 / 2 |
| `next` | Lompat ke clip berikutnya. | 0 / 2 |
| `prev` | Kembali ke clip sebelumnya. | 0 / 2 |
| `status` | `0` kalau aktif, `1` kalau tidak. | 0 / 1 |
| `doctor` | Periksa dependensi, config, socket, akselerasi GPU. | 0 / 2 |
| `bench` | Ukur latensi `stop` berulang kali. | 0 / 2 |
| `install` | Tulis config + blok integrasi idle. | 0 |
| `uninstall` | Cabot blok integrasi idle, stop screensaver. | 0 |
| `aerials` | Kelola koleksi video Apple TV Aerial. | 0 / 2 |

Opsi global: `--config <file>`, `--quiet`, `--help`, `--version`.

`status` dipakai skrip hypridle/swayidle, jadi kecepatannya penting.
It tidak memanggil mpv sama sekali — hanya membaca pidfile.

---

## Konfigurasi

`~/.config/noctoprevi/config.conf`, format `KEY=VALUE` satu per baris.
Nilai boleh diapit `"` atau `'`. Baris `#` adalah komentar.
Key yang tidak dikenal dicatat sebagai peringatan, bukan error — jadi config
lama tidak langsung meledak setelah upgrade.

Berkas yang paling sering diubah:

```conf
# Mana clip-nya
VIDEO_DIR=~/.config/noctoprevi/videos
PLAYBACK_MODE=shuffle          # shuffle | sequential
VIDEO_EXTENSIONS=mp4,mkv,webm,mov
VIDEO_RECURSIVE=0              # 1 = ikut pindai subfolder

# Engine (FR-03)
HWDEC=auto                     # auto | vaapi | nvdec | cuda | drm | vk | no
AUDIO=none                     # none = mute total
CURSOR_AUTOHIDE=always
LOOP_FILE=inf
FULLSCREEN=1

# Multi-monitor
MONITOR_MODE=focused           # focused | all

# Robustness
VALIDATE_MEDIA=1               # cek dengan ffprobe sebelum diputar
RETRY_LIMIT=3                  # coba file lain sebanyak ini kalau mpv gagal
STARTUP_GRACE_MS=2500          # mpv mati sebelum ini = dianggap file rusak
STOP_IPC_WAIT_MS=20            # tunggu IPC quit, lalu eskalasi ke SIGTERM

# Log
LOG_LEVEL=info                 # debug | info | warn | error | off
LOG_TARGET=stderr              # stderr | file | both | journal
```

Semua key ada di `config/config.conf` yang terpasang, lengkap dengan
keterangan setiap baris. Setelah ubah:

```bash
noctoprevi stop && noctoprevi start
```

`MPV_ARGS` mengganti set argumen inti, `EXTRA_MPV_ARGS` hanya menambahkan.
 Pakai `EXTRA_MPV_ARGS` dulu; pindah ke `MPV_ARGS` baru kalau benar-benar
perlu meng-override default.

---

## Integrasi idle

### hypridle

```bash
noctoprevi install --idle-daemon hypridle
hyprctl reload
```

Blok yang ditulis:

```ini
listener { timeout = 300;  on-timeout = noctoprevi start }
listener { timeout = 900;  on-timeout = noctalia msg lock }
listener { timeout = 0;    on-resume  = noctoprevi stop }
```

`timeout = 0` berarti listener itu tidak pernah memicu `on-timeout`, tapi
`on-resume` tetap dipanggil. Hasilnya layar tidak berkedip: screensaver
mati tepat di detik pertama ada input.

### swayidle (Sway dan Niri)

```bash
noctoprevi install --idle-daemon swayidle
swaymsg reload
systemctl --user enable --now swayidle
```

Niri tidak punya idle daemon bawaan, tapi mengimplementasikan `wlr-idle`,
jadi `swayidle` bisa dipakai apa adanya.

### Kenapa begini, bukan yang lain

- **Mematikan lewat `on-resume`, bukan `on-timeout`.** Kalau parodyanya juga
 omlette `on-timeout` untuk stop, layar akan berkedip setiap idle timeout.
- **`socat`, bukan `nc`.** Hanya `socat` yang ada di repo Arch/CachyOS dan
  mendukung `UNIX-CONNECT` dengan benar.
- **Tidak pakai `hyprlock`/lock bawaan.** Kunci layar tetap Noctalia
  (`noctalia msg lock`) supaya konsisten dengan tema dan panel kamu.

Kalau kamu pakai lockown lebih agresif (misal `swayidle -w`), screensaver
dimatikan oleh `on-resume` lebih dulu, jadi tidak akan tertinggal.

---

## Koleksi video

Folder video menerima `.mp4`, `.mkv`, `.webm`, `.mov` (bisa diubah lewat
`VIDEO_EXTENSIONS`).

```bash
noctoprevi aerials                 # lihat katalog, 114 clip
noctoprevi aerials --sync          # unduh semua sesuai AERIALS_QUALITY
noctoprevi aerials --sync -q 4k    # varian 4K HEVC
noctoprevi aerials --sync --only "Tokyo"   # hanya yang namanya cocok
```

Sumbernya server resmi Apple (`sylvan.apple.com`):
- Kualitas: `1080p` (H.264, paling aman) · `1080p-hevc` · `1080p-hdr` ·
  `4k` · `4k-hdr`
- Folder: `AERIALS_DIR`, default ikut `VIDEO_DIR`
- Unduhan berjalan paralel (`--jobs`, default 3), file yang sudah ada dilewati,
  bisa dilanjutkan (`curl -C -`)

Ukuran perkiraan: `1080p` sekitar 1–3 GB untuk semua clip. `4k` bisa sampai
65 GB kalau ambil semua, jadi pakai `--only` kalau mau selektif.

Butuh `curl` dan `jq`. `ffmpeg` tidak dipakai untuk unduhan (file Apple sudah
dalam `.mov` jadi), tapi tetap berguna kalau kamu mau transcode sendiri.

Kalau lewat proxy atau memakai trust store sendiri:

```conf
AERIALS_CURL_ARGS=--proxy http://proxy:8080
AERIALS_CURL_ARGS=--cacert /path/ke/bundle.pem
```

Atau sesaat via CLI: `noctoprevi aerials --sync --curl-arg=--cacert=/path/bundle.pem`

---

## Cara kerja internal

### Supervisor

`noctoprevi start` tidak menjalankan screensaver langsung. Dia men-spawn satu
proses bash yang menjadi **supervisor**, lalu langsung keluar. Jadi
`hypridle` tidak perlu menunggu jendela mpv benar-benar muncul.

```
noctoprevi start
  └─ (subshell) exec noctoprevi __supervise
        ├─ tulis pidfile
        ├─ pegang flock pada $XDG_RUNTIME_DIR/noctoprevi.lock
        ├─ mpv --input-ipc-server=… --loop-file=inf <clip>
        └─ wait; kalau mpv rc≠0 sebelum STARTUP_GRACE_MS → coba clip lain
```

Supervisor juga menangani:
- Clip yang dihapus/di corrupted saat diputar → lompat ke yang berikutnya
- Semua clip rusak → keluar dengan pesan jelas, tidak menggantung compositor
- `SIGTERM`/`SIGINT` → bunuh anak mpv, bersihkan semua file runtime

### Singleton

Dua lapis:

1. **flock** pada `noctoprevi.lock`. Ini yang otoritatif — tahan pid reuse,
   dan `start` dari 6 proses paralel hanya menghasilkan 1 jendela
   (ada test-nya).
2. **pidfile** `noctoprevi.pid` untuk `status` dan `stop` supaya keduanya
   cepat tanpa perlu cek lock.

Supervisor mewarisi file descriptor lock dari `start`, jadi lock tetap dipegang
selama supervisor hidup, dan otomatis lepas saat ia mati.

### IPC (FR-04)

`mpv --input-ipc-server=$XDG_RUNTIME_DIR/noctoprevi.sock` membuat socket-nya
sendiri. Semua perintah keluar lewat JSON-RPC mpv:

```json
{"command":["quit"],"request_id":1}
{"command":["loadfile","/path/clip.mov","replace"],"request_id":2}
{"command":["get_property","path"],"request_id":3}
```

Path di-escape dengan `nc_json_escape` (quote, backslash, control character),
supaya nama file dengan spasi atau karakter aneh tidak merusak payload.

Untuk multi-monitor, socket instance ke-N ada di `noctoprevi.N.sock`
(instance 0 tetap `noctoprevi.sock` supaya sesuai PRD).

### Jalur `stop` yang cepat

Bagian stop sengaja menghindari IPC yang pelan. Urutannya:

```
t0   baca pidfile + pid mpv                    (~0.2ms, tanpa fork)
t0   fork socat, kirim {"command":["quit"]} di background
t0   poll /proc tiap 5ms sampai mpv hilang      <- ini yang bersihkan layar
t20  masih hidup? -> SIGTERM ke mpv
t100 masih hidup? -> SIGKILL
t+   bersihkan socket / pidfile / order / media
```

Yang diukur sebagai "layar bersih" adalah mpv mati, bukan socat selesai.
Fork `socat` berjalan paralel dengan polling, jadi tidak menumpuk waktu.

**Kenapa ada eskalasi ke SIGTERM.** Diuji langsung di mesin ini:

| Cara stop | Waktu |
| --- | --- |
| IPC `{"command":["quit"]}` | 41 ms |
| `SIGTERM` | 9 ms |
| `SIGKILL` | 11 ms |

mpv menutup `quit` dengan rapi tapi butuh ~40 ms karena menunggu graceful
shutdown penuh. `SIGTERM` memakai jalur keluar yang lebih cepat dan tetap
teratur — tidak merusak apa pun karena screensaver hanya membaca file.
Jadi program mencoba cara bersih dulu, lalu naik ke `SIGTERM` supaya tidak
menunggu. Hasilnya layar bersih dalam 13-22 ms, bukan 28 ms.

Semua penundaan polling memakai `read -t` pada fifo, bukan `sleep`, karena
`sleep` adalah binary eksternal dan akan menambah ~1 ms per iterasi.
Config parsing juga tanpa command substitution — 50 baris config dulu
memakan 10 ms karena ~150 fork.

### Playlist

Daftar putar diserialisasi sekali ke `noctoprevi.order` (satu path per baris).
`next` cuma membaca file itu — tidak perlu glob ulang, tidak perlu sort,
tidak perlu fork. Kalau file di playlist hilang, `next` melompatinya dan
membangun ulang playlist kalau terlalu banyak yang hilang.

Acak memakai Fisher-Yates dengan `$RANDOM`, bukan `shuf`, supaya tidak ada
subprocess untuk 500 file.

### File runtime

Semua di `$XDG_RUNTIME_DIR` (fallback `/tmp`):

| Berkas | Isi |
| --- | --- |
| `noctoprevi.sock` | JSON-IPC mpv (dibuat mpv) |
| `noctoprevi.pid` | PID supervisor |
| `noctoprevi.0.pid` | PID mpv instance ke-0 |
| `noctoprevi.N.sock` | Socket instance ke-N (multi-monitor) |
| `noctoprevi.order` | Playlist, satu path per baris |
| `noctoprevi.index` | Posisi playback saat ini |
| `noctoprevi.media` | Path clip yang sedang diputar |
| `noctoprevi.lock` | flock singleton |

Kalau `$XDG_RUNTIME_DIR` tidak bisa dipakai, semua nama file diberi suffix
`-<UID>`, sesuai PRD. Ini juga mencegah tabrakan di `/tmp` yang ditulis
semua user. Nama socket juga dijaga tetap di bawah batas 108 byte `sun_path`.

---

## Multi-monitor

```conf
MONITOR_MODE=focused   # default
MONITOR_MODE=all
```

- **`focused`** — satu jendela fullscreen di output yang aktif. Paling andal,
  dan itulah yang dipakai sebagian besar orang.
- **`all`** — satu proses mpv per output, masing-masing dengan socket sendiri.
  `next` dan `stop` diteruskan ke semua instance. Output dideteksi lewat
  `hyprctl monitors`, `niri msg outputs`, `swaymsg`, atau `wlr-randr`.

Keterbatasan yang perlu diketahui: mpv di Wayland tidak punya cara memilih
output tertentu — compositor yang menaruh permukaannya. Jadi di mode `all`,
beberapa instance bisa semuanya mendarat di satu monitor kalau compositor
menerapkan focus-stealing prevention. Kalau begitu screensaver tetap jalan,
tapi hanya satu monitor yang tertutup. Untuk menjamin semua monitor tertutup,
jalankan `focused` per workspace, atau konfigurasi `--force-window` manual
per output lewat `EXTRA_MPV_ARGS`.

---

## Mengukur latensi

```bash
noctoprevi bench --runs 10
```

```
Benchmark noctoprevi: 10 putaran (start -> stop)
run    start(ms)    stop(ms)    total(ms)
...
stop   min=41ms  p50=46ms  p95=52ms  max=58ms  rata-rata=47ms  [OK, di bawah anggaran 120ms]
```

`stop` mengukur waktu sampai proses mpv benar-benar hilang, karena itu yang
menghilangkan gambar dari layar. Kalau di mesinmu `p95` melewati 150ms:

1. `noctoprevi doctor` — cek `hwdec` dan `/dev/dri`
2. Naikkan `STOP_IPC_WAIT_MS` kalau `LOG_LEVEL=debug` sering mencatat
   eskalasi ke SIGTERM dan kamu lebih suka shut down sepenuhnya
3. Set `LOG_LEVEL=debug` dan lihat pesan `stop: layar bersih dalam …ms`
4. Cek compositor: beberapa compositor punya delay saat menutup surface

---

## Pemecahan masalah

**Layar tidak muncul saat `start`**

```bash
noctoprevi doctor          # cek mpv, socat, hwdec, folder video
ls ~/.config/noctoprevi/videos    # ada file yang cocok?
noctoprevi start            # lihat pesan errornya langsung
```

**`start` bilang "tidak ada file video yang valid"**

Folder kosong, atau semua file punya ekstensi di luar `VIDEO_EXTENSIONS`.
Jalankan `noctoprevi aerials --sync` atau isi manual.

**Screensaver tidak mati saat input**

- `LOG_TARGET=stderr` dan jalankan hypridle sebagai systemd user service,
  lalu cek `journalctl --user -u hypridle -f`
- Pastikan blok `noctoprevi` ada di config idle kamu (`noctoprevi doctor`
  akan memberi tahu)
- Uji manual: `noctoprevi stop` harus terasa instan

**`stop` lambat**

```bash
LOG_LEVEL=debug noctoprevi stop
```

Lihat baris `stop: layar bersih dalam Xms`.

**Layar penuh tapi video hitam**

`hwdec=auto` mungkin jatuh ke software karena paket driver belum ada.
Coba `HWDEC=vaapi` atau `HWDEC=nvdec` secara eksplisit, atau `HWDEC=no`
untuk memastikan masalahnya bukan decoding.

**`aerials` gagal dengan "kesalahan sertifikat TLS"**

Trust store sistem tidak punya root CA Apple. Gejalanya `curl: (60)`. Cek
dulu:

```bash
printf '%s\n' | sudo trust list --filter=ca-anchors | grep -i apple
```

Kalau kosong, pasang ulang anchors-nya:

```bash
sudo pacman -S --overwrite '*' ca-certificates-mozilla
sudo update-ca-trust
```

Kalau tidak boleh pakai sudo, arahkan ke bundle sendiri lewat
`AERIALS_CURL_ARGS=--cacert=/path/ke/bundle.pem`.

**Butuh jalan di dua monitor**

Lihat bagian [Multi-monitor](#multi-monitor).

---

## Arsitektur berkas

```
bin/noctoprevi          CLI entry: resolvable symlink,-load modul, dispatch
lib/core.sh             konstanta, path XDG, util (JSON escape, timing, PID)
lib/log.sh              level + target (stderr/file/both/journal)
lib/config.sh           parser config.conf + validasi
lib/media.sh            glob, Fisher-Yates, playlist, advance
lib/ipc.sh              JSON-IPC mpv lewat socat
lib/runtime.sh          singleton, supervisor, hope stop path
lib/cmd.sh              start/stop/toggle/next/prev/status
lib/setup.sh            doctor, bench, install/uninstall idle daemon
lib/aerials.sh          unduh koleksi Aerial
config/                 template config.conf + contoh hypridle/swayidle
scripts/install.sh      installer tanpa root
packaging/PKGBUILD      paket Arch/CachyOS
tests/                  test suite tanpa dependensi
```

Tidak ada dependensi runtime selain `mpv`, `socat`, `flock`. Tidak ada
dependensi Python. Sekitar 2400 baris bash untuk programnya, sisanya test.

---

## Pengembangan

```bash
./tests/run-tests.sh              # semua test
./tests/run-tests.sh config       # hanya yang namanya cocok
./tests/run-tests.sh --gpu        # pakai output video sungguhan
./tests/run-tests.sh --list       # daftar test
./scripts/install.sh --prefix /tmp/np-try   # coba pasang tanpa ganggu sistem
```

Test suite (150 test) tidak butuh `bats` atau framework apa pun. Tiap test
dapat sandbox `XDG_*` sendiri, jadi tidak menyentuh konfigurasi asli. Test
yang butuh mpv/socat/ffmpeg otomatis di-skip kalau belum terpasang.

Beberapa hal yang dijaga test suite, antara lain: singleton raced 6 proses
sekaligus, file dihapus saat diputar, semua clip rusak, mpv yatim, socket
basi, layout terpasang di prefix, pemanggilan lewat symlink, dan anggaran
latensi `stop` <150 ms.

Secara default test memakai `--vo=null` supaya tidak mengambil alih layar.
Gunakan `--gpu` untuk menguji jalur output video sungguhan.

Linting:

```bash
shellcheck -x -S warning -e SC2034 bin/noctoprevi lib/*.sh
bash -n bin/noctoprevi lib/*.sh
```

---

## Lisensi

MIT. Lihat `LICENSE`.

Koleksi video Apple TV Aerial milik Apple Inc. dan diunduh dari server
mereka; kamu bertanggung jawab sendiri soal lisensi penggunaan personal.
