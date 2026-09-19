# Recovery validation and release boundary

## Automated VM checks

`python3 tests/run_vm.py` boots the preserved rescue runtime with the current
working application shared read-only. It creates three new sparse disk files in
`packaging/build/roundtrip-*/`: source, target, and backup storage. No host block
devices or network interfaces are attached. The guest additionally checks its
QEMU identity and all three device serial numbers before any writes.

`python3 tests/run_vm.py dist/<candidate>.iso` tests the application installed in
that ISO, using the same isolated disks. The kernel/initramfs are loaded directly
from the preserved runtime for reliable serial automation; this is separate
from a firmware boot test of the ISO.

**Harness inputs:** `tests/run_vm.py` and `tests/two_vm_recovery.py` load the
kernel and initramfs from `baseline/usb-files/sysresccd/boot/x86_64/`. The
original USB capture that supplied them is gone, so regenerate them from any
candidate ISO with `packaging/extract_boot_runtime.sh [ISO]` (default
`baseline/last-known-good.iso`; it never overwrites). Both harnesses take an
optional ISO path, default to `baseline/last-known-good.iso`, and need a
`<iso>.sha256` sidecar. They need `qemu-system-x86_64` and OVMF (`edk2-ovmf`)
and run under QEMU software emulation. `packaging/build_nvidia.py` still needs
the missing candidate-2 ISO and cannot be rerun; it was the candidate-3 build
step. `tests/boot_iso.py` needs only OVMF and an ISO. All three harness runs
passed against candidate 5 on 2026-09-19 (see the
[checkpoint](build-checkpoint.md)).

The guest exercises:

- GPT with FAT32 EFI content, Btrfs subvolumes and a read-only snapshot, hard and
  symbolic links, a Btrfs swapfile, a swap partition with a fixed UUID, and raw
  partition data.
- Source rejection while a subvolume is mounted or swap is active.
- Forced termination of a real Partclone capture without manifest publication.
- Full-source SHA-256 before and after capture, proving the test source did not
  change during capture.
- A corrupt backup rejected with the entire test target unchanged.
- Restore followed by SHA-256 checks of fixture files, subvolume-list comparison,
  link checks, swapfile mapping, swap UUID preservation, and raw-byte comparison.
- A separate primary DOS/MBR table with ext4, restored and checked by file hash.

To isolate duplicate Btrfs UUIDs for content checks, the guest removes the source
fixture's Btrfs signature **after** the preservation check. This is restricted
to the disposable guest source and is not a hardware recovery instruction.

Serial logs and disk files remain in the printed evidence directory. Do not
mistake retained test disks for a backup of the actual workstation.

## Firmware boot and launcher checks

`python3 tests/boot_iso.py dist/<candidate>.iso` boots the actual ISO through
OVMF UEFI, with no writable data disk attached. Use `tests/qmp.py` with the
printed `qmp.sock` path to capture the screen, send keys, or quit the VM.
The ISO must reach the XFCE desktop, activate the application launcher, and
provide the tty2 text-menu fallback. Record screenshots for each observation.

## What VM success does not establish

The additional [two-VM rehearsal](two-vm-rehearsal.md) now establishes restored
UEFI boot for a disk-installed Linux fixture, with the source disk and rescue
media absent. It passed on 2026-09-10. The limitations below describe the original
synthetic round-trip fixtures and the remaining hardware/workstation exclusions.

The EFI fixture is a content sample, not an installed operating system. These
checks alone do not establish that a restored workstation boots (real-hardware
round trips are recorded in [the checkpoint](build-checkpoint.md)), that its hardware
works in the rescue environment, or that every Btrfs feature combination is
supported. The MBR test does not validate BIOS bootstrap recovery: the current
DOS backup stores partition definitions, not arbitrary bootstrap/gap contents.
Extended/logical DOS tables, hybrid GPT/MBR and multi-device Btrfs are rejected.

Real-hardware round trips have since been run (in place on 2026-09-10 and
2026-09-19, and against an isolated spare on 2026-09-14 without saved logs), but
the maintainer accepted these as sufficient on 2026-09-19 instead of a further
isolated-spare rehearsal. Should one be run, a spare disk must be designated for
a destructive recovery rehearsal. Record its freshly observed by-id path, model, serial,
capacity and sector size, and obtain explicit authorization for that disk.
The original SystemRescue USB is excluded. Rehearse backup/restore and boot with
only the intended restored system visible, avoiding duplicate filesystem UUIDs.
After those checks, build/tag the release, verify its payload and checksum,
and flash only a separately identified new USB when explicitly requested.
