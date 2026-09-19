#!/usr/bin/env bash
# system-rescue.sh — interactive, menu-driven disk backup/restore.
#
# Deliberately NOT `set -e`: in an interactive menu, "the user pressed
# Esc/Ctrl+C on a picker" is a normal outcome (gum exits non-zero),
# not a script error. Every gum call is checked explicitly instead.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/disk_detect.sh"
source "$SCRIPT_DIR/../lib/partition_table.sh"
source "$SCRIPT_DIR/../lib/backup_engine.sh"
source "$SCRIPT_DIR/../lib/verify_engine.sh"
source "$SCRIPT_DIR/../lib/restore_engine.sh"
source "$SCRIPT_DIR/../lib/mount_helpers.sh"
source "$SCRIPT_DIR/../lib/job_select.sh"
source "$SCRIPT_DIR/../lib/ui.sh"

# pick_and_mount_destination HEADER: pick a whole disk, then a usable
# partition on it (auto-selected if there's only one), then mount it.
# Prints "DISK_BYID<TAB>MOUNTPOINT" on stdout — and ONLY that, since
# callers capture this function's stdout via $(...). Every status/error
# message therefore goes to stderr; letting one leak to stdout would
# silently corrupt the returned disk/mountpoint pair.
pick_and_mount_destination() {
    local header="$1" disk part mp

    disk=$(ui_pick_disk "$header")
    [[ -n "$disk" ]] || return 1

    part=$(ui_pick_partition "Select partition on $disk:" "$disk")
    if [[ -z "$part" ]]; then
        ui_error "That disk has no usable filesystem (it may be blank)." >&2
        ui_info "Partition and format it first, then try again." >&2
        return 1
    fi

    ui_info "Mounting /dev/$part..." >&2
    mp=$(mount_destination_partition "$part")
    if [[ -z "$mp" ]]; then
        ui_error "Failed to mount /dev/$part." >&2
        return 1
    fi

    printf '%s\t%s' "$disk" "$mp"
}

do_backup() {
    local src dest dest_disk dest_mp job_dir reason

    src=$(ui_pick_disk "Select SOURCE disk to back up:")
    [[ -n "$src" ]] || { ui_warn "Cancelled."; return; }

    dest=$(pick_and_mount_destination "Select DESTINATION disk (backup will be stored here):") || return
    dest_disk="${dest%%$'\t'*}"
    dest_mp="${dest#*$'\t'}"

    if ! reason=$(check_backup_disks_distinct "$src" "$dest_disk"); then
        ui_error "$reason"
        unmount_destination "$dest_mp"
        return
    fi

    echo
    ui_info "Source:      $(lsblk -dno MODEL,SIZE "$src")"
    ui_info "Destination: $(lsblk -dno MODEL,SIZE "$dest_disk"), free: $(df -h --output=avail "$dest_mp" | tail -1 | tr -d ' ')"
    echo

    if ! ui_confirm "Back up $src to this destination?"; then
        ui_warn "Cancelled."
        unmount_destination "$dest_mp"
        return
    fi

    if job_dir=$(backup_disk "$src" "$dest_mp"); then
        ui_ok "Backup complete: $job_dir"
    else
        ui_error "Backup failed — see the messages above."
    fi

    unmount_destination "$dest_mp"
}

# pick_backup_job MOUNTPOINT HEADER: list every backup job under
# MOUNTPOINT and let the user choose one. Prints the chosen job dir on
# stdout, empty if they backed out or there is nothing to choose.
#
# Shared by Restore and Verify on purpose. WHICH jobs exist and HOW each
# one is described now live in lib/job_select.sh, so the GUI shows exactly
# the same list with exactly the same labels; only the gum picker is here.
pick_backup_job() {
    local src_mp="$1" header="$2" dir label
    local -a jobs=()

    while IFS=$'\x1f' read -r dir label; do
        jobs+=("${label}::${dir}")
    done < <(list_backup_jobs "$src_mp")

    if (( ${#jobs[@]} == 0 )); then
        ui_error "$SR_NO_JOBS_MSG" >&2
        return 1
    fi

    "$GUM" choose --header "$header" --label-delimiter="::" "${jobs[@]}"
}

do_restore() {
    local src_disk src_mp job_dir target ttoken typed reason

    src_disk=$(ui_pick_disk "Select the disk that HOLDS your backups:")
    [[ -n "$src_disk" ]] || { ui_warn "Cancelled."; return; }

    local part
    part=$(ui_pick_partition "Select partition on $src_disk:" "$src_disk")
    if [[ -z "$part" ]]; then
        ui_error "That disk has no usable filesystem."
        return
    fi

    ui_info "Mounting /dev/$part..."
    src_mp=$(mount_destination_partition "$part")
    if [[ -z "$src_mp" ]]; then
        ui_error "Failed to mount /dev/$part."
        return
    fi

    job_dir=$(pick_backup_job "$src_mp" "Select a backup to restore:")
    if [[ -z "$job_dir" ]]; then
        ui_warn "Cancelled."
        unmount_destination "$src_mp"
        return
    fi

    target=$(ui_pick_disk "Select TARGET disk to restore onto (THIS DISK WILL BE ERASED):")
    if [[ -z "$target" ]]; then
        ui_warn "Cancelled."
        unmount_destination "$src_mp"
        return
    fi

    if ! reason=$(check_restore_disks_distinct "$src_disk" "$target"); then
        ui_error "$reason"
        unmount_destination "$src_mp"
        return
    fi

    ttoken=$(disk_confirm_token "$target")

    echo
    ui_info "Backup:"
    # The kernel name is shown last and labelled "was", because it is
    # the one field here that means nothing on this boot.
    jq -r '"    taken:    \(.created_at)
    model:    \(.source_disk.model)
    serial:   \(.source_disk.serial)
    size:     \(.source_disk.size)
    was:      \(.source_disk.name) (kernel name at backup time)"' "$job_dir/manifest.json"
    printf '    contents: %s\n' "$(job_summary "$job_dir/manifest.json")"
    echo
    ui_warn "Target (WILL BE COMPLETELY ERASED):"
    printf '    disk:   %s\n'   "$(lsblk -dno KNAME "$target")"
    printf '    model:  %s\n'  "$(lsblk -dno MODEL "$target")"
    printf '    serial: %s\n' "${ttoken:-<none>}"
    printf '    size:   %s\n'   "$(lsblk -dno SIZE "$target")"
    echo
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$target" | sed 's/^/    /'
    echo

    if ! ui_confirm "Everything on this disk will be destroyed. Continue to the confirmation step?"; then
        ui_warn "Cancelled."
        unmount_destination "$src_mp"
        return
    fi

    typed=$("$GUM" input --prompt "Type the target disk's serial (${ttoken:-<none>}) to confirm: ")

    if [[ "$typed" != "$ttoken" ]]; then
        ui_error "Confirmation did not match. Nothing was written. Aborting."
        unmount_destination "$src_mp"
        return
    fi

    if restore_disk "$job_dir" "$target" "$typed"; then
        ui_ok "Restore complete."
    else
        ui_error "Restore failed — see the messages above."
    fi

    unmount_destination "$src_mp"
}

# power_off ACTION: end the live session cleanly. ACTION is poweroff or
# reboot.
#
# The rescue USB auto-launches this menu on tty1 and RELAUNCHES it when
# it exits, so simply leaving the script strands the user in a loop with
# no way out — which is exactly what happened on the 2026-07-29 test run
# and forced a Ctrl+Alt+Del. These items are that way out.
#
# sync first: everything here has already flushed its own writes, but a
# session that just finished a restore is the worst possible moment to
# discover otherwise, and the call costs nothing.
power_off() {
    local action="$1"

    ui_info "Flushing pending writes..."
    sync
    ui_info "It is safe to remove the USB stick once the screen goes blank."

    # SR_POWEROFF_CMD lets a test drive this path without actually
    # taking the machine down.
    if [[ -n "${SR_POWEROFF_CMD:-}" ]]; then
        "$SR_POWEROFF_CMD" "$action"
        return
    fi

    "$action" 2>/dev/null || systemctl "$action" 2>/dev/null || {
        ui_error "Could not $action automatically."
        ui_info "Press Alt+F2 for a root shell and run '$action' by hand."
        return 1
    }
}

# do_verify: re-check stored backups WITHOUT restoring anything.
#
# The safest item on this menu: it opens no target disk, writes nothing,
# and erases nothing. It exists because "the backup completed" and "the
# backup is still good months later" are different claims, and until now
# only a restore could test the second one — which meant needing a disk
# you were willing to lose in order to ask whether you needed the backup
# at all.
do_verify() {
    local src_disk src_mp part job_dir scope rc=0
    local -a jobs=()

    src_disk=$(ui_pick_disk "Select the disk that HOLDS your backups:")
    [[ -n "$src_disk" ]] || { ui_warn "Cancelled."; return; }

    part=$(ui_pick_partition "Select partition on $src_disk:" "$src_disk")
    if [[ -z "$part" ]]; then
        ui_error "That disk has no usable filesystem."
        return
    fi

    ui_info "Mounting /dev/$part..."
    src_mp=$(mount_destination_partition "$part")
    if [[ -z "$src_mp" ]]; then
        ui_error "Failed to mount /dev/$part."
        return
    fi

    scope=$("$GUM" choose --header "What would you like to verify?" \
                "One backup" "Every backup on this disk")
    if [[ -z "$scope" ]]; then
        ui_warn "Cancelled."
        unmount_destination "$src_mp"
        return
    fi

    if [[ "$scope" == "One backup" ]]; then
        job_dir=$(pick_backup_job "$src_mp" "Select a backup to verify:")
        if [[ -z "$job_dir" ]]; then
            ui_warn "Cancelled."
            unmount_destination "$src_mp"
            return
        fi
        jobs=("$job_dir")
    else
        local d
        while IFS= read -r d; do
            [[ -f "$d/manifest.json" ]] && jobs+=("$d")
        done < <(find "$src_mp" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | sort)
        if [[ ${#jobs[@]} -eq 0 ]]; then
            ui_error "$SR_NO_JOBS_MSG"
            unmount_destination "$src_mp"
            return
        fi
        ui_info "Found ${#jobs[@]} backup job(s)."
    fi

    echo
    # Say this before the screen goes quiet for several minutes, so a
    # long pause reads as "working", not "hung".
    ui_warn "This reads EVERY byte of the backup and can take a while."
    ui_info "Nothing is written and no disk is erased."
    echo

    local job pass=0 fail=0
    local -a failed=()
    for job in "${jobs[@]}"; do
        echo
        if verify_backup_job "$job"; then
            ui_ok "PASS  $(basename "$job")"
            pass=$((pass + 1))
        else
            ui_error "FAIL  $(basename "$job")"
            failed+=("$job")
            fail=$((fail + 1))
        fi
    done

    echo
    if (( fail == 0 )); then
        ui_ok "All $pass backup(s) verified intact."
    else
        rc=1
        # Name them again: on a multi-job run the failure has scrolled
        # away, and this is the one line that must not be missed.
        ui_error "$fail of ${#jobs[@]} backup(s) did NOT verify:"
        for job in "${failed[@]}"; do
            ui_error "    $job"
        done
        ui_warn "Do not rely on those backups. Take a fresh one."
    fi

    unmount_destination "$src_mp"
    return $rc
}

# ---------------------------------------------------------------------------
# Job lock — one disk job at a time, across every copy of this menu.
#
# Two jobs running at once can each mount the SAME destination partition
# and then unmount it out from under the other mid-backup. That is a
# corrupted backup, not just a cosmetic mess.
#
# The lock is held around a JOB, not around the menu. Locking the whole
# menu was tried first and is wrong: the tty2 autoterminal starts a copy
# at boot and it sits at the menu forever, so a desktop-icon copy would
# find the lock held every single time and wait for a menu that never
# closes. Proven in the VM on 2026-08-28 — the icon opened straight into
# "already running, waiting". Two idle menus are harmless; two jobs are
# not.
#
# It covers destination PICKING as well as imaging, because picking is
# where the mount happens. A lock taken after the mount would let both
# copies mount the same partition before either started work.
SR_LOCK_FILE="${SR_LOCK_FILE:-/run/system_rescue.lock}"

# with_job_lock ACTION [ARGS...]: run ACTION holding the job lock.
#
# The action runs in a SUBSHELL so the lock is released by the kernel
# when that subshell exits — on a normal return, an early return from a
# cancelled picker, or a crash alike. There is no unlock path to forget
# and no stale lockfile to clean up.
with_job_lock() {
    (
        # fd 9 lives and dies with this subshell.
        #
        # The 2>/dev/null MUST stay wrapped in the braces. `exec` with no
        # command makes its redirections permanent for the whole shell, so
        # writing `exec 9>"$f" 2>/dev/null` closes stderr for the entire
        # job, not just for the open. gum draws its pickers on stderr and
        # the engines print every human-readable line there, so that turned
        # Backup into a blank screen waiting on an invisible prompt — it
        # looked like a hang on the maintainer's hardware, 2026-08-28. Braces scope the
        # redirection to the group and restore stderr when it ends, while
        # the exec inside still applies fd 9 to this subshell.
        if ! { exec 9>"$SR_LOCK_FILE"; } 2>/dev/null; then
            # A rescue tool that refuses to work because it could not
            # create a lock file is worse than the race it guards.
            ui_warn "Could not create $SR_LOCK_FILE — running without the job lock."
            ui_warn "Do not start a job in another terminal until this one finishes."
        elif ! flock -n 9; then
            ui_warn "Another copy of system_rescue is running a job right now."
            ui_info "Only one job can touch disks at a time: two at once can"
            ui_info "mount the same destination partition and unmount it out"
            ui_info "from under each other, which corrupts a backup."
            echo
            ui_info "The other copy is on Ctrl+Alt+F2, or Ctrl+Alt+F1 for the desktop."
            ui_info "Waiting — this starts on its own when that job finishes."
            flock 9
        fi
        "$@"
    )
}

# menu_items: the main menu's entries, one per line.
#
# Only offers the power items on the live USB. The same script runs
# under test/interactive_sandbox.sh on a real desktop, where one stray
# Enter must never take the machine down. See is_live_environment in
# common.sh.
menu_items() {
    printf '%s\n' "Backup" "Restore" "Verify a backup"
    is_live_environment && printf '%s\n' "Shut down" "Reboot"
    printf '%s\n' "Exit to shell"
}

main_menu() {
    local choice
    local -a items=()
    mapfile -t items < <(menu_items)

    while true; do
        echo
        choice=$("$GUM" choose --header "system_rescue — what would you like to do?" \
                     "${items[@]}")
        case "$choice" in
            Backup)  with_job_lock do_backup ;;
            Restore) with_job_lock do_restore ;;
            "Verify a backup") with_job_lock do_verify ;;
            "Shut down")
                # Confirm rather than act on a single keypress: the
                # post-restore verification block is on screen and only
                # on screen, and powering off is how it gets lost.
                if ui_confirm "Shut down now? Anything still on screen will be gone."; then
                    power_off poweroff
                fi
                ;;
            Reboot)
                if ui_confirm "Reboot now? Anything still on screen will be gone."; then
                    power_off reboot
                fi
                ;;
            "Exit to shell")
                # Where "exit" leads depends on how this copy was
                # started. The tty2 autoterminal RELAUNCHES the menu the
                # moment it exits, so leaving it just loops back here —
                # say so instead of letting the user discover it. A copy
                # started from the desktop icon is an ordinary terminal
                # window, so there exiting really does end the menu.
                if is_live_environment && [[ -z "${SR_DESKTOP_LAUNCH:-}" ]]; then
                    ui_warn "This menu relaunches itself on tty2, so leaving it will"
                    ui_info "just bring you back here. For a root shell, switch to the"
                    ui_info "desktop with Ctrl+Alt+F1 and open Terminal."
                    ui_info "To end the session, choose Shut down or Reboot."
                else
                    break
                fi
                ;;
            # Esc or Ctrl+C on the picker: redraw the menu rather than
            # exit. Backing out of a menu is not a request to quit.
            "") ;;
        esac
    done
}

# Run only when executed, not when sourced. Sourcing lets a test call
# main_menu's helpers (menu_items, power_off) directly instead of
# proving them on a hardware boot, which is the slowest feedback loop
# this project has.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root
    ui_banner
    main_menu

    # Only reachable from a desktop-icon launch (the tty2 copy never
    # breaks out of the loop). Say the window is finished with, because
    # xfce4-terminal --hold leaves it open and otherwise silent.
    if [[ -n "${SR_DESKTOP_LAUNCH:-}" ]]; then
        echo
        ui_info "Menu closed. You can close this window."
    fi
fi
