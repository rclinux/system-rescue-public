# Initial USB review — 2026-09-08

## Observed baseline

- SanDisk Ultra, approximately 28.6 GiB, ISO label `RESCUE1302`.
- SystemRescue 13.02 with custom `sysresccd/customize.srm` (4,169,728 bytes).
- Shipped rescue root filesystem passed its included SHA-512 checksum. This checks consistency with the on-media checksum, not authenticity against a separately trusted upstream signature.
- Custom root overlay has 19 files: 18 under `/usr/local/system_rescue` and one desktop launcher under `/root/Desktop`.
- Graphical desktop enabled by YAML; text menu fallback configured on tty2.
- Runtime includes Partclone 0.3.48 and Btrfs tools 6.17.1. The installed host reported newer Btrfs tools; compatibility must be tested, not assumed from version numbers.
- No actual USB boot, backup, or restore was performed in this review.

## Confirmed defects to fix

1. `verify_backup_job` accepts a v4 manifest with an empty partition array and an empty partition-table dump. Reproduced with temporary regular files; exit status was 0. Validate manifest schema, required images and table structure before reporting a usable backup or allowing restore.
2. `dump_partition_table` reports success when a simulated `sgdisk --backup` fails. The subsequent `printf` masks the failure. Reproduced with a shell-function stub, never a real disk command. Propagate failure explicitly through the backup flow.
3. `_probe_fs_stats` uses `mount -o ro` for Btrfs, without `nologreplay`. Read-only Btrfs mounts can replay a tree log. Review per-filesystem probe options and guarantee intended source preservation. Reference: https://btrfs.readthedocs.io/en/stable/Administration.html

## Further review and testing

- The menu does not use `set -e`; audit explicit error checks for directory creation, checksumming, JSON generation, and partition enumeration. Never infer safety from `set -e` in a conditional function call.
- Validate source eligibility inside the backup engine as well as the UI; the CLI calls the engine directly.
- Post-restore used-space/inode comparisons are coarse checks, not file-content or boot verification. Btrfs does not provide a conventional inode count through `df`.
- Verify recovery of EFI and all Btrfs subvolumes, including snapshots and the swapfile. Test supported Btrfs feature flags against the shipped rescue tools.
- Restore requires a destination at least as large in exact bytes as the original disk; used-space size alone is insufficient.
- Recovery handles one physical source disk per operation, not every disk in the computer in one job.
- Review duplicate-UUID guidance. The current suggestion to run `wipefs -a` on a whole disk should not be treated as a tested way to remove every filesystem signature inside its partitions.
- The existing build script references missing packaging and customizer files, and its comments refer to earlier startup behavior. Reconstruct from observed artifacts and official build documentation.

## Positive design elements

Per-partition Partclone images with zstd compression, partition-table preservation, dated job folders, disk identity confirmation, capacity checks, image hash and structural checks before restore, per-partition logs, and an exclusive menu job lock.
