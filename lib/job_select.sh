#!/usr/bin/env bash
# job_select.sh — how a stored backup is DESCRIBED and CHOSEN, and the two
# refusals that keep a disk from being used against itself.
#
# All of this used to live inside bin/system-rescue.sh. It moved here the
# moment a second front-end (the GTK4 GUI) became real, because these are
# the most dangerous decisions the project makes and two implementations
# of them is two chances to get one wrong:
#
#   * the label a user picks from is the last thing standing between
#     "restore the right backup" and "erase a disk using the wrong one"
#   * "this filesystem was EMPTY" is the check that once stopped a correct
#     backup+restore being reported as silent data loss
#   * source==destination and target==backup-holder are the two ways to
#     aim the tool at itself
#
# Deliberately UI-FREE: nothing here calls gum, prints styled output, or
# assumes a terminal. It returns data and reasons; the TUI and the GUI each
# decide how to show them. That is what makes it shareable.

# Message shown when a disk holds no backups. Defined once so both
# front-ends say the same thing.
SR_NO_JOBS_MSG="No backup jobs found on this disk."

# fmt_stamp 20260729T144548Z -> "2026-07-29 14:45Z". Falls back to the
# raw string rather than guessing if it doesn't match.
fmt_stamp() {
    local s="$1"
    [[ "$s" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2}) ]] \
        || { printf '%s' "$s"; return; }
    printf '%s-%s-%s %s:%sZ' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
        "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
}

# job_summary MANIFEST: what this backup actually CONTAINS, for a picker.
# Choosing the wrong job erases a disk, and two jobs from the same source
# are otherwise indistinguishable apart from a timestamp — so the label
# has to say whether the source held any real data.
#
# Inodes, not bytes: a fresh 4TB ext4 reports ~64GB "in use" that is
# entirely mkfs structure. See fs_looks_empty in common.sh.
job_summary() {
    local m="$1" ver used inodes
    ver=$(jq -r '.system_rescue_manifest_version // 0' "$m" 2>/dev/null)
    [[ "$ver" =~ ^[0-9]+$ ]] || ver=0
    if (( ver < 4 )); then
        printf 'v%s - contents not recorded' "$ver"
        return
    fi
    used=$(jq -r '[.partitions[].fs_used_bytes // 0] | add' "$m" 2>/dev/null)
    inodes=$(jq -r '[.partitions[].fs_inodes_used // 0] | add' "$m" 2>/dev/null)
    if fs_looks_empty "$used" "$inodes"; then
        printf 'EMPTY - no files'
        return
    fi
    printf '%s in %s inodes' "$(fmt_bytes "$used")" "$inodes"
}

# job_label JOB_DIR: the one-line human description of a backup job.
# Column widths are fixed so a list of them reads as a table in any
# front-end that uses a monospace font.
#
# Leads with the job directory's own name, not the source disk's model —
# the same physical disk gets reformatted and re-backed-up under different
# names (e.g. one Kingston drive holding "cosmic" one week, "linuxmint" the
# next), so model+serial alone can be identical across jobs a user very
# much needs to tell apart. The directory name is whatever the user
# renamed it to specifically to make that call, so trust it as the primary
# label; serial stays as a secondary check that the name still points at
# the disk it claims to.
job_label() {
    local d="$1" m="$d/manifest.json" name created dserial
    name=$(basename -- "$d")
    created=$(jq -r '.created_at // "unknown"' "$m" 2>/dev/null)
    dserial=$(jq -r '.source_disk.serial // "?"' "$m" 2>/dev/null)
    printf '%-30s %-18s %-18s %s' \
        "$name" "$dserial" "$(fmt_stamp "$created")" "$(job_summary "$m")"
}

# list_backup_jobs MOUNTPOINT: every backup job under MOUNTPOINT, NEWEST
# FIRST, one per line as "JOB_DIR<US>LABEL". Non-zero (and silent) when
# there are none — the caller decides how to say SR_NO_JOBS_MSG.
#
# Newest first because the stale job is the dangerous one to pick by
# accident, and pickers preselect the top entry.
list_backup_jobs() {
    local src_mp="$1" d created
    local -a rows=()

    while IFS= read -r d; do
        [[ -f "$d/manifest.json" ]] || continue
        created=$(jq -r '.created_at // "unknown"' "$d/manifest.json" 2>/dev/null)
        # \x1f, not tab: tab is an IFS whitespace char and collapses runs,
        # which shifts fields when a value is empty.
        rows+=("${created}"$'\x1f'"${d}"$'\x1f'"$(job_label "$d")")
    done < <(find "$src_mp" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    (( ${#rows[@]} > 0 )) || return 1

    local _stamp dir label
    while IFS=$'\x1f' read -r _stamp dir label; do
        printf '%s\x1f%s\n' "$dir" "$label"
    done < <(printf '%s\n' "${rows[@]}" | sort -r)
}

# _refuse_if_same A B REASON: 0 when the two disks differ, 1 when they are
# the same disk — printing REASON on stdout for the caller to display.
#
# Compares by the STABLE by-id path the pickers hand out, not by kernel
# name: nvmeN drifts between boots, so a kernel-name comparison could call
# two different disks equal, or one disk two.
_refuse_if_same() {
    local a="$1" b="$2" reason="$3"
    [[ -n "$a" && -n "$b" && "$a" == "$b" ]] || return 0
    printf '%s' "$reason"
    return 1
}

# check_backup_disks_distinct SOURCE DEST: refuse to back a disk up onto
# itself. The image would be written into the filesystem it is imaging.
check_backup_disks_distinct() {
    _refuse_if_same "$1" "$2" "Source and destination are the same disk."
}

# check_restore_disks_distinct BACKUP_DISK TARGET: refuse to restore onto
# the disk holding the backup. The erase happens before the read finishes,
# so this destroys the backup and the restore together.
check_restore_disks_distinct() {
    _refuse_if_same "$1" "$2" "Target cannot be the disk holding the backup."
}
