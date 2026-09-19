#!/usr/bin/env bash
# common.sh — shared helpers for system_rescue scripts.

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "system_rescue: this operation requires root (reads/writes raw block devices)." >&2
        exit 1
    fi
}

# Every [system_rescue] message goes to stderr, and — when SR_LOG_FILE
# names a writable path — to that file as well, timestamped.
#
# Without this, the only record of a run was the screen. The restore
# log lived in RAM and died at shutdown, so the post-restore
# verification block (the one output that says whether the restore
# actually worked) survived only as photographs of the monitor. Both
# post-mortems this project has needed were done days later, from those
# photographs. Callers set SR_LOG_FILE to a path INSIDE the job dir on
# the destination disk, so the log outlives the reboot.
#
# open_log_file PATH: start logging to PATH. Non-zero if it cannot be
# written, so the caller can say so rather than imply a log exists.
open_log_file() {
    local path="$1"
    : > "$path" 2>/dev/null || return 1
    SR_LOG_FILE="$path"
    printf '# system_rescue log opened %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SR_LOG_FILE"
}

# _log_emit LINE: stderr always, log file when one is open. A failed
# append must never change a caller's control flow, hence `return 0`.
_log_emit() {
    printf '%s\n' "$1" >&2
    if [[ -n "${SR_LOG_FILE:-}" ]]; then
        printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$SR_LOG_FILE" 2>/dev/null || true
    fi
    return 0
}

log_info()  { _log_emit "[system_rescue] $*"; }
log_error() { _log_emit "[system_rescue] ERROR: $*"; }

# fmt_bytes N: human-readable size, falling back to raw bytes if
# numfmt is missing or N is not a number.
fmt_bytes() {
    [[ "$1" =~ ^[0-9]+$ ]] || { printf '?'; return; }
    # iec-i so the unit is unambiguous: 60GiB, not a "60GB" that could
    # be read as either base.
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
}

# --- filesystem occupancy probing ---------------------------------------
# Shared by the backup engine (which records occupancy) and the restore
# engine (which reads it back to verify its own work), so it lives here
# rather than in either one.

# _df_pair MOUNTPOINT: read occupancy off an already-mounted filesystem
# as "USED_BYTES<US>INODES_USED". The inode count comes from `df -i`,
# which is a superblock field and therefore instant — never from
# walking the tree, which would take hours on a full 4TB disk.
# Filesystems with no inode concept (vfat) report "-"; that field is
# left empty rather than faked.
_df_pair() {
    local mp="$1" used inodes
    # NOTE: no -i here. `df -i --output=iused` is rejected outright
    # ("options -i and --output are mutually exclusive"), and with the
    # error sent to /dev/null the field came back EMPTY — which would
    # have made every inode comparison skip itself while still
    # reporting a pass. --output=iused already selects inode counts.
    used=$(df -B1 --output=used "$mp" 2>/dev/null | tail -1 | tr -d ' ')
    inodes=$(df --output=iused "$mp" 2>/dev/null | tail -1 | tr -d ' ')
    [[ "$used" =~ ^[0-9]+$ ]] || return 1
    # Filesystems with no inode concept report "-" on some systems and
    # a flat 0 on others (vfat does the latter here). Either way they
    # are not reporting occupancy, so both normalise to "unknown"
    # rather than to a count of zero — a populated 318MiB EFI partition
    # reporting 0 must not be mistaken for an empty one.
    [[ "$inodes" =~ ^[0-9]+$ ]] && (( inodes > 0 )) || inodes=""
    printf '%s\x1f%s\n' "$used" "$inodes"
}

# _probe_fs_stats PART_DEV FSTYPE: measure what a filesystem actually
# holds, printing "USED_BYTES<US>INODES_USED". Non-zero exit means it
# could not be measured — swap, unformatted space, LUKS/LVM, or any
# filesystem this kernel cannot mount. Callers must treat that as
# "unknown", never as zero.
#
# df needs the filesystem MOUNTED and in the rescue environment
# nothing is, so an unmounted filesystem gets a read-only probe mount
# just long enough to read the two numbers.
_probe_fs_stats() {
    local dev="$1" fstype="$2" mp probe out=""
    [[ -n "$fstype" && "$fstype" != "swap" ]] || return 1

    mp=$(findmnt -rno TARGET "$dev" 2>/dev/null | head -1)
    if [[ -n "$mp" ]]; then
        _df_pair "$mp"
        return
    fi

    probe=$(mktemp -d) || return 1
    local -a opts=(-o ro)
    # noload keeps a read-only ext mount from replaying its journal.
    [[ "$fstype" == ext* ]] && opts=(-o ro,noload)
    # Btrfs can replay its tree log even on a read-only mount.
    [[ "$fstype" == btrfs ]] && opts=(-o ro,rescue=nologreplay)
    if mount -t "$fstype" "${opts[@]}" "$dev" "$probe" 2>/dev/null; then
        out=$(_df_pair "$probe") || out=""
        if ! umount "$probe" 2>/dev/null; then
            log_error "could not unmount probe at $probe"
            return 1
        fi
    fi
    rmdir "$probe" 2>/dev/null || true

    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# fs_looks_empty USED_BYTES INODES_USED: true if a filesystem holds
# nothing but its own structure.
#
# This exists because "space in use" on a big filesystem is NOT user
# data. A freshly formatted 4TB ext4 reports ~64GB in use before a
# single file exists — that is the inode table (244M inodes x 256B),
# journal, bitmaps and reserved GDT blocks. Mistaking that figure for
# real content once led to a correct backup+restore being reported as
# silent data loss. A newly mkfs'd ext4 has 11 inodes in use (root,
# lost+found and the reserved set), so the inode count is the honest
# signal and the byte figure is not.
fs_looks_empty() {
    local used="$1" inodes="$2"
    [[ "$inodes" =~ ^[0-9]+$ ]] || return 1
    (( inodes <= 11 ))
}

# --- live-environment detection -----------------------------------------

# is_live_environment: true when this is running from the rescue USB
# rather than on an installed operating system.
#
# It exists solely to gate the Shut down / Reboot menu items. The same
# scripts run under test/interactive_sandbox.sh on the developer's own
# desktop, where offering a power-off button would mean one stray Enter
# takes the machine down mid-session.
#
# Several independent signals are accepted because any single one could
# change with a SystemRescue release: the archiso/SystemRescue live root
# is an overlay over squashfs, archiso leaves /run/archiso behind, and
# os-release identifies the distro. Failing SAFE means concluding "not
# live" and hiding the option, which costs a wasted reboot at worst.
# SR_ALLOW_POWEROFF=1 forces it on, =0 forces it off.
is_live_environment() {
    case "${SR_ALLOW_POWEROFF:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac

    local rootfs
    rootfs=$(findmnt -no FSTYPE / 2>/dev/null) || rootfs=""
    case "$rootfs" in
        overlay|overlayfs|aufs|squashfs|iso9660|tmpfs|ramfs) return 0 ;;
    esac

    [[ -d /run/archiso || -d /run/miso ]] && return 0
    grep -qi 'sysrescue' /etc/os-release 2>/dev/null && return 0

    return 1
}
