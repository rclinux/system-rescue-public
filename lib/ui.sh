#!/usr/bin/env bash
# ui.sh — gum-based UI helpers for the interactive menu.
#
# gum is a vendored static binary (system_rescue/vendor/gum), not an
# apt dependency — it ships on the rescue USB the same way. See
# https://github.com/charmbracelet/gum releases v0.17.0.

_UI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GUM="$_UI_LIB_DIR/../vendor/gum"

if [[ ! -x "$GUM" ]]; then
    echo "system_rescue: gum binary not found or not executable at $GUM" >&2
    exit 1
fi

ui_banner() {
    "$GUM" style \
        --border rounded --align center --width 50 --margin "1 2" --padding "1 4" \
        --border-foreground 212 --foreground 212 --bold \
        "SYSTEM RESCUE" "Backup & Restore Utility"
}

ui_info()  { "$GUM" style --foreground 39  "  $*"; }
ui_warn()  { "$GUM" style --foreground 214 "  ! $*"; }
ui_error() { "$GUM" style --foreground 196 --bold "  x $*"; }
ui_ok()    { "$GUM" style --foreground 46  --bold "  v $*"; }

# ui_confirm PROMPT: gum confirm, defaulting focus to "No" (gum's
# default when --default is omitted) so an accidental Enter on a
# destructive prompt never confirms it.
ui_confirm() {
    "$GUM" confirm "$1"
}

# ui_pick_disk HEADER: interactively choose a disk from the eligible
# candidate list. Prints the chosen /dev/disk/by-id/* path on stdout
# (empty if the user backed out). Never lists busy/boot-media/virtual
# disks — that filtering lives in list_candidate_disks.
ui_pick_disk() {
    local header="$1"
    local -a options=()
    local name size model serial byid

    while IFS=$'\t' read -r name size model serial byid; do
        [[ -n "$name" ]] || continue
        options+=("$(printf '%-10s %6s  %-28s  serial %s' "$name" "$size" "$model" "$serial")::${byid}")
    done < <(list_candidate_disks)

    if [[ ${#options[@]} -eq 0 ]]; then
        ui_error "No eligible disks found (all disks are busy, boot media, or virtual)." >&2
        return 1
    fi

    local chosen
    chosen=$("$GUM" choose --header "$header" --label-delimiter="::" "${options[@]}") || return 1
    printf '%s' "$chosen"
}

# ui_pick_partition HEADER DISK: interactively choose one of DISK's
# usable (mountable, non-swap) partitions. Prints the kernel partition
# name (e.g. nvme1n1p1) on stdout. If there is exactly one candidate,
# it is returned without prompting.
ui_pick_partition() {
    local header="$1" disk="$2"
    local -a options=()
    local pname pfstype psize plabel

    while IFS=$'\t' read -r pname pfstype psize plabel; do
        [[ -n "$pname" ]] || continue
        options+=("$(printf '%-14s %-8s %6s  %s' "$pname" "$pfstype" "$psize" "$plabel")::${pname}")
    done < <(disk_usable_partitions "$disk")

    if [[ ${#options[@]} -eq 0 ]]; then
        return 1
    elif [[ ${#options[@]} -eq 1 ]]; then
        printf '%s' "${options[0]##*::}"
        return 0
    fi

    local chosen
    chosen=$("$GUM" choose --header "$header" --label-delimiter="::" "${options[@]}") || return 1
    printf '%s' "$chosen"
}
