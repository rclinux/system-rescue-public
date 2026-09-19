#!/usr/bin/env bash
# restore-disk.sh — Phase 3 test harness: restore a backup job onto a
# target disk from the command line. Plain CLI, no menu — the gum UI
# comes in Phase 4.
#
# THIS ERASES THE TARGET DISK.
#
# Usage: restore-disk.sh <job-dir> <target-disk-path>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/disk_detect.sh"
source "$SCRIPT_DIR/../lib/partition_table.sh"
source "$SCRIPT_DIR/../lib/verify_engine.sh"
source "$SCRIPT_DIR/../lib/restore_engine.sh"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <job-dir> <target-disk-path>" >&2
    exit 1
fi

job_dir="$1"
target="$2"
manifest="$job_dir/manifest.json"

[[ -f "$manifest" ]] || { echo "No manifest.json in $job_dir" >&2; exit 1; }
[[ -b "$target" ]]   || { echo "$target is not a block device" >&2; exit 1; }

tname=$(lsblk -dno KNAME "$target")
ttoken=$(disk_confirm_token "$target")

echo
echo "======================= RESTORE SUMMARY ======================="
echo "SOURCE (from backup manifest)"
jq -r '"  taken:  \(.created_at)
  disk:   \(.source_disk.name)
  model:  \(.source_disk.model)
  serial: \(.source_disk.serial)
  size:   \(.source_disk.size) (\(.source_disk.size_bytes) bytes)"' "$manifest"
echo
echo "TARGET (WILL BE COMPLETELY ERASED)"
printf '  disk:   %s\n' "$tname"
printf '  model:  %s\n' "$(lsblk -dno MODEL "$target")"
printf '  serial: %s\n' "${ttoken:-<none>}"
printf '  size:   %s (%s bytes)\n' "$(lsblk -dno SIZE "$target")" "$(lsblk -bdno SIZE "$target")"
echo
echo "Contents of the target disk that will be destroyed:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$target" | sed 's/^/  /'
echo "==============================================================="
echo
echo "Everything on $tname will be PERMANENTLY DESTROYED."
echo "To confirm, type the target disk's serial number exactly:"
printf '  serial> '
read -r typed

if [[ "$typed" != "$ttoken" ]]; then
    echo
    echo "Serial did not match. Nothing was written. Aborting."
    exit 1
fi

echo
restore_disk "$job_dir" "$target" "$typed"
