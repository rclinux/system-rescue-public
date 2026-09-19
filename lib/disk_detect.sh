#!/usr/bin/env bash
# disk_detect.sh — stable disk identification for system_rescue.
#
# Disks are always identified by kernel name + SIZE/MODEL/SERIAL, and
# resolved to a /dev/disk/by-id/* path before any read/write happens,
# so a /dev/sdX -> /dev/sdY drift between boots never touches the
# wrong device. Any disk currently backing a mounted filesystem (this
# includes the booted live USB itself) is excluded from candidate
# lists — it must never be offered as a backup source or restore
# target.

# busy_disks: print kernel disk names (sda, nvme0n1, ...) that back a
# currently mounted filesystem, directly or via a loop device (e.g. a
# live-boot squashfs). These are excluded from candidate lists.
busy_disks() {
    local rows swaps src
    _mounted_btrfs_disks || return 1
    rows=$(findmnt -rn -o SOURCE) || return 1
    swaps=$(swapon --show=NAME --noheadings --raw) || return 1
    while IFS= read -r src; do
        [[ -n "$src" ]] || continue
        # findmnt appends [/subvolume] to Btrfs sources.
        src="${src%%\[*}"
        if [[ "$src" == /dev/* ]]; then
            _disk_behind "$src" || return 1
        elif [[ "$src" == /* ]]; then
            local host
            host=$(findmnt -rn -o SOURCE --target "$src") || return 1
            _disk_behind "${host%%\[*}" || return 1
        fi
    done <<< "$rows
$swaps"
}

# Btrfs can mount through one member while writing to several others.
# Its mounted-filesystem sysfs inventory identifies every member by dev_t.
_mounted_btrfs_disks() {
    local entry number
    for entry in /sys/fs/btrfs/*/devices/*/dev; do
        [[ -e "$entry" ]] || continue
        number=$(cat "$entry") || return 1
        [[ "$number" =~ ^[0-9]+:[0-9]+$ ]] || return 1
        _disk_behind "/dev/block/$number" || return 1
    done
    return 0
}

# Follow all ancestors, including device-mapper/RAID and loop backing files.
_disk_behind() {
    local dev="${1%%\[*}" backing host rows name type
    if [[ "$dev" == /dev/loop* ]]; then
        backing=$(losetup --noheadings --output BACK-FILE "$dev") || return 1
        host=$(findmnt -rn -o SOURCE --target "$backing") || return 1
        _disk_behind "${host%%\[*}"
        return
    fi
    rows=$(lsblk -snr -o KNAME,TYPE "$dev") || return 1
    while read -r name type; do
        [[ "$type" == disk || "$type" == loop ]] && printf '%s\n' "$name"
    done <<< "$rows"
    return 0
}

# Engine-level gate, also used immediately before each source image.
validate_source_disk() {
    local disk="$1" name candidates candidate
    [[ -b "$disk" ]] || { log_error "source is not a block device: $disk"; return 1; }
    local topology kind
    topology=$(lsblk -nr -o TYPE "$disk") || return 1
    while read -r kind; do
        case "$kind" in disk|part) ;; loop) [[ "${SR_ALLOW_VIRTUAL:-0}" == 1 ]] || return 1 ;;
            *) log_error "source has active stacked devices ($kind)"; return 1 ;;
        esac
    done <<< "$topology"
    local filesystems path fstype super devices
    filesystems=$(lsblk -rnp -o PATH,FSTYPE "$disk") || return 1
    while read -r path fstype; do
        [[ "$fstype" == btrfs ]] || continue
        super=$(btrfs inspect-internal dump-super "$path") || return 1
        devices=$(awk '$1 == "num_devices" {print $2; exit}' <<< "$super")
        if [[ "$devices" != 1 ]]; then
            log_error "multi-device or unreadable Btrfs requires a separate recovery workflow"
            return 1
        fi
    done <<< "$filesystems"
    name=$(lsblk -dno KNAME "$disk") || return 1
    [[ -n "$name" ]] || return 1
    candidates=$(list_candidate_disks) || return 1
    while IFS=$'\t' read -r candidate _; do
        [[ "$candidate" == "$name" ]] && return 0
    done <<< "$candidates"
    log_error "source $disk is not eligible (mounted, active swap, boot media, or unsupported device)"
    return 1
}

# _udev_serial NAME: fallback serial lookup for disks that report a
# blank SERIAL column in lsblk (seen on some USB enclosures).
_udev_serial() {
    udevadm info --query=property --name="/dev/$1" 2>/dev/null \
        | awk -F= '$1=="ID_SERIAL_SHORT"{print $2; f=1} END{exit !f}'
}

# _stable_byid_path NAME: pick a canonical /dev/disk/by-id/* symlink
# for a kernel disk name (preferring wwn- IDs, which are the least
# likely to change), skipping partition entries. Falls back to
# /dev/NAME if the disk has no by-id symlinks at all.
_stable_byid_path() {
    local name="$1" link target base best=""
    for link in /dev/disk/by-id/*; do
        [[ -e "$link" ]] || continue
        [[ "$link" == *-part* ]] && continue
        target=$(readlink -f "$link") || continue
        base=$(basename "$target")
        [[ "$base" == "$name" ]] || continue
        case "$(basename "$link")" in
            wwn-*) echo "$link"; return 0 ;;
            *) [[ -z "$best" ]] && best="$link" ;;
        esac
    done
    echo "${best:-/dev/$name}"
}

# _is_selectable_disk_type TYPE: true if lsblk's TYPE for a device
# means "a whole disk we may operate on". Real hardware reports
# "disk". Loopback devices report "loop" and are accepted only under
# the SR_ALLOW_VIRTUAL test hatch.
_is_selectable_disk_type() {
    [[ "$1" == "disk" ]] && return 0
    [[ "${SR_ALLOW_VIRTUAL:-0}" == "1" && "$1" == "loop" ]] && return 0
    return 1
}

# disk_confirm_token DISK: the string a human must type to confirm a
# destructive operation on DISK. Prefers the serial number; falls back
# to the by-id name and then the kernel name for hardware that reports
# no serial (seen on some USB enclosures, and on loopback devices in
# the test suite). Both the UI that displays the token and the engine
# that re-verifies it call this, so they can never disagree.
disk_confirm_token() {
    local disk="$1" kname serial byid
    kname=$(lsblk -dno KNAME "$disk" 2>/dev/null)
    [[ -n "$kname" ]] || return 1

    serial=$(lsblk -dno SERIAL "$disk" 2>/dev/null)
    [[ -z "$serial" ]] && { serial=$(_udev_serial "$kname") || true; }
    if [[ -n "$serial" ]]; then
        echo "$serial"
        return 0
    fi

    byid=$(_stable_byid_path "$kname")
    if [[ "$byid" != "/dev/$kname" ]]; then
        basename "$byid"
        return 0
    fi

    echo "$kname"
}

# _parse_lsblk_pairs LINE: split one line of `lsblk -P` output
# (KEY="value" KEY="value" ...) into KEY<US>VALUE records.
_parse_lsblk_pairs() {
    local line="$1" key val
    while [[ "$line" =~ ^([A-Z_]+)=\"([^\"]*)\"[[:space:]]*(.*)$ ]]; do
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        printf '%s\x1f%s\n' "$key" "$val"
        line="${BASH_REMATCH[3]}"
    done
}

# list_candidate_disks: print one tab-separated record per whole disk
# eligible for backup/restore selection:
#   NAME  SIZE  MODEL  SERIAL  STABLE_PATH
# Excludes anything in busy_disks and anything that isn't TYPE=disk
# (partitions, loop devices, optical drives, etc).
list_candidate_disks() {
    local -a busy
    local busy_rows disk_rows
    busy_rows=$(busy_disks) || return 1
    mapfile -t busy <<< "$busy_rows"
    disk_rows=$(lsblk -Pdno NAME,SIZE,MODEL,SERIAL,TYPE) || return 1

    local line name size model serial type key val is_busy b byid
    while IFS= read -r line; do
        name="" size="" model="" serial="" type=""
        while IFS=$'\x1f' read -r key val; do
            case "$key" in
                NAME) name="$val" ;;
                SIZE) size="$val" ;;
                MODEL) model="$val" ;;
                SERIAL) serial="$val" ;;
                TYPE) type="$val" ;;
            esac
        done < <(_parse_lsblk_pairs "$line")

        # SR_ALLOW_VIRTUAL=1 is a TEST-ONLY escape hatch letting the
        # loopback test suite target synthetic disks. It widens only
        # which disks may be listed; every other safety check (identity
        # confirmation, size check, mounted-filesystem check, checksum
        # verification) still applies in full.
        _is_selectable_disk_type "$type" || continue
        local topology child_type unsupported=0
        topology=$(lsblk -nr -o TYPE "/dev/$name") || return 1
        while read -r child_type; do
            case "$child_type" in disk|part|loop) ;; *) unsupported=1 ;; esac
        done <<< "$topology"
        (( unsupported )) && continue
        if [[ "${SR_ALLOW_VIRTUAL:-0}" != "1" ]]; then
            # Real disks have a backing hardware device link; zram/dm
            # and other virtual block devices do not.
            [[ -e "/sys/block/$name/device" ]] || continue

            # ...but a legacy floppy controller DOES present that link,
            # so QEMU's emulated fd0 turned up in the picker during the
            # ISO smoke test as a 4K disk with model/serial "Unknown".
            # Nothing worth backing up or restoring is smaller than
            # SR_MIN_DISK_BYTES (1GiB), and offering an unusable device
            # in a destructive menu is a hazard in itself.
            [[ "$name" == fd[0-9]* ]] && continue
            local bytes
            bytes=$(lsblk -bdno SIZE "/dev/$name" 2>/dev/null)
            [[ "$bytes" =~ ^[0-9]+$ ]] || continue
            (( bytes >= ${SR_MIN_DISK_BYTES:-1073741824} )) || continue
        fi

        is_busy=0
        for b in "${busy[@]}"; do
            [[ "$b" == "$name" ]] && { is_busy=1; break; }
        done
        (( is_busy )) && continue

        if [[ -z "$serial" ]]; then
            serial=$(_udev_serial "$name") || true
        fi
        byid=$(_stable_byid_path "$name")

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$name" "${size:-?}" "${model:-Unknown}" "${serial:-Unknown}" "$byid"
    done <<< "$disk_rows"
}
