#!/usr/bin/env bash
# backup-disk.sh — Phase 2 test harness: back up one disk to a
# destination directory from the command line. Plain CLI, no menu —
# the gum-based picker comes in Phase 4.
#
# Usage: backup-disk.sh <source-disk-path> <destination-dir>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/disk_detect.sh
source "$SCRIPT_DIR/../lib/disk_detect.sh"
# shellcheck source=../lib/partition_table.sh
source "$SCRIPT_DIR/../lib/partition_table.sh"
# shellcheck source=../lib/backup_engine.sh
source "$SCRIPT_DIR/../lib/backup_engine.sh"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <source-disk-path> <destination-dir>" >&2
    exit 1
fi

job_dir=$(backup_disk "$1" "$2")
echo "Job folder: $job_dir"
