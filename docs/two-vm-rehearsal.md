# Two-VM installed-system recovery rehearsal

## Result — 2026-09-10

**PASS:** candidate 2 captured the bootable source installation, deep-verified
the backup, restored it in the separate recovery VM, and the restored disk booted
under UEFI without repairs. All five stages completed with QEMU exit 0. Both VMs
are stopped. The full-source hash matched before/after capture; restored file
hashes, subvolume identities/hierarchy and read-only snapshot state matched.
Both installed-system boots checked EFI mode, root/home subvolume mounts, file
hashes and hard/symbolic links. The bootloader, kernel and initramfs hashes passed.

Evidence: [results and QEMU commands](evidence/candidate2-two-vm-results.json),
[readable serial logs](evidence/candidate2-two-vm.log). Raw logs and virtual disks
were kept in `packaging/build/two-vm-157vh2m9/`, which is git-ignored and has
since been cleared; the readable log and results JSON above are the retained
evidence.

The first attempt's disk-count assertion incorrectly included QEMU's empty
optical drive. A diagnostic boot isolated that harness error; the corrected
five-stage run used entirely new disk files. No runtime application change was
needed. Some rescue shutdown logs report failure to unmount the read-only live
ISO mount; the test data mounts were explicitly unmounted before the stage
success markers, and the guests completed poweroff. Installed-system boot checks
passed both as a startup service and when repeated from the serial console.

## Reproduce

Run `python3 tests/two_vm_recovery.py` from the repository. It takes an optional
ISO path (default `baseline/last-known-good.iso`, which needs a `.sha256`
sidecar) and loads the kernel/initramfs from `baseline/usb-files/`, regenerated
with `packaging/extract_boot_runtime.sh` (see [recovery testing](recovery-testing.md)).
The 2026-09-10 pass above used candidate 2, whose ISO no longer exists; the
rehearsal was repeated for candidate 5 on 2026-09-19 and all five stages passed
([results](evidence/candidate5-two-vm-results.json),
[log](evidence/candidate5-two-vm.log)). The runner verifies
the ISO's checksum against its sidecar and creates a new `packaging/build/two-vm-*/` evidence
directory. No real disks or networking are attached. The source and recovery VMs
have distinct machine UUIDs; each firmware boot starts with fresh OVMF variables.

The installed Linux fixture is assembled from the preserved SystemRescue root
filesystem, with a newly generated disk-root initramfs, systemd-boot at the UEFI
fallback path, a FAT32 EFI partition, Btrfs root/home subvolumes, a read-only
snapshot, and representative files with hard and symbolic links. It is a test
installation, not a copy of the workstation or an independently downloaded distro.

The stages run sequentially:

1. **Setup:** install the fixture onto a new 12 GiB sparse source disk.
2. **Source boot:** firmware-boot that disk alone and check EFI mode, root/home
   mounts, file hashes and links. No ISO, direct kernel boot or vault is attached.
3. **Capture:** boot the candidate rescue runtime with the source and a separate
   24 GiB vault; capture and deep-verify using the application installed in the
   candidate. Compare whole-source hashes before and after capture.
4. **Restore:** start the recovery VM with only a blank 12 GiB target and the
   vault. Deep-verify and restore using the candidate application. Check file
   hashes, subvolume identities/hierarchy and snapshot read-only state.
5. **Recovery boot:** firmware-boot the restored disk alone with fresh firmware
   variables. Repeat the installed-system checks without the source, vault, ISO,
   host kernel or host initramfs attached.

Serial logs, exact QEMU argument lists, sparse disks and incremental `results.json`
are retained in the evidence directory. A stage is recorded as passing only after
its checks and a clean QEMU shutdown. Interrupted or failed stages are not passes.
The read-only share contains only the guest test script, not an alternate app.
Rescue automation uses the preserved kernel/initramfs and candidate ISO, as in the
existing integration harness; separate firmware boot stages prove disk bootability.

This tests bootable virtual-system recovery. It does not establish workstation
recovery, physical NVMe/USB compatibility, Secure Boot, BIOS bootstrap recovery,
encrypted root, or every Btrfs configuration. As of 2026-09-10 a separate NVMe
was designated for backup storage, and this VM rehearsal designated no
physical restore target; later real-hardware round trips are recorded in
[the checkpoint](build-checkpoint.md).
