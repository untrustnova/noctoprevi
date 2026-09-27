# Product Requirements Document (PRD): Noctoprevi

---

## 1. Ringkasan Eksekutif

**Noctoprevi** adalah utilitas screensaver video modular dan berbobot ringan (*lightweight*) yang dirancang khusus untuk lingkungan Wayland (khususnya Noctalia Shell di atas compositor seperti Hyprland, Sway, atau Niri) pada distribusi CachyOS.

Program ini memanfaatkan kemampuan akselerasi perangkat keras dari `mpv` dan kontrol proses berbasis IPC (*Inter-Process Communication*) via `socat` untuk menghadirkan visual screensaver dinamis (seperti Apple TV Aerials atau video kustom) dengan konsumsi daya dan latensi serendah mungkin.

---

## 2. Latar Belakang & Masalah

* **Keterbatasan Solusi Eksisting:** Ekosistem Wayland tidak memiliki subsistem screensaver monolitik seperti XScreenSaver pada X11. Pengguna sering kali harus bergantung pada plugin berat atau tool desktop bawaan yang tidak fleksibel.
* **Overhead Sumber Daya:** Solusi screensaver berbasis web atau Electron mengonsumsi memori dan daya CPU yang berlebihan saat sistem dalam kondisi idle.
* **Integrasi Desentralisasi:** Pengguna CachyOS dengan Noctalia membutuhkan utilitas independen yang dapat dipicu secara presisi oleh idle daemon (`hypridle`/`swayidle`) dan dapat langsung dimatikan seketika saat ada interaksi pengguna (*zero input lag* saat resume).

---

## 3. Lingkungan Target & Dependensi

| Komponen | Spesifikasi / Paket Target |
| --- | --- |
| **Sistem Operasi** | CachyOS (Linux x86_64, optimized kernel) |
| **Display Protocol** | Wayland (`wlroots`, Hyprland, Sway, Niri) |
| **Desktop Shell** | Noctalia Shell |
| **Playback Engine** | `mpv` (dengan decoding VA-API / NVDEC) |
| **IPC Controller** | `socat` |
| **Idle Management** | `hypridle` (primer) atau `swayidle` |
| **Standar Direktori** | XDG Base Directory Specification |

---

## 4. Kebutuhan Fungsional (*Functional Requirements*)

### FR-01: Kontrol Siklus Hidup Proses (Lifecycle Control)

* Program harus menyediakan antarmuka CLI sederhana:
* `noctoprevi start`: Memulai pemutaran video secara fullscreen tanpa border.
* `noctoprevi stop`: Menghentikan video dan membersihkan socket secara instan (<100ms).
* `noctoprevi toggle`: Membalikkan status berjalan/mati program.
* `noctoprevi next`: Melewatkan video yang sedang aktif ke video berikutnya di direktori.
* `noctoprevi status`: Memeriksa apakah screensaver sedang aktif (mengembalikan exit code `0` atau `1`).


* Pencegahan instans ganda (*singleton pattern*): jika `start` dipanggil saat program sudah aktif, program tidak boleh membuat jendela baru.

### FR-02: Manajemen & Seleksi Media

* Mendukung format kontainer video universal: `.mp4`, `.mkv`, `.webm`, `.mov`.
* Mode pemilihan file:
* **Shuffle/Random:** Memilih klip secara acak dari direktori media.
* **Sequential:** Memutar playlist secara berurutan.


* Looping tak terbatas (*seamless infinite loop*) untuk file yang sedang diputar.
* *Graceful Fallback*: Jika direktori kosong atau format file tidak valid, program harus mencatat log kesalahan dan keluar tanpa menyebabkan hang pada compositor.

### FR-03: Optimasi Playback Engine

* Pemutaran video harus mematikan audio secara default (`--no-audio`) untuk mencegah interferensi suara saat komputer ditinggal.
* Mengaktifkan akselerasi perangkat keras otomatis (`--hwdec=auto`) untuk menurunkan beban CPU hingga mendekati 0%.
* Menyembunyikan kursor mouse secara permanen saat jendela screensaver aktif (`--cursor-autohide=always`).

### FR-04: Komunikasi Antar-Proses (IPC)

* Menggunakan Unix Domain Socket pada direktori runtime pengguna:
* Jalur default: `$XDG_RUNTIME_DIR/noctoprevi.sock` (fallback: `/tmp/noctoprevi-$UID.sock`).


* Perintah eksternal dikirim melalui socket menggunakan payload JSON-IPC `mpv` via `socat`.

### FR-05: Integrasi Idle & Lockscreen

* Konfigurasi kompatibel dengan `hypridle.conf` melalui dua tahap:
1. *Idle threshold 1:* Memicu `noctoprevi start`.
2. *User input resume:* Memicu `noctoprevi stop`.
3. *Idle threshold 2:* Mengunci sesi menggunakan Noctalia lockscreen (`noctalia msg lock`).



---

## 5. Kebutuhan Non-Fungsional (*Non-Functional Requirements*)

* **Performa (Latency):** Waktu terminasi dari deteksi input mouse/keyboard hingga layar kembali responsif ke pengguna harus di bawah **150 milidetik**.
* **Efisiensi Daya:** Penggunaan CPU saat screensaver berjalan tidak boleh melebihi **2-3%** pada prosesor modern berkat pemanfaatan decoding GPU.
* **Modularitas & Portabilitas:** Kode inti ditulis menggunakan POSIX-compliant Bash atau Python/Rust ringan tanpa dependensi pustaka GUI pihak ketiga selain `mpv`.
* **Keamanan & Stabilitas:** File socket sementara harus diisolasi pada level pengguna (`UID`) agar tidak terjadi konflik izin pada sistem multi-user.

---

## 6. Spesifikasi Direktori & Konfigurasi

Sesuai standar XDG, struktur direktori `noctoprevi` ditentukan sebagai berikut:

```text
~/.config/noctoprevi/
├── config.conf          # File konfigurasi (direktori video, mode urutan, hwdec, argumen mpv)
└── videos/              # Direktori default penyimpanan file video screensaver

```

File runtime:

```text
$XDG_RUNTIME_DIR/noctoprevi.sock   # Socket kontrol IPC

```

---

## 7. Roadmap Implementasi

### Fase 1: MVP (Minimum Viable Product)

* Pembuatan skrip inti Bash dengan parameter `start`, `stop`, dan `status`.
* Integrasi socket IPC `mpv` dan `socat`.
* Seleksi acak format video `.mp4`/`.mkv`.
* Template integrasi untuk `hypridle.conf`.

### Fase 2: Robustness & Modular Config

* Penambahan parser file konfigurasi `~/.config/noctoprevi/config.conf`.
* Implementasi perintah `noctoprevi next` dan `noctoprevi toggle`.
* Penanganan multi-monitor (opsi pemutaran cermin atau per-monitor).
* Log error yang terstandarisasi ke `journalctl` atau file lokal.

### Fase 3: Distribusi & Integrasi Lanjutan

* Pembuatan skrip instalasi otomatis / `PKGBUILD` untuk CachyOS/Arch User Repository (AUR).
* Pembuatan skrip downloader opsional untuk mengunduh koleksi video Aerial resmi Apple secara otomatis ke folder media `noctoprevi`.