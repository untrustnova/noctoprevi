#!/usr/bin/env bash
#
# Helper untuk tests/run-tests.sh.
#
# Menjalankan siklus start/stop berulang di DALAM satu proses, lalu
# melaporkan apakah supervisor benar-benar hidup tiap iterasi.
#
# Ini menangkap regresi "lock tidak dilepas": kalau fd lock tetap dipegang
# proses ini setelah stop, iterasi berikutnya melihat lock terisi dan
# `start` kembali tanpa melakukan apa-apa. Gejalanya angka benchmark jadi
# tidak berarti - stop terasa 3 ms karena memang tidak ada yang dimatikan.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLES="${1:-3}"

for m in core log config anomaly anomaly_cmd tui media ipc runtime cmd setup aerials; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done

nc_init_paths
nc_log_init
nc_config_defaults
nc_config_load
nc_config_validate
nc_log_init
nc_config_ext_array

for (( i = 1; i <= CYCLES; i++ )); do
    rc=0
    nc_cmd_start >/dev/null 2>&1 || rc=$?
    if nc_pid_alive "$(nc_supervisor_pid 2>/dev/null)"; then
        state="hidup"
    else
        state="mati"
    fi
    printf 'siklus %s: start_rc=%s supervisor=%s\n' "$i" "$rc" "$state"
    nc_cmd_stop >/dev/null 2>&1
done
