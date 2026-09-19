#!/usr/bin/env bash
# list-disks.sh — Phase 1 test harness: print every disk system_rescue
# would currently offer as a backup source / restore target, plus
# (separately) every disk it's excluding as busy/boot-media.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/disk_detect.sh
source "$SCRIPT_DIR/../lib/disk_detect.sh"

echo "Candidate disks (safe to offer for backup/restore):"
printf '  %-10s %-8s %-24s %-20s %s\n' "NAME" "SIZE" "MODEL" "SERIAL" "STABLE PATH"
found=0
while IFS=$'\t' read -r name size model serial byid; do
    [[ -z "$name" ]] && continue
    found=1
    printf '  %-10s %-8s %-24s %-20s %s\n' "$name" "$size" "$model" "$serial" "$byid"
done < <(list_candidate_disks)
(( found )) || echo "  (none found)"

echo
echo "Excluded as busy/boot-media (never offered):"
mapfile -t excluded < <(busy_disks)
if (( ${#excluded[@]} == 0 )); then
    echo "  (none)"
else
    printf '  %s\n' "${excluded[@]}"
fi
