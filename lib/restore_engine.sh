#!/usr/bin/env bash
# restore_engine.sh — write a backup job back onto a target disk.
#
# THIS DESTROYS EVERYTHING ON THE TARGET DISK.
#
# Design rule: every check that can be made happens BEFORE the first
# destructive write. In particular the whole backup is checksum-
# verified up front, because discovering a corrupt image after the
# target has been zapped means losing both copies. That verification
# costs a full read pass over the image set; SR_SKIP_VERIFY=1 skips
# it, which trades the only guarantee that the backup is intact for
# some wall-clock time. Not recommended.
#
# The engine never prompts. The caller (CLI/TUI) collects the human's
# typed confirmation and passes the serial it was given; the engine
# then independently re-reads the target's serial and refuses to
# proceed unless the two agree. A wrong disk selection therefore has
# to survive two independent identifications to do any damage.

# _target_partition_map DISK: emit "PARTNUM<TAB>/dev/NAME" for each
# partition currently visible on DISK.
_target_partition_map() {
    local disk="$1" line key val pnum pname ptype
    while IFS= read -r line; do
        pnum="" pname="" ptype=""
        while IFS=$'\x1f' read -r key val; do
            case "$key" in
                PARTN) pnum="$val" ;; NAME) pname="$val" ;; TYPE) ptype="$val" ;;
            esac
        done < <(_parse_lsblk_pairs "$line")
        [[ "$ptype" == "part" ]] || continue
        [[ -n "$pnum" && -n "$pname" ]] || continue
        printf '%s\t/dev/%s\n' "$pnum" "$pname"
    done < <(lsblk -Pno PARTN,NAME,TYPE "$disk" 2>/dev/null)
}

# _disk_has_mounted_filesystem DISK: true if the disk or any of its
# partitions currently backs a mounted filesystem.
_disk_has_mounted_filesystem() {
    local disk="$1" name child
    name=$(lsblk -dno KNAME "$disk" 2>/dev/null) || return 1
    while read -r child; do
        [[ -n "$child" ]] || continue
        findmnt -rno TARGET "/dev/$child" &>/dev/null && return 0
    done < <(lsblk -no KNAME "/dev/$name" 2>/dev/null)
    return 1
}

# _uuid_collisions MANIFEST TARGET
# Prints one \x1f-delimited "number|uuid|where" line per manifest filesystem
# UUID that ALREADY EXISTS on some device outside TARGET. Silent if none.
#
# Why this matters, and why it is not a bug in the restore:
# a faithful restore reproduces the source's filesystem UUIDs -- that is
# precisely what makes it faithful, and what lets a restored system boot.
# But when the target is a SECOND disk in the SAME machine, each of those
# UUIDs now exists TWICE, and /etc/fstab and /etc/crypttab identify
# filesystems BY UUID. Which copy wins at boot depends on device enumeration
# order, which on real hardware is NOT stable (eight distinct mappings
# observed on the development machine). The result is a system that boots
# correctly once and then fails to reach a login prompt on some later boot.
#
# Believed root cause of the 2026-07-30 emergency restore: a COSMIC image was
# restored onto a spare disk to test it -- exactly the right instinct -- and
# left two filesystems claiming the root UUID and two claiming the crypttab
# swap UUID. Nothing warned anyone, because every individual step was correct.
#
# Uses lsblk (udev database), NOT blkid: cached blkid output has already lied
# on this project once, reporting a UUID from a filesystem destroyed twenty
# minutes earlier.
_uuid_collisions() {
    local manifest="$1" target="$2"
    local tgt_real partition_prefix path uuid real num u
    tgt_real=$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")

    partition_prefix="$tgt_real"
    [[ "$partition_prefix" == *[0-9] ]] && partition_prefix+=p

    local -A live=()
    while read -r path uuid; do
        # An empty subscript is a hard error in bash, so guard before use.
        [[ -n "${uuid:-}" ]] || continue
        real=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
        # Skip the target's own partitions: they are about to be erased.
        [[ "$real" == "$tgt_real" || "$real" =~ ^"$partition_prefix"[0-9]+$ ]] && continue
        live["$uuid"]="${live[$uuid]:+${live[$uuid]}, }$real"
    done < <(lsblk -rno PATH,UUID 2>/dev/null)

    while IFS=$'\x1f' read -r num u; do
        [[ -n "$u" && "$u" != "null" ]] || continue
        [[ -n "${live[$u]:-}" ]] || continue
        printf '%s\x1f%s\x1f%s\n' "$num" "$u" "${live[$u]}"
    done < <(jq -r '.partitions[] | "\(.number)\u001f\(.uuid)"' "$manifest" 2>/dev/null)
}

# report_uuid_collisions MANIFEST TARGET PHASE
# PHASE is "before" (advisory, you can still abort) or "after" (the one that
# matters -- it is the last thing on screen before the machine is rebooted).
# Returns 0 if collisions were reported, 1 if the disks are clean.
report_uuid_collisions() {
    local manifest="$1" target="$2" phase="$3"
    local lines num uuid where
    lines=$(_uuid_collisions "$manifest" "$target")
    [[ -n "$lines" ]] || return 1

    if [[ "$phase" == "before" ]]; then
        log_info "NOTE: this restore will duplicate filesystem UUIDs already on this machine:"
    else
        log_info "=================================================================="
        log_info "ACTION REQUIRED BEFORE YOU REBOOT"
        log_info "=================================================================="
    fi

    while IFS=$'\x1f' read -r num uuid where; do
        [[ -n "$num" ]] || continue
        log_info "  partition $num  uuid=$uuid"
        log_info "      same UUID already present on: $where"
    done <<< "$lines"

    if [[ "$phase" == "before" ]]; then
        log_info "  That is correct behaviour for a restore, but see the warning"
        log_info "  printed at the end before rebooting this machine."
    else
        log_info ""
        log_info "  $target now holds filesystems whose UUIDs are IDENTICAL to ones"
        log_info "  already in this machine. /etc/fstab and /etc/crypttab find"
        log_info "  filesystems BY UUID, so the next boot may pick the WRONG copy."
        log_info "  Device enumeration order is not stable, so it may work once and"
        log_info "  fail later. This can leave the system unable to reach a login."
        log_info ""
        log_info "  Do ONE of these before rebooting into the installed system:"
        log_info "    * physically remove or power off $target, OR"
        log_info "    * disconnect the original disk and boot only the restored copy."
        log_info ""
        log_info "  This does NOT apply if you are restoring the machine's own system"
        log_info "  disk -- in that case the old copy is gone and there is no clash."
        log_info "=================================================================="
    fi
    return 0
}

# validate_restore JOB_DIR TARGET CONFIRMED_SERIAL
# Runs every safety check. Writes nothing. Non-zero exit means the
# restore must not proceed.
validate_restore() {
    local job_dir="$1" target="$2" confirmed_serial="$3"
    local manifest="$job_dir/manifest.json"
    local ok=1

    validate_backup_metadata "$job_dir" "$manifest" || return 1

    if [[ "${SR_SKIP_VERIFY:-0}" == "1" ]]; then
        log_info "WARNING: SR_SKIP_VERIFY=1 — backup integrity NOT verified before erase"
    else
        log_info "verifying backup integrity before touching the target..."
        # The image checks themselves live in verify_engine.sh so that
        # bin/verify-backup.sh can run exactly the same verification
        # WITHOUT a target disk. Two copies of this logic would be two
        # things to keep true; a backup passing one and failing the
        # other is the kind of contradiction a rescue tool cannot afford.
        verify_backup_images "$job_dir" "$manifest" || ok=0
    fi

    # --- target sanity ----------------------------------------------------
    if [[ ! -b "$target" ]]; then
        log_error "target $target is not a block device"
        return 1
    fi

    local ttype
    ttype=$(lsblk -dno TYPE "$target" 2>/dev/null)
    if ! _is_selectable_disk_type "$ttype"; then
        log_error "target $target is not a whole disk (type=$ttype)"
        ok=0
    fi

    if _disk_has_mounted_filesystem "$target"; then
        log_error "target $target has a mounted filesystem — refusing to erase it"
        ok=0
    fi

    # The candidate list already excludes busy disks and the live boot
    # medium; requiring membership means the target can never be the
    # running system's own disk.
    local tkname candidate_ok=0 cname
    tkname=$(lsblk -dno KNAME "$target" 2>/dev/null)
    while IFS=$'\t' read -r cname _ _ _ _; do
        [[ "$cname" == "$tkname" ]] && { candidate_ok=1; break; }
    done < <(list_candidate_disks)
    if (( ! candidate_ok )); then
        log_error "target $target is not an eligible disk (busy, boot media, or virtual)"
        ok=0
    fi

    local source_sector target_sector
    source_sector=$(python3 "$(dirname -- "${BASH_SOURCE[0]}")/validate_table.py" "$manifest" --sector-size) || return 1
    target_sector=$(lsblk -bdnr -o LOG-SEC "$target") || return 1
    if [[ "$source_sector" != "$target_sector" ]]; then
        log_error "source/target logical sector sizes differ: $source_sector != $target_sector"
        ok=0
    fi

    # --- identity confirmation -------------------------------------------
    # Re-derived independently of whatever the UI displayed, so a wrong
    # disk has to survive two separate identifications to be erased.
    local ttoken
    ttoken=$(disk_confirm_token "$target") || ttoken=""
    if [[ -z "$confirmed_serial" || -z "$ttoken" || "$confirmed_serial" != "$ttoken" ]]; then
        log_error "identity confirmation failed: caller confirmed '${confirmed_serial:-<empty>}' but $target reports '${ttoken:-<none>}'"
        ok=0
    fi

    # --- capacity ---------------------------------------------------------
    local src_bytes tgt_bytes
    src_bytes=$(jq -r '.source_disk.size_bytes' "$manifest")
    tgt_bytes=$(lsblk -bdno SIZE "$target" 2>/dev/null)
    if [[ -z "$tgt_bytes" || -z "$src_bytes" ]]; then
        log_error "could not determine source/target sizes"
        ok=0
    elif (( tgt_bytes < src_bytes )); then
        log_error "target is smaller than source: $tgt_bytes < $src_bytes bytes"
        ok=0
    fi

    (( ok )) || return 1
    # Advisory only — this never blocks a restore. Restoring onto a second
    # disk is a legitimate and encouraged way to TEST a system backup; the
    # hazard is leaving it there at reboot, which is what the "after" report
    # covers. Mentioning it here lets the operator abort if it was a mistake.
    report_uuid_collisions "$manifest" "$target" before || true

    log_info "all pre-restore checks passed"
    return 0
}

# restore_disk JOB_DIR TARGET CONFIRMED_SERIAL
# DESTRUCTIVE. Validates, then erases and rewrites TARGET.
restore_disk() {
    require_root
    local job_dir="$1" target="$2" confirmed_serial="$3"
    local manifest="$job_dir/manifest.json"

    # `local` is dynamically scoped in bash, so every function called
    # from here logs to this file too, and it is restored on return —
    # no global left set for the next menu action to inherit.
    local SR_LOG_FILE="${SR_LOG_FILE:-}"
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    if open_log_file "$job_dir/restore_${ts}.log"; then
        log_info "restore log: $job_dir/restore_${ts}.log (survives the reboot)"
    else
        log_info "NOTE: could not write a restore log to $job_dir"
        log_info "  this run is screen-only — photograph anything that matters"
    fi

    validate_restore "$job_dir" "$target" "$confirmed_serial" || {
        log_error "validation failed — nothing was written to $target"
        return 1
    }

    # One partclone log PER PARTITION, same reasoning as the backup side
    # (see backup_engine.sh): partclone opens -L for writing, not
    # appending, so a single shared path is TRUNCATED on every invocation
    # and only the last partition's log survives. Confirmed on the
    # 2026-07-29 COSMIC restore rehearsal — a four-partition restore left
    # one 644-byte log holding partition 3 alone, so the vfat ESP and
    # recovery records were gone. Harmless there only because the run
    # succeeded; a FAILED multi-partition restore is exactly when those
    # records matter most.
    local logfile_base="$job_dir/partclone_restore_${ts}"
    local pttype ptfile
    pttype=$(jq -r '.partition_table.type' "$manifest")
    ptfile=$(jq -r '.partition_table.dump_file' "$manifest")

    log_info "ERASING $target and restoring from $job_dir"

    sgdisk --zap-all "$target" >/dev/null 2>&1 || true
    wipefs -a "$target" >/dev/null 2>&1 || true
    partprobe "$target" >/dev/null 2>&1 || true

    log_info "restoring $pttype partition table"
    restore_partition_table "$target" "$pttype" "$job_dir/$ptfile" || {
        log_error "partition table restore failed — target is now in an INCONSISTENT state"
        return 1
    }

    # Get the kernel to re-read the new table. partprobe alone is
    # unreliable for loopback devices, so partx -u is used as a
    # fallback before waiting on udev to create the device nodes.
    partprobe "$target" >/dev/null 2>&1 || true
    command -v partx >/dev/null 2>&1 && partx -u "$target" >/dev/null 2>&1 || true
    udevadm settle --timeout=30 >/dev/null 2>&1 || true

    local -A partmap=()
    local pnum pdev
    while IFS=$'\t' read -r pnum pdev; do
        partmap["$pnum"]="$pdev"
    done < <(_target_partition_map "$target")

    # Fields are \x1f-separated, not tab-separated. Tab is an IFS
    # *whitespace* character, so `IFS=$'\t' read` silently collapses
    # runs of consecutive tabs into a single delimiter — and a swap
    # entry has three empty fields in a row (no tool, no image, no
    # label), which shifts every later field into the wrong variable.
    # \x1f is not IFS whitespace, so empty fields survive intact.
    local num method tool img uuid label expected_size actual_size
    while IFS=$'\x1f' read -r num method tool img uuid label expected_size; do
        pdev="${partmap[$num]:-}"
        if [[ -z "$pdev" || ! -b "$pdev" ]]; then
            log_error "partition $num did not appear on $target after table restore"
            return 1
        fi

        actual_size=$(lsblk -bdno SIZE "$pdev") || return 1
        if [[ "$actual_size" != "$expected_size" ]]; then
            log_error "partition $num size after table restore differs from manifest"
            return 1
        fi
        case "$method" in
            mkswap)
                # A blank UUID here means the manifest was written or
                # parsed wrongly. Letting mkswap generate a random one
                # would look like success while silently breaking any
                # /etc/crypttab or /etc/fstab entry that resolves swap
                # by UUID, so refuse instead.
                if [[ -z "$uuid" ]]; then
                    log_error "partition $num: swap UUID missing from manifest — refusing to generate a random one"
                    return 1
                fi
                log_info "  partition $num: recreating swap (uuid=$uuid)"
                local -a mkswap_args=(-U "$uuid")
                [[ -n "$label" ]] && mkswap_args+=(-L "$label")
                mkswap "${mkswap_args[@]}" "$pdev" >/dev/null || {
                    log_error "mkswap failed on $pdev"
                    return 1
                }
                ;;
            partclone)
                log_info "  partition $num: restoring $img via $tool"
                local plog="${logfile_base}_part${num}.log"
                if ! ( set -o pipefail
                       zstd -dc "$job_dir/$img" | partclone.restore -q -L "$plog" -s - -O "$pdev" ); then
                    log_error "restore of partition $num failed"
                    return 1
                fi
                ;;
            rawdd)
                # Raw byte image — partclone.restore would reject it
                # ("This is not partclone image"), so replay it with dd.
                log_info "  partition $num: restoring $img raw via dd"
                if ! ( set -o pipefail
                       zstd -dc "$job_dir/$img" | dd of="$pdev" bs=4M conv=fsync status=none ); then
                    log_error "raw restore of partition $num failed"
                    return 1
                fi
                ;;
            *)
                log_error "unknown restore_method '$method' for partition $num"
                return 1
                ;;
        esac
    done < <(jq -r '.partitions[]
                    | "\(.number)\u001f\(.restore_method)\u001f\(.partclone_tool)\u001f\(.image_file)\u001f\(.uuid)\u001f\(.label)\u001f\(.size_bytes)"' \
                   "$manifest")

    sync
    partprobe "$target" >/dev/null 2>&1 || true
    udevadm settle --timeout=30 >/dev/null 2>&1 || true

    verify_restored_data "$job_dir" "$target" || return 1

    log_info "restore complete onto $target"

    # LAST, deliberately: this is the final thing on screen before the operator
    # reboots, which is the exact moment the hazard becomes real. Printing it
    # earlier would let it scroll away behind the partclone output. It also
    # lands in the durable log, so it survives the live session.
    report_uuid_collisions "$job_dir/manifest.json" "$target" after || true
}

# verify_restored_data JOB_DIR TARGET
# Reads each restored filesystem back and compares its actual
# occupancy against what the source held at backup time.
#
# This is the check whose absence made an earlier round trip
# unfalsifiable: every command succeeded, so the tool said "restore
# complete", and only manual inspection days later could establish
# whether 64GB or nothing at all had landed. Exit codes prove that
# no command errored; they do not prove that data arrived. This does.
#
# Requires manifest v4. A v3 backup carries no recorded occupancy, so
# verification is impossible and says so rather than staying quiet —
# an unverified restore must never read as a verified one.
verify_restored_data() {
    local job_dir="$1" target="$2"
    local manifest="$job_dir/manifest.json"
    local mver
    mver=$(jq -r '.system_rescue_manifest_version // 0' "$manifest")

    if [[ "$mver" == "3" ]]; then
        log_info "NOT VERIFIED: this is a v3 backup, which records no occupancy figures."
        log_info "  The restore reported no errors, but nothing here has confirmed that"
        log_info "  data actually landed. Take a fresh backup to get a verifiable one."
        return 0
    fi

    local -A partmap=()
    local pnum pdev
    while IFS=$'\t' read -r pnum pdev; do
        partmap["$pnum"]="$pdev"
    done < <(_target_partition_map "$target")

    log_info "comparing restored filesystem occupancy against the manifest..."
    log_info "Occupancy checks do not verify file contents or bootability."

    local num fstype exp_used exp_inodes stats got_used got_inodes
    local checked=0 failed=0 bytes_only=0
    while IFS=$'\x1f' read -r num fstype exp_used exp_inodes; do
        [[ -n "$num" ]] || continue
        # null means the source could not be measured, so there is
        # nothing to compare against. Say so; do not score it a pass.
        if [[ "$exp_used" == "null" || -z "$exp_used" ]]; then
            log_info "  partition $num: source occupancy was never measured — cannot verify"
            continue
        fi

        pdev="${partmap[$num]:-}"
        if [[ -z "$pdev" || ! -b "$pdev" ]]; then
            log_error "  partition $num: device missing after restore"
            failed=1
            continue
        fi

        if [[ "$fstype" == btrfs && -n "$(_uuid_collisions "$manifest" "$target")" ]]; then
            log_info "  partition $num: occupancy check skipped while duplicate UUIDs exist; isolate the restored disk first"
            continue
        fi
        if ! stats=$(_probe_fs_stats "$pdev" "$fstype"); then
            log_error "  partition $num: restored filesystem could not be mounted to verify"
            failed=1
            continue
        fi
        IFS=$'\x1f' read -r got_used got_inodes <<<"$stats"
        checked=$((checked + 1))

        # Whether the inode comparison can run at all decides what this
        # partition's "ok" line is allowed to claim. vfat reports no
        # usable inode count, so on the EFI and recovery partitions of a
        # real COSMIC restore only the byte figure is comparable. An
        # earlier version ran this same guard but printed "(matches
        # source)" regardless — a check that skipped itself and still
        # reported green, which is this project's recurring defect.
        # State which comparison actually ran, every time.
        local inode_cmp=0
        [[ "$exp_inodes" =~ ^[0-9]+$ && "$got_inodes" =~ ^[0-9]+$ ]] && inode_cmp=1

        # Inode count must match exactly — a block-level restore
        # reproduces the source superblock verbatim, so any difference
        # means the filesystem is not the one that was imaged.
        if (( inode_cmp )); then
            if [[ "$got_inodes" != "$exp_inodes" ]]; then
                log_error "  partition $num: INODE COUNT MISMATCH — source had $exp_inodes, restored has $got_inodes"
                failed=1
                continue
            fi
        fi

        # Bytes get a small tolerance: a mount can settle allocation
        # metadata by a few blocks without the content differing.
        local delta=$(( got_used > exp_used ? got_used - exp_used : exp_used - got_used ))
        if (( delta > 1048576 )); then
            log_error "  partition $num: USED-SPACE MISMATCH — source held $(fmt_bytes "$exp_used"), restored holds $(fmt_bytes "$got_used")"
            failed=1
            continue
        fi

        if (( inode_cmp )); then
            log_info "  partition $num: ok — $(fmt_bytes "$got_used") / $got_inodes inodes (used bytes and inode count both match source)"
        else
            bytes_only=$((bytes_only + 1))
            log_info "  partition $num: ok — $(fmt_bytes "$got_used") used, matches source within 1MiB"
            log_info "    BYTES ONLY: ${fstype:-this filesystem} reports no usable inode count, so"
            log_info "    the number of files was NOT verified. Matching bytes is weaker"
            log_info "    evidence than a matching inode count."
        fi

        if fs_looks_empty "$exp_used" "$exp_inodes"; then
            log_info "    NOTE: the SOURCE filesystem was empty, so this restored an empty"
            log_info "    filesystem. That is correct behaviour, not data loss. The byte"
            log_info "    figure is mkfs structure (inode tables, journal), not files."
        fi
    done < <(jq -r '.partitions[] | select(.restore_method=="partclone")
                    | "\(.number)\(.fstype)\(.fs_used_bytes)\(.fs_inodes_used)"' \
                   "$manifest")

    if (( failed )); then
        log_error "POST-RESTORE VERIFICATION FAILED — the target does not match the backup"
        return 1
    fi
    if (( checked == 0 )); then
        log_info "post-restore verification: nothing could be verified (no measurable filesystems)"
    elif (( bytes_only )); then
        log_info "post-restore verification passed on $checked filesystem(s): $((checked - bytes_only)) matched used bytes + inode counts, $bytes_only by used bytes only"
    else
        log_info "post-restore verification passed on $checked filesystem(s)"
    fi
    return 0
}
