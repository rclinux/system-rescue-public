# System Rescue 0.1.0 — release notes

## What this is

A bootable rescue USB image (UEFI, x86-64, XFCE desktop) with a menu-driven
tool for whole-disk backup, backup verification, and restore. It is built on
SystemRescue and adds a `system_rescue` application with three functions:

- **Backup** — images a whole disk to a folder on another disk, one partition
  at a time, storing used blocks only (partclone) and compressing the result.
  Each image is checksummed and the disk layout is recorded in a manifest.
- **Verify a backup** — re-reads a stored backup and confirms it is intact,
  without needing a restore target. Read-only.
- **Restore** — writes a backup back onto a chosen disk, **erasing it**. The
  backup is verified before anything is written, the target must be confirmed
  by typing its serial number, and the result is checked afterward.

The image also carries an NVIDIA driver (610.57.04, built for the rescue
kernel) so the desktop works on machines with a recent NVIDIA card. A
basic-display boot entry (NVIDIA disabled) is the fallback.

Instructions: [backup, verify and restore guide](backup-and-recovery-guide.md).

## Release file

| | |
| --- | --- |
| File | `system-rescue-0.1.0.iso`. Byte-identical to candidate 5 (checked with `cmp`), not rebuilt, so the candidate-5 evidence below applies to it directly |
| Size | 1,770,061,824 bytes |
| SHA-256 | `42a666f55cc7075456e5366373283a14e7dba8592dee6c2ad13270a08cb3d5eb` |

Verify the checksum before writing it to a USB stick. The guide explains how.

## What has been tested, and what that does and does not show

Each row is a separate kind of evidence. A pass in one row is not a pass in
another. "Ran without error" is not "data restored correctly", and neither
means "the restored system boots".

| Evidence | Result | Where |
| --- | --- | --- |
| Regression tests (25, no real devices) | Pass (re-run 2026-09-21) | `tests/` |
| ISO payload (application files, permissions, ownership, launcher config) matches the source at tag `v0.1.0` | Pass, 21 payload files (2026-09-21) | `docs/evidence/release-0.1.0-payload-verify.log` |
| UEFI boot to desktop, launcher and tty2 fallback, in a VM | Pass on candidates 1–3 (screenshots). Not recorded as re-run in a VM on candidate 5; candidate 5 has booted on real hardware (below) | `docs/evidence/candidate*-desktop.png` etc. |
| Backup → restore round trips in a VM: GPT + FAT32 EFI + Btrfs (subvolumes, read-only snapshot, hard/symbolic links, swapfile, swap UUID, raw partition) and DOS/MBR + ext4, with file-hash comparison | Pass on candidate 5 (2026-09-19) | `docs/evidence/candidate5-roundtrip.log` |
| Corrupt backup rejected with the target left unchanged; killed capture publishes no manifest; busy source rejected | Pass on candidate 5 | same log |
| Two-VM rehearsal: capture a disk-installed Linux system, restore it in a separate VM, boot the restored disk alone under UEFI, compare file hashes, links and subvolumes | Pass on candidate 5 (2026-09-19), no repairs | `docs/evidence/candidate5-two-vm-results.json` |
| Real hardware, in place (source and target are the same disk): NVMe with a Linux Mint ext4 install, backup then restore on candidate 5 | Backup log and manifest saved; both image checksums re-verified before restore; after restore, used bytes and inode count matched on the ext4 partition, used bytes matched on the FAT32 partition. Booted into the restored system with no problems (**maintainer's report only; no file hashes or fsck saved**) | Logs are kept privately because they contain disk serials and UUIDs; the restore results are summarized in `docs/build-checkpoint.md` |
| Real hardware, in place: production NVMe, candidate 4 (2026-09-10) | Restored system rebooted; partition UUIDs and byte counts matched | checkpoint |
| Real hardware, isolated spare disk, candidate 5 (2026-09-14) | Restore completed; job picker showed correct names; NVIDIA entry booted on an RTX 5080. **Maintainer's console observation only; no logs saved and the spare disk's identity was not recorded** | checkpoint |

For timing, the in-place run above backed up 21 GiB used on a 4 TB disk in
about 3½ minutes and restored it in about 6 minutes. These are single-run
figures onto a fast destination. Do not treat them as a guarantee.

**The maintainer accepted the in-place round trips as sufficient in place of a
separate isolated-spare rehearsal (2026-09-19).** That decision is about
releasing. It does not add evidence. The items under "Not established" below
remain untested.

## Not established

These were not tested. Do not assume they work:

- Restoring onto a **second disk in the same machine and booting with both
  present.** The restore reproduces filesystem UUIDs exactly, so both disks
  then carry the same UUIDs, and the machine may boot the wrong one on any
  given boot. The tool warns before and after a restore when this applies.
  Disconnect one disk before booting. Duplicate-UUID handling on real hardware
  was not exercised.
- **File-content comparison after a real-hardware restore.** Hardware evidence
  is occupancy (bytes and inodes) plus a reported successful boot. File hashes
  were compared only in VMs.
- **Legacy BIOS boot** of the rescue USB, and **BIOS bootstrap-code recovery**
  for DOS/MBR disks. The tool stores the MBR partition definitions, not the
  boot code or the gap before the first partition.
- **4Kn (4096-byte logical sector) disks.**
- **Every Btrfs feature combination.** Btrfs with subvolumes, a snapshot and a
  swapfile passed in a VM; that is not the whole feature space.
- **Other filesystems.** partclone supports many (xfs, ntfs, exfat, f2fs, and
  more) and the tool will use it for them. Only ext4, Btrfs and FAT32 were
  exercised.
- **Encrypted (LUKS) and LVM disks.** These partitions are copied as raw bytes
  (full size, not used-blocks-only), so the backup is as large as the
  partition. Only a synthetic raw partition was tested, in a VM; no real
  LUKS or LVM disk is documented as tested.
- **Backup of a live, mounted disk.** The tool refuses; back up from the
  rescue USB only.

## Known limits by design

- Restore needs a target **at least as large** as the source, with the **same
  logical sector size**.
- The destination for a backup must be a **different disk** from the source,
  and a restore target must be a different disk from the one holding the
  backup. The tool enforces both.
- Rejected as unsupported: extended/logical DOS partition tables, hybrid
  GPT/MBR, multi-device Btrfs.
- Swap is not imaged. It is recreated on restore with the same UUID, because
  systems reference swap by UUID.
- Backups are only as good as the disk they sit on. Keep a second copy of
  anything irreplaceable.

## Changes since candidate 4

Candidate 5 is the only functional change: the Restore and Verify pickers
label each backup by its **folder name** instead of the source disk's model and
serial. Before, several backups of one disk (for example, different operating
systems installed and backed up in turn) appeared as identical rows. Rename a
job folder to something meaningful and that is what the picker shows.

## Earlier history (for context)

- Candidates 1–2: recovered application from the original rescue USB, two
  safety-repair passes, rebuilt ISO, VM round trips and two-VM rehearsal.
- Candidate 3: NVIDIA driver added.
- Candidate 4: backup progress display; first real-hardware round trip.
- Candidate 5: picker labelling fix.

Details, logs and hashes: `docs/build-checkpoint.md`.
