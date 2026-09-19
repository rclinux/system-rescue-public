#!/usr/bin/env bash
# mount_helpers.sh — mount/unmount a destination disk for interactive
# backup/restore.
#
# The disk picker only ever offers whole disks (matching "select the
# source and destination" — the user picks a disk, not a partition), so
# this is what turns a chosen destination disk into a writable
# directory: find its usable partition(s), mount one, hand back the
# path. It does not partition or format anything — a blank disk is
# reported as an error, not silently initialized, since formatting a
# disk is itself a destructive operation outside backup/restore's
# stated scope.

# disk_usable_partitions DISK: print "NAME<TAB>FSTYPE<TAB>SIZE<TAB>LABEL"
# for each partition on DISK that has a real, mountable filesystem.
# Swap and unrecognized/raw content (LUKS, LVM, unformatted) are
# excluded — none of those can hold backup image files.
disk_usable_partitions() {
    local disk="$1" line key val pname pfstype psize plabel ptype
    while IFS= read -r line; do
        pname="" pfstype="" psize="" plabel="" ptype=""
        while IFS=$'\x1f' read -r key val; do
            case "$key" in
                NAME) pname="$val" ;; FSTYPE) pfstype="$val" ;;
                SIZE) psize="$val" ;; LABEL) plabel="$val" ;; TYPE) ptype="$val" ;;
            esac
        done < <(_parse_lsblk_pairs "$line")
        [[ "$ptype" == "part" ]] || continue
        [[ -n "$pfstype" && "$pfstype" != "swap" ]] || continue
        case "$pfstype" in
            crypto_LUKS|LVM2_member) continue ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$pname" "$pfstype" "${psize## }" "$plabel"
    done < <(lsblk -Pno NAME,FSTYPE,SIZE,LABEL,TYPE "$disk" 2>/dev/null)
}

# mount_destination_partition PART_NAME: mount /dev/PART_NAME
# read-write at a fresh temp mountpoint. Prints the mountpoint path.
mount_destination_partition() {
    require_root
    local pname="$1" mp
    mp=$(mktemp -d /run/system_rescue.XXXXXX) || return 1
    if ! mount "/dev/$pname" "$mp"; then
        rmdir "$mp" 2>/dev/null || true
        return 1
    fi
    echo "$mp"
}

# unmount_destination MOUNTPOINT: unmount and remove a mountpoint
# created by mount_destination_partition. Best-effort — falls back to
# a lazy unmount rather than leaving the disk mounted on failure.
unmount_destination() {
    local mp="$1"
    [[ -n "$mp" && -d "$mp" ]] || return 0
    sync
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
}
