#!/usr/bin/env bash
# verify_engine.sh — check that a stored backup is still intact, without
# restoring it and without touching any disk.
#
# Why this is its own engine rather than a corner of the restore:
# the restore has always verified the image set before erasing anything,
# but that check was only reachable BY STARTING A RESTORE — which needs a
# target disk you are willing to destroy. So the one question you actually
# want to ask a backup sitting on the vault drive ("is it still good?")
# was the one question the tool could not answer. The backup drive has
# already silently truncated one file; a backup nobody can re-check is a
# backup nobody should trust.
#
# Everything here is READ-ONLY. It opens no block devices, mounts nothing
# and needs no root — it reads files in the job directory and nothing else.
#
# The checks, weakest to strongest:
#   1. completeness — every image the manifest names is present, and no
#      unexpected image is sitting in the job dir
#   2. sha256      — each image still hashes to what the manifest recorded
#   3. structure   — the compressed stream and the image inside it are
#      internally coherent (see _verify_one_image for why 2 is not enough)

# Validate metadata even when the caller explicitly skips image checks.
# Validate saved geometry before any image processing or target access.
validate_backup_metadata() {
    local job_dir="$1" manifest="$2" ptfile schema
    schema="$(dirname -- "${BASH_SOURCE[0]}")/manifest.jq"
    if ! jq -e -s -f "$schema" "$manifest" >/dev/null 2>&1; then
        log_error "invalid or incomplete backup manifest: $manifest"
        return 1
    fi
    ptfile=$(jq -r '.partition_table.dump_file' "$manifest") || return 1
    if [[ ! -f "$job_dir/$ptfile" || ! -s "$job_dir/$ptfile" ]]; then
        log_error "partition table dump missing or empty: $job_dir/$ptfile"
        return 1
    fi
    python3 "$(dirname -- "${BASH_SOURCE[0]}")/validate_table.py" "$manifest" || return 1
}

# _verify_stray_images JOB_DIR MANIFEST
# Report image files present in the job dir that the manifest does not
# name. A stray image is not corruption, but it means the directory is not
# the tidy unit it looks like — usually a half-finished second backup
# written into the same folder, and the next person to read a file listing
# will assume it belongs. Advisory: it does not fail the run.
_verify_stray_images() {
    local job_dir="$1" manifest="$2" f base found=0
    local -A named=()
    local img
    while read -r img; do
        [[ -n "$img" ]] && named["$img"]=1
    done < <(jq -r '.partitions[] | select(.image_file != null and .image_file != "")
                    | .image_file' "$manifest" 2>/dev/null)

    for f in "$job_dir"/*.img.zst "$job_dir"/*.img; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f")
        [[ -n "${named[$base]:-}" ]] && continue
        log_info "  NOTE: $base is in the job dir but not named in the manifest"
        found=1
    done
    return $(( found ? 0 : 1 ))
}

# _verify_one_image JOB_DIR IMAGE EXPECTED_SHA METHOD
# Verify a single image. Returns non-zero on any failure, and emits the
# exact wording the restore engine has always used — the negative tests
# assert on these strings, and a rescue tool's error text is part of its
# interface, not decoration.
_verify_one_image() {
    local job_dir="$1" img="$2" sum="$3" method="$4" expected_bytes="${5:-}" actual

    if [[ ! -f "$job_dir/$img" ]]; then
        log_error "image file missing: $job_dir/$img"
        return 1
    fi

    # sha256 proves the file still matches what was written.
    actual=$(sha256sum "$job_dir/$img" | awk '{print $1}')
    if [[ "$actual" != "$sum" ]]; then
        log_error "checksum mismatch on $img (backup is corrupt)"
        return 1
    fi

    # ...but a checksum taken over a TRUNCATED image still matches that
    # truncated image perfectly, so a hash alone cannot tell a whole
    # backup from half of one. Only a reader that understands the format
    # can attest the image is structurally complete, so ask one. This
    # costs a full decompress pass; SR_DEEP_VERIFY=0 skips it.
    if [[ "${SR_DEEP_VERIFY:-1}" != "1" ]]; then
        log_info "  ok: $img (checksum)"
        return 0
    fi

    case "$method" in
        partclone)
            # partclone.chkimg walks the image's own bitmap and block
            # index, so it catches damage the hash cannot: it is the
            # strongest statement available that this image would restore.
            if ( set -o pipefail
                 zstd -dc "$job_dir/$img" | partclone.chkimg -s - -L /dev/null ) >/dev/null 2>&1; then
                log_info "  ok: $img (checksum + partclone structure)"
            else
                log_error "$img fails partclone integrity check (damaged or incomplete image)"
                return 1
            fi
            ;;
        rawdd)
            # rawdd images are raw bytes with no partclone header, so
            # chkimg cannot read them and they used to get sha256 only.
            # zstd -t still decompresses the whole stream and checks its
            # frame checksums, which catches a truncated or corrupted
            # container even though nothing can validate the bytes inside.
            if zstd -t "$job_dir/$img" >/dev/null 2>&1; then
                local actual_bytes
                actual_bytes=$(set -o pipefail; zstd -dc "$job_dir/$img" | wc -c) || return 1
                if [[ "$actual_bytes" != "$expected_bytes" ]]; then
                    log_error "$img raw size differs from partition: $actual_bytes != $expected_bytes"
                    return 1
                fi
                log_info "  ok: $img (checksum + zstd stream + exact raw size)"
            else
                log_error "$img fails zstd integrity check (truncated or corrupt stream)"
                return 1
            fi
            ;;
        *)
            log_info "  ok: $img (checksum; no structural check for method '$method')"
            ;;
    esac
    return 0
}

# verify_backup_images JOB_DIR MANIFEST
# Run checks 1-3 over every imaged partition in the manifest. Returns 0
# if the whole image set is sound, 1 if anything failed. Callers decide
# what a failure means: the restore engine refuses to erase a target, the
# standalone CLI just reports.
verify_backup_images() {
    local job_dir="$1" manifest="$2"
    local ok=1 img sum method bytes n=0
    validate_backup_metadata "$job_dir" "$manifest" || return 1

    while IFS=$'\x1f' read -r img sum method bytes; do
        [[ -n "$img" ]] || continue
        n=$((n + 1))
        _verify_one_image "$job_dir" "$img" "$sum" "$method" "$bytes" || ok=0
    done < <(jq -r '.partitions[] | select(.restore_method!="mkswap")
                    | "\(.image_file)\u001f\(.checksum_sha256)\u001f\(.restore_method)\u001f\(.size_bytes)"' "$manifest")

    # Even if parsing fails after metadata validation, never report an
    # empty image set as verified.
    if (( n == 0 )); then
        log_error "this manifest names no partition images to verify"
        return 1
    fi

    _verify_stray_images "$job_dir" "$manifest" || true

    return $(( ok ? 0 : 1 ))
}

# verify_backup_job JOB_DIR
# Full standalone verification of one backup job directory: manifest,
# version, partition-table dump, then the image set. Returns 0 on a clean
# bill of health.
verify_backup_job() {
    local job_dir="$1"
    local manifest="$job_dir/manifest.json"
    local ok=1 mver created serial

    [[ -d "$job_dir" ]] || { log_error "not a directory: $job_dir"; return 1; }
    validate_backup_metadata "$job_dir" "$manifest" || return 1
    mver=$(jq -r '.system_rescue_manifest_version' "$manifest")

    created=$(jq -r '.created_at // "unknown"' "$manifest")
    serial=$(jq -r '.source_disk.serial // "unknown"' "$manifest")
    log_info "job:     $job_dir"
    log_info "created: $created   source serial: $serial   manifest v$mver"

    verify_backup_images "$job_dir" "$manifest" || ok=0

    return $(( ok ? 0 : 1 ))
}
