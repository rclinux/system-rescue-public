#!/usr/bin/env bash
# verify-backup.sh — re-check a stored backup WITHOUT restoring it.
#
# A backup you cannot re-check is a backup you are only assuming is good.
# The restore engine has always verified the image set before erasing a
# target, but reaching that check meant starting a restore, which means
# having a disk you are willing to lose. This runs the same verification
# on its own.
#
# STRICTLY READ-ONLY: it opens no block devices, mounts nothing, writes
# nothing, and needs no root. Safe to run against the vault drive while
# the machine is doing anything else.
#
# Usage:
#   verify-backup.sh <job-dir>          verify one backup job
#   verify-backup.sh --all <dest-root>  verify every job under a destination
#
# Exit status is the point: 0 means every job checked is sound, 1 means at
# least one is not. SR_DEEP_VERIFY=0 drops to checksums only, which is much
# faster and much weaker — it can no longer tell a whole image from a
# truncated one.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/verify_engine.sh
source "$SCRIPT_DIR/../lib/verify_engine.sh"

usage() {
    echo "Usage: $0 <job-dir>" >&2
    echo "       $0 --all <destination-root>" >&2
    exit 1
}

for t in jq sha256sum zstd python3; do
    command -v "$t" >/dev/null || { log_error "missing required tool: $t"; exit 1; }
done
# Never silently downgrade a requested deep check. The image engine
# reports a failed structural check if its required checker is missing.

ALL=0
if [[ "${1:-}" == "--all" ]]; then
    ALL=1
    shift
fi
[[ $# -eq 1 ]] || usage
ROOT="$1"
[[ -d "$ROOT" ]] || { log_error "not a directory: $ROOT"; exit 1; }

declare -a JOBS=()
if (( ALL )); then
    # A job dir is identified by holding a manifest.json, not by its
    # name — the timestamped folder name is a convenience for humans and
    # nothing in the tool parses it. _archive/ and any other nesting the
    # user has imposed therefore come along without special-casing.
    while IFS= read -r m; do
        JOBS+=("$(dirname "$m")")
    done < <(find "$ROOT" -maxdepth 3 -name manifest.json -type f | sort)
    if [[ ${#JOBS[@]} -eq 0 ]]; then
        log_error "no backup jobs (no manifest.json) found under $ROOT"
        exit 1
    fi
    log_info "found ${#JOBS[@]} backup job(s) under $ROOT"
else
    JOBS=("$ROOT")
fi

pass=0
fail=0
declare -a FAILED=()
for job in "${JOBS[@]}"; do
    echo
    if verify_backup_job "$job"; then
        log_info "RESULT: PASS — $job"
        pass=$((pass + 1))
    else
        log_error "RESULT: FAIL — $job"
        fail=$((fail + 1))
        FAILED+=("$job")
    fi
done

echo
log_info "=================================================================="
log_info "verified ${#JOBS[@]} job(s):  $pass passed, $fail failed"
if (( fail > 0 )); then
    # Name them again at the end. On a multi-job run the failure has
    # scrolled off by now, and "some of them were fine" is not the part
    # anyone needs to leave with.
    log_error "these backups did NOT verify — do not rely on them:"
    for job in "${FAILED[@]}"; do
        log_error "    $job"
    done
    log_info "=================================================================="
    exit 1
fi
log_info "=================================================================="
exit 0
