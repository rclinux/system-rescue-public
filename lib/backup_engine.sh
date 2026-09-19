#!/usr/bin/env bash
# backup_engine.sh — image a whole disk to a backup job folder,
# partition by partition, used-blocks-only via partclone.
#
# Manifest v4 notes (v4 = v3 plus fs_used_bytes / fs_inodes_used):
#   * Every partclone partition records what it actually held at
#     backup time: fs_used_bytes and fs_inodes_used, measured with a
#     read-only probe mount before imaging. Restore reads these back
#     off the restored filesystem and compares, so "restore complete"
#     means something checkable rather than merely "no command
#     returned an error". null means the probe could not measure it
#     (unmountable filesystem), and verification is skipped for that
#     partition rather than guessed at.
#   * fs_inodes_used is the honest "is there real data here" signal;
#     fs_used_bytes is not. See fs_looks_empty() below.
#
# Manifest v3 notes (still true in v4):
#   * Sizes are recorded in exact bytes. Human-readable sizes ("3.6T")
#     are kept only for display — two different disks can both render
#     as "3.6T" while differing by gigabytes, so the restore-time
#     size check must never use them.
#   * Each partition carries a restore_method:
#       partclone — filesystem partclone understands; used blocks only
#       rawdd     — anything else (LUKS, LVM PV, unformatted); raw copy
#       mkswap    — swap; no data imaged, recreated with mkswap -U
#     rawdd images are RAW BYTES, not partclone format. They cannot be
#     verified with partclone.chkimg and must not be restored with
#     partclone.restore.
#   * Swap carries no data worth preserving (on this system swap is
#     plain dm-crypt re-keyed from /dev/urandom every boot), so it is
#     not imaged. Its filesystem UUID must be preserved verbatim:
#     /etc/crypttab resolves swap by it, so losing it means the
#     restored system comes up with no swap.

declare -A _PARTCLONE_MAP=(
    [ext2]=partclone.ext2       [ext3]=partclone.ext3     [ext4]=partclone.ext4
    [xfs]=partclone.xfs         [btrfs]=partclone.btrfs   [ntfs]=partclone.ntfs
    [vfat]=partclone.vfat       [fat32]=partclone.fat32   [fat16]=partclone.fat16
    [fat12]=partclone.fat12     [exfat]=partclone.exfat   [f2fs]=partclone.f2fs
    [hfsplus]=partclone.hfsplus [minix]=partclone.minix   [reiser4]=partclone.reiser4
    [apfs]=partclone.apfs
)

# _restore_method_for FSTYPE: how this partition must be captured and
# replayed. See the manifest notes above.
_restore_method_for() {
    local fstype="$1"
    [[ "$fstype" == "swap" ]] && { echo mkswap; return; }
    # An unformatted partition reports an empty fstype, and bash
    # rejects an empty associative-array subscript outright — so the
    # emptiness must be checked before the lookup, not inside it.
    [[ -n "$fstype" ]] || { echo rawdd; return; }
    [[ -n "${_PARTCLONE_MAP[$fstype]:-}" ]] && { echo partclone; return; }
    echo rawdd
}

# _partclone_tool_for FSTYPE: the partclone binary for a filesystem,
# or "dd" for content partclone does not understand.
#
# Note: partclone.dd is deliberately NOT used for the raw fallback. It
# accepts neither -c nor -x, so the usual clone invocation silently
# degrades into printing its help text, and the images it writes are
# raw bytes rather than partclone format — which would then fail on
# restore. Plain dd is clearer and symmetric with the restore side.
_partclone_tool_for() {
    [[ -n "$1" ]] || { echo dd; return; }
    echo "${_PARTCLONE_MAP[$1]:-dd}"
}

# _ext_used_bytes PART_DEV: bytes partclone will actually have to read
# from an ext2/3/4 filesystem — total blocks minus free blocks, taken
# straight off the superblock with dumpe2fs.
#
# This exists because statvfs (what df calls "used", and what
# _probe_fs_stats returns) EXCLUDES ext4's static metadata. The inode
# table, block and inode bitmaps, journal and reserved GDT blocks are
# not counted as used space by df, but partclone must still copy every
# one of them. Measured on the 4TB Kingston: statvfs said
# 12,869,279,744 bytes while partclone actually moved 76,835,577,856 —
# a 6x gap of 64GB. The gap scales with DEVICE size (~1.6% of it), not
# with how much data is stored, so it grows with the disk and cannot be
# absorbed by a fixed margin. block_count - free_blocks reproduces
# partclone's "Space in use" EXACTLY (verified against partclone's own
# log on a real ext4: 58511 blocks both ways).
#
# Direction of error matters here: the space guard is a hard refusal,
# so an UNDER-estimate is a false GO that lets a doomed backup start
# and hit ENOSPC part-way through writing. Compression hid this for a
# long time — 76.8GB of mostly-zeroed inode tables compresses to about
# 10GB, so every real backup fit anyway.
#
# The superblock's free-block count can lag on a mounted, actively
# written filesystem. Nothing is mounted in the rescue environment, and
# this figure only feeds an estimate, so a slightly stale count is
# acceptable — but it must never be used for verification. The manifest
# keeps recording the statvfs figure, which restore compares on both
# sides and which is correct for that purpose.
_ext_used_bytes() {
    local dev="$1" out bc fb bs
    command -v dumpe2fs >/dev/null 2>&1 || return 1
    out=$(dumpe2fs -h "$dev" 2>/dev/null) || return 1
    # Anchored to ^ so "Reserved block count:" cannot be read as
    # "Block count:".
    bc=$(awk -F: '/^Block count:/ { gsub(/ /, "", $2); print $2; exit }' <<<"$out")
    fb=$(awk -F: '/^Free blocks:/ { gsub(/ /, "", $2); print $2; exit }' <<<"$out")
    bs=$(awk -F: '/^Block size:/  { gsub(/ /, "", $2); print $2; exit }' <<<"$out")
    [[ "$bc" =~ ^[0-9]+$ && "$fb" =~ ^[0-9]+$ && "$bs" =~ ^[0-9]+$ ]] || return 1
    (( bc >= fb )) || return 1
    echo $(( (bc - fb) * bs ))
}

# _partition_used_bytes PART_DEV FSTYPE SIZE_BYTES: conservative uncompressed
# capture budget. Only ext has a validated used-block calculation. In the VM,
# Btrfs statvfs omitted metadata captured by Partclone, so other filesystems
# fall back to their full partition size. Compression may reduce actual output.
_partition_used_bytes() {
    local dev="$1" fstype="$2" size_bytes="$3" used
    [[ "$fstype" == swap ]] && { echo 0; return; }
    if [[ "$fstype" == ext[234] ]]; then
        if used=$(_ext_used_bytes "$dev"); then
            [[ "$used" =~ ^[0-9]+$ ]] && { echo "$used"; return; }
        fi
    fi
    echo "$size_bytes"
}

# estimate_backup_bytes DISK: uncompressed size estimate for a full
# backup of DISK — the number of bytes partclone will READ, which for
# ext* includes static metadata that df does not count as used.
#
# Compression usually makes the bytes actually WRITTEN much smaller
# (76.8GB of mostly-zeroed inode tables landed as a 10.7GB image), so
# this remains deliberately conservative and a refusal does not mean
# the backup could not have fit — hence SR_SKIP_SPACE_CHECK.
#
# It did NOT used to be conservative. Until 2026-07-29 this comment
# claimed it over-estimated on purpose while the ext* path under-counted
# by 6x, which is a false GO rather than a false refusal.
estimate_backup_bytes() {
    local disk="$1" total=0 rows amount
    rows=$(lsblk -Pbno NAME,FSTYPE,SIZE,TYPE "$disk") || return 1
    local line key val pname pfstype pbytes ptype
    while IFS= read -r line; do
        pname="" pfstype="" pbytes="" ptype=""
        while IFS=$'\x1f' read -r key val; do
            case "$key" in
                NAME) pname="$val" ;; FSTYPE) pfstype="$val" ;;
                SIZE) pbytes="$val" ;; TYPE) ptype="$val" ;;
            esac
        done < <(_parse_lsblk_pairs "$line")
        [[ "$ptype" == "part" ]] || continue
        amount=$(_partition_used_bytes "/dev/$pname" "$pfstype" "${pbytes:-0}") || return 1
        [[ "$amount" =~ ^[0-9]+$ ]] || return 1
        total=$((total + amount))
    done <<< "$rows"
    echo "$total"
}

# backup_partition PART_DEV METHOD TOOL OUTFILE LOGFILE
#
# The partclone path compresses through an explicit shell pipe rather
# than partclone's own -x/--compresscmd. -x is NOT a shell command line:
# partclone 0.3.48 (the version SystemRescue 13.02 actually ships) execs
# the whole argument as one program name, so `-x "zstd -T0 -q"` dies with
#   sh: 1: zstd -T0 -q: not found
# and the backup aborts after "Reading Super Block". The host's partclone
# 0.3.27 word-splits it, which is why the test suite passed on the host
# while the real USB failed on 2026-08-28. Piping to stdout behaves the
# same on both versions, needs no assumption about how -x is parsed, and
# mirrors what restore_engine.sh already does in the other direction.
backup_partition() {
    local part_dev="$1" method="$2" tool="$3" outfile="$4" logfile="$5"
    case "$method" in
        partclone)
            # pipefail so a zstd failure is not masked by partclone's exit 0.
            ( set -o pipefail
              "$tool" -c -L "$logfile" -s "$part_dev" -o - | zstd -T0 -q -o "$outfile" )
            ;;
        rawdd)
            ( set -o pipefail
              dd if="$part_dev" bs=4M status=progress | zstd -T0 -q -o "$outfile" )
            ;;
        *)
            log_error "backup_partition: unknown method '$method'"
            return 1
            ;;
    esac
}

# backup_disk DISK DEST_ROOT: full backup of DISK to a new timestamped
# job folder under DEST_ROOT. Prints the job folder path on stdout.
backup_disk() {
    require_root
    local disk="$1" dest_root="$2"
    validate_source_disk "$disk" || return 1

    [[ -d "$dest_root" ]] || { log_error "destination $dest_root does not exist"; return 1; }

    local name="" size="" model="" serial="" key val
    while IFS=$'\x1f' read -r key val; do
        case "$key" in
            NAME) name="$val" ;; SIZE) size="$val" ;;
            MODEL) model="$val" ;; SERIAL) serial="$val" ;;
        esac
    done < <(_parse_lsblk_pairs "$(lsblk -Pdno NAME,SIZE,MODEL,SERIAL "$disk")")
    [[ -z "$serial" ]] && { serial=$(_udev_serial "$name") || true; }

    local size_bytes
    size_bytes=$(lsblk -bdno SIZE "$disk") || return 1
    [[ "$size_bytes" =~ ^[1-9][0-9]*$ ]] || return 1

    # --- destination free-space check ------------------------------------
    # These two figures are captured rather than just printed: the check has
    # to run BEFORE the job dir exists (it may refuse to create one), so the
    # log isn't open yet and the numbers would otherwise be screen-only. On
    # a real run they scroll away in seconds on a console with no scrollback,
    # which is exactly what happened on the 2026-07-29 COSMIC backup — the
    # estimate was unrecoverable afterwards. They get re-logged below.
    local est="" avail=""
    if [[ "${SR_SKIP_SPACE_CHECK:-0}" == "1" ]]; then
        log_info "WARNING: SR_SKIP_SPACE_CHECK=1 — destination free space NOT checked"
    else
        log_info "estimating space required (probing filesystems read-only)..."
        est=$(estimate_backup_bytes "$disk") || { log_error "could not estimate source size"; return 1; }
        avail=$(df -B1 --output=avail "$dest_root" 2>/dev/null | tail -1 | tr -d ' ')
        [[ "$est" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] || { log_error "could not establish available backup space"; return 1; }
        log_info "  need up to ~$(fmt_bytes "$est") uncompressed; destination has $(fmt_bytes "$avail") free"
        if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < est )); then
            log_error "not enough free space on $dest_root: $(fmt_bytes "$avail") available, ~$(fmt_bytes "$est") needed"
            log_error "(estimate is uncompressed, so the backup may well fit — override with SR_SKIP_SPACE_CHECK=1)"
            return 1
        fi
    fi

    # Name the job folder after the disk's IDENTITY (model + serial),
    # never its kernel name: nvmeN drifts between boots, so two backups
    # of ONE disk used to appear as backups of two different disks
    # (nvme1n1_... and nvme2n1_..., same serial). Nothing parses this
    # name — restore reads manifest.json — so it exists purely to be
    # unambiguous to the human choosing what to restore.
    local ts job_dir slug
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    slug=$(printf '%s' "${model:-}" | tr -cs '[:alnum:]' '_' | sed 's/^_*//; s/_*$//')
    job_dir="$dest_root/${slug:-unknown}_${serial:-unknown}_${ts}"
    mkdir "$job_dir" || { log_error "could not create a new job folder"; return 1; }

    # One partclone log PER PARTITION. partclone opens -L for writing,
    # not appending, so a single shared path is TRUNCATED on every
    # invocation and only the last partition's log survives — on a
    # four-partition disk like the COSMIC root that discards three
    # quarters of the record. Found 2026-07-29 when a test that summed
    # this log silently compared a whole-disk estimate against one
    # partition's figures and passed.
    local logfile_base="$job_dir/partclone"

    # Same reasoning as the restore side: keep a record that outlives
    # the live session. The occupancy line below ("holds X in N inodes")
    # is what distinguishes a real backup from one of an empty disk, and
    # until now it existed only on screen.
    local SR_LOG_FILE="${SR_LOG_FILE:-}"
    open_log_file "$job_dir/backup_${ts}.log" \
        || log_info "NOTE: could not write a backup log to $job_dir (screen-only)"

    log_info "backing up $disk ($model, serial=${serial:-unknown}, $size_bytes bytes)"
    log_info "destination: $job_dir"

    # Replay the preflight into the durable log (see the capture above).
    if [[ -n "$est" ]]; then
        log_info "space preflight: estimated ~$(fmt_bytes "$est") uncompressed ($est bytes), destination had $(fmt_bytes "$avail") free"
    else
        log_info "space preflight: SKIPPED (SR_SKIP_SPACE_CHECK=1) — free space was NOT checked"
    fi

    local pttype ptfile table_record partition_rows
    table_record=$(dump_partition_table "$disk" "$job_dir") || {
        log_error "partition table capture failed — aborting backup"
        return 1
    }
    read -r pttype ptfile <<< "$table_record"
    [[ -n "$ptfile" && -s "$job_dir/$ptfile" ]] || return 1
    partition_rows=$(lsblk -Pbno PARTN,NAME,FSTYPE,SIZE,UUID,PARTUUID,LABEL,TYPE "$disk") || {
        log_error "could not enumerate source partitions"
        return 1
    }

    local parts_json="[]"
    local pline ptype pnum pname pfstype psize pbytes puuid ppartuuid plabel
    local tool img_file checksum method pused pinodes pstats
    while IFS= read -r pline; do
        pnum="" pname="" pfstype="" psize="" pbytes="" puuid="" ppartuuid="" plabel="" ptype=""
        while IFS=$'\x1f' read -r key val; do
            case "$key" in
                PARTN) pnum="$val" ;; NAME) pname="$val" ;;
                FSTYPE) pfstype="$val" ;; SIZE) pbytes="$val" ;;
                UUID) puuid="$val" ;; PARTUUID) ppartuuid="$val" ;;
                LABEL) plabel="$val" ;; TYPE) ptype="$val" ;;
            esac
        done < <(_parse_lsblk_pairs "$pline")

        [[ "$ptype" == "part" ]] || continue

        # lsblk right-pads this column, so trim it — this string is
        # for display only (size_bytes is what decisions use).
        psize=$(lsblk -dno SIZE "/dev/$pname" 2>/dev/null | tr -d ' ')
        method=$(_restore_method_for "$pfstype")

        # Occupancy is measured BEFORE imaging, while the source is
        # still readable, and recorded in the manifest so the restore
        # side has something concrete to check its own work against.
        # Without it a restore can only report "no errors", which is
        # indistinguishable from having written nothing at all.
        pused=""; pinodes=""
        if [[ "$method" == "partclone" ]]; then
            if pstats=$(_probe_fs_stats "/dev/$pname" "$pfstype"); then
                IFS=$'\x1f' read -r pused pinodes <<<"$pstats"
            fi
        fi

        if [[ "$method" == "mkswap" ]]; then
            tool=""; img_file=""; checksum=""
            log_info "  partition $pnum ($pname, swap) — skipping data, will recreate via mkswap -U"
        else
            tool=$(_partclone_tool_for "$pfstype")
            img_file="part${pnum}.img.zst"
            log_info "  partition $pnum ($pname, fstype=${pfstype:-none}, method=$method, tool=$tool)"
            if [[ -n "$pused" ]]; then
                log_info "    holds $(fmt_bytes "$pused") in ${pinodes:-?} inodes"
                if fs_looks_empty "$pused" "$pinodes"; then
                    log_info "    NOTE: this filesystem is EMPTY (${pinodes} inodes — nothing but mkfs structure)."
                    log_info "          Its image will be small and a restore of it will produce an empty filesystem."
                fi
            fi
            # Abort loudly on failure. A partial image (out of space,
            # read error) would otherwise get a perfectly valid
            # checksum computed over its truncated self, and restore's
            # verification would wave it through — the one thing that
            # verification exists to prevent.
            validate_source_disk "$disk" || return 1
            local plog="${logfile_base}_part${pnum}.log"
            if ! backup_partition "/dev/$pname" "$method" "$tool" "$job_dir/$img_file" "$plog"; then
                log_error "imaging partition $pnum failed — aborting backup (see $plog)"
                return 1
            fi
            log_info "    calculating image checksum — reading the entire compressed image; please wait..."
            checksum=$(sha256sum "$job_dir/$img_file") || return 1
            checksum=${checksum%% *}
            log_info "    image checksum complete"
        fi

        parts_json=$(jq -c \
            --arg num "$pnum" --arg fstype "$pfstype" --arg size "$psize" \
            --argjson bytes "${pbytes:-0}" \
            --arg uuid "$puuid" --arg partuuid "$ppartuuid" --arg label "$plabel" \
            --arg method "$method" --arg tool "$tool" \
            --arg img "$img_file" --arg sum "$checksum" \
            --arg used "$pused" --arg inodes "$pinodes" \
            '. + [{number: ($num|tonumber), fstype: $fstype, size: $size, size_bytes: $bytes,
                   uuid: $uuid, partuuid: $partuuid, label: $label,
                   restore_method: $method, partclone_tool: $tool,
                   image_file: $img, checksum_sha256: $sum,
                   fs_used_bytes:   (if $used   == "" then null else ($used|tonumber)   end),
                   fs_inodes_used:  (if $inodes == "" then null else ($inodes|tonumber) end)}]' \
            <<< "$parts_json") || return 1
    done <<< "$partition_rows"
    if ! jq -e 'length > 0' <<< "$parts_json" >/dev/null; then
        log_error "source has no captured partitions — aborting backup"
        return 1
    fi

    jq -n \
        --argjson version 4 \
        --arg created_at "$ts" \
        --arg name "$name" --arg size "$size" --argjson size_bytes "$size_bytes" \
        --arg model "$model" --arg serial "${serial:-unknown}" --arg byid "$disk" \
        --arg pttype "$pttype" --arg ptfile "$ptfile" \
        --argjson partitions "$parts_json" \
        '{
            system_rescue_manifest_version: $version,
            created_at: $created_at,
            source_disk: {name: $name, size: $size, size_bytes: $size_bytes,
                          model: $model, serial: $serial, by_id: $byid},
            partition_table: {type: $pttype, dump_file: $ptfile},
            partitions: $partitions
        }' > "$job_dir/manifest.json.tmp" || return 1
    jq -e -s -f "$(dirname -- "${BASH_SOURCE[0]}")/manifest.jq" \
        "$job_dir/manifest.json.tmp" >/dev/null || return 1
    python3 "$(dirname -- "${BASH_SOURCE[0]}")/validate_table.py" "$job_dir/manifest.json.tmp" || return 1
    mv "$job_dir/manifest.json.tmp" "$job_dir/manifest.json" || return 1

    log_info "backup complete: $job_dir"
    echo "$job_dir"
}
