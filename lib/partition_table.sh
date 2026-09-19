#!/usr/bin/env bash
# partition_table.sh — dump a disk's partition table so it can be
# replayed onto a restore target. Handles both table types found in
# the wild: GPT (sgdisk) and MBR/dos (sfdisk).

# pttype_of DISK: print "gpt", "dos", or "" (no partition table) for
# the given disk path (e.g. /dev/disk/by-id/... or /dev/sdX).
pttype_of() {
    lsblk -dno PTTYPE "$1" 2>/dev/null
}

# dump_partition_table DISK OUTDIR: write the partition table to
# OUTDIR, print two tab-separated fields on stdout: TYPE and the
# dump filename (relative to OUTDIR), for the manifest to record.
dump_partition_table() {
    local disk="$1" outdir="$2"
    local pttype
    pttype=$(pttype_of "$disk") || return 1

    case "$pttype" in
        gpt)
            sgdisk --backup="$outdir/partition_table.gpt" "$disk" >/dev/null || {
                log_error "failed to save GPT partition table"
                return 1
            }
            [[ -s "$outdir/partition_table.gpt" ]] || return 1
            printf 'gpt\tpartition_table.gpt\n'
            ;;
        dos)
            sfdisk --dump "$disk" > "$outdir/partition_table.sfdisk" || {
                log_error "failed to save MBR partition table"
                return 1
            }
            [[ -s "$outdir/partition_table.sfdisk" ]] || return 1
            printf 'dos\tpartition_table.sfdisk\n'
            ;;
        "")
            log_error "no partition table found on $disk"
            return 1
            ;;
        *)
            log_error "unrecognized partition table type '$pttype' on $disk"
            return 1
            ;;
    esac
}

# restore_partition_table DISK TYPE DUMPFILE: replay a dumped
# partition table onto DISK. DESTRUCTIVE. The caller must have already
# passed the full validation gate in restore_engine.sh — this function
# performs no safety checks of its own.
restore_partition_table() {
    local disk="$1" pttype="$2" dumpfile="$3"
    case "$pttype" in
        gpt)
            sgdisk --load-backup="$dumpfile" "$disk" >/dev/null || return 1
            ;;
        dos)
            sfdisk --force "$disk" < "$dumpfile" >/dev/null || return 1
            ;;
        *)
            log_error "unrecognized partition table type '$pttype' for restore"
            return 1
            ;;
    esac
}
