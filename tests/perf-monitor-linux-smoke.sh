#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${ROOT_DIR}/tools/perf-monitor/perf_monitor.sh"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || fail "$label: expected='$expected' actual='$actual'"
  echo "[ok] $label"
}

bash -n "$SCRIPT"

export PERF_MONITOR_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$SCRIPT"
unset PERF_MONITOR_SOURCE_ONLY

diskstats_file=$(mktemp)
trap 'rm -f "$diskstats_file"' EXIT

cat > "$diskstats_file" <<'DATA'
   8       0 sda 1 0 100 0 2 0 200 0 0 0 0 0 0 0
   8       1 sda1 1 0 999 0 2 0 999 0 0 0 0 0 0 0
 253       0 dm-0 1 0 300 0 2 0 400 0 0 0 0 0 0 0
 104       0 cciss/c0d0 1 0 500 0 2 0 600 0 0 0 0 0 0 0
  94       0 dasda 1 0 700 0 2 0 800 0 0 0 0 0 0 0
DATA

export PERF_MONITOR_DISKSTATS="$diskstats_file"
export PERF_MONITOR_LSBLK_OUTPUT=$'sda disk\nsda1 part\ndm-0 lvm'
assert_eq "100 200" "$(_disk_stat)" "lsblk がある場合は物理ディスクのみ集計する"

unset PERF_MONITOR_LSBLK_OUTPUT
export PERF_MONITOR_SKIP_LSBLK=1
assert_eq "1600 2000" "$(_disk_stat)" "lsblk が使えない場合は SUSE/RHEL 系デバイス名を拾う"
unset PERF_MONITOR_SKIP_LSBLK

export PERF_MONITOR_DF_OUTPUT=$'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 50 50 50% /\nautofs 0 0 0 - /net\ntmpfs 1 1 0 100% /run'
assert_eq '"/":50' "$(printf '%s' "$(_disk_usage_json)")" "df の非数値 Capacity と仮想マウントを除外する"

echo "[ok] perf-monitor Linux smoke completed"
