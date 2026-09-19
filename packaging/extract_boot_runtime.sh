#!/usr/bin/env bash
# Extract the rescue kernel and initramfs from a candidate ISO into
# baseline/usb-files/sysresccd/boot/x86_64/, where tests/run_vm.py and
# tests/two_vm_recovery.py load them. Candidates built with sysrescue-customize
# carry the base kernel/initramfs unchanged. No block devices are accessed, and
# existing files are never overwritten.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${1:-$ROOT/baseline/last-known-good.iso}"
DEST="$ROOT/baseline/usb-files/sysresccd/boot/x86_64"

[[ -f "$ISO" ]] || { echo "ISO not found: $ISO" >&2; exit 1; }
if [[ -f "$ISO.sha256" ]]; then
    (cd "$(dirname "$ISO")" && sha256sum -c "$(basename "$ISO").sha256" >/dev/null) \
        || { echo "Checksum mismatch: $ISO" >&2; exit 1; }
fi
mkdir -p "$DEST"
for name in vmlinuz sysresccd.img; do
    [[ -e "$DEST/$name" ]] && { echo "Refusing to overwrite $DEST/$name" >&2; exit 1; }
    xorriso -osirrox on -indev "$ISO" -extract "/sysresccd/boot/x86_64/$name" "$DEST/$name" >/dev/null 2>&1
done
sha256sum "$DEST/vmlinuz" "$DEST/sysresccd.img"
