# Second repair pass — 2026-09-09

Work resumed from the September 8 candidate-1 checkpoint. The original USB and
preserved baseline remain unchanged; all development writes use project files
and disposable QEMU disks.

## Changes

- The backup engine checks source eligibility itself, both before probing and
  immediately before imaging. Mounted filesystems, Btrfs subvolume mounts,
  active swap, loop-backed boot media and stacked-device ancestors are checked.
  Discovery errors fail closed. Active stacked sources and multi-device Btrfs
  are rejected because this application captures one physical disk per job.
- Corrected `losetup` output selection and `swapon` column selection against
  the installed rescue runtime. Filesystem probes specify the filesystem type
  to avoid stale autodetection after formatting/restoring.
- A file-only Python validator checks both GPT header CRCs, the partition-array
  CRC, header agreement, disk capacity/sector geometry, partition bounds,
  overlap, numbers, sizes and GPT partition UUIDs against the manifest.
  The validator runs before backup publication, verification and target access.
- DOS primary tables are checked for ranges, overlap and correspondence.
  Extended/logical DOS tables and hybrid GPT/MBR tables are explicitly rejected;
  their recovery has not been established. This narrows the accepted backup
  set instead of silently accepting an untested table layout.
- Restore requires matching logical sector sizes and checks restored partition
  sizes before writing images. Raw images must decompress to exactly the
  manifest's partition size during deep verification.
- Space-estimate discovery failures no longer become a zero-byte estimate.
  The VM demonstrated that Btrfs statvfs omitted metadata copied by Partclone;
  only ext uses the validated used-block calculation, with other filesystems
  conservatively budgeted at full partition size.
- Occupancy reporting no longer describes matching counts as full verification.
  Btrfs occupancy probing is skipped when duplicate filesystem UUIDs exist;
  isolate the restored copy before mounting it for independent content checks.
  Removed the unproven whole-disk `wipefs` instruction from recovery guidance.
- The ISO builder excludes Python bytecode caches from the runtime payload.

The GPT backup layout is described in [GPT fdisk's recovery documentation](https://www.rodsbooks.com/gdisk/repairing.html).
The VM exposed that standalone `nologreplay` is no longer accepted by the
rescue kernel. The corrected Btrfs probe uses `ro,rescue=nologreplay`, following the
[Btrfs kernel version notes](https://btrfs.readthedocs.io/en/stable/Kernel-by-version.html).

## Validation

25 file-only regression tests pass, including GPT fixtures generated independently
with util-linux `sfdisk`, corrupt headers/arrays, manifest mismatches, DOS overlap,
source discovery failure, Btrfs subvolume/stacked ancestors, and valid compressed
raw data of the wrong length.

Candidate 2 was built from clean commit `5fae2b0` and passed all 21 payload-file
comparisons, permissions/ownership and launch configuration checks. It passed
UEFI desktop boot, packaged launcher activation and tty2 fallback checks.

The complete candidate-2 guest run passed with exit 0: GPT/EFI/Btrfs subvolumes,
read-only snapshot, hard/symbolic links, swapfile mapping, swap UUID and raw
content checks, followed by a separate DOS/ext4 file-content round trip. Source
hashes matched across capture, corrupt input left the target unchanged, and
terminating Partclone did not publish a completed manifest. Evidence is linked
from [the checkpoint](build-checkpoint.md). The test compares subvolume identities
and hierarchy, excluding transaction generation counters that change at unmount.

The runtime artifact is unchanged by subsequent test-harness/documentation fixes.
As of this pass it did not establish restored workstation boot or hardware
recovery; see [the checkpoint](build-checkpoint.md) for the hardware results since.
