# Candidate 2 hardware recovery rehearsal

Status: preparation only. No hardware restore or restored-system boot has been
performed *to this document's protocol*. Complete this record during the
rehearsal; empty fields are not passes.

Real hardware backup/restore cycles have happened outside this protocol,
recorded in [the checkpoint](build-checkpoint.md): an in-place round trip on the
source disk itself (2026-09-10), an isolated spare-disk round trip (2026-09-14),
which also confirmed physical RTX 5080 boot under the NVIDIA-enabled entry, and
a logged in-place round trip on an ext4 Linux Mint NVMe (2026-09-19). The
2026-09-14 test is treated there as functionally satisfying item 2/3 below, but
none of the three recorded this document's identity/authorization fields, the
spare-disk run saved no manifest/log, and the two in-place runs used the same
disk as source and target, so nothing here is marked as passed.

## Media and authorization record

Record identities again from the rescue environment immediately before use.
Device names such as `/dev/sda` can change between boots.

| Role | Stable by-id path | Model / serial | Bytes / logical sector size |
| --- | --- | --- | --- |
| Installed system to capture | Pending | Pending | Pending |
| Backup storage (separate from source and target) | Pending | Pending | Pending |
| Spare restore target (all contents will be erased) | Pending | Pending | Pending |
| Candidate rescue boot media | Pending | Pending | Pending |

- Explicit authorization to erase the identified spare target: **pending**.
- Authorization to flash new rescue media, if needed: **pending**, separate from
  authorization to erase the restore target.
- Original SanDisk SystemRescue USB: excluded from all writes.
- Target capacity must be at least the source capacity, with matching logical
  sector size. Confirm backup storage has sufficient free space.

Read-only inventory commands:

```sh
ls -l /dev/disk/by-id/
lsblk -b -o NAME,PATH,TYPE,TRAN,SIZE,MODEL,SERIAL,LOG-SEC,FSTYPE,MOUNTPOINTS
findmnt
swapon --show
```

## Rehearsal sequence

1. Check the candidate ISO against its recorded SHA-256:
   `ac9a63432b290eee910f3160bd17f7e185d19694820b7a2c62586b4a20b77cff`.
   Use candidate 2 for the rehearsal and record the boot-media preparation and
   verification separately. Do not overwrite the original USB.
2. Before shutting down the installed system, select representative files and
   record their hashes in separate evidence storage. Record the expected root,
   EFI, Btrfs subvolume and swap layout. Identify any dependencies on other
   disks so the boot test can demonstrate the intended recovery scope.
3. Boot candidate 2 in UEFI mode. Confirm the desktop, application launcher,
   keyboard, display and required storage devices work. Save the fresh media
   inventory and compare it to the authorized identities above.
4. Keep all source filesystems unmounted and source swap inactive. Mount only
   the separately identified backup storage. Capture the source using the
   packaged Backup workflow and save the job path, manifest and application log.
5. Run the packaged Verify workflow with deep verification enabled. Record its
   exit status and log. Stop on any capture or verification failure.
6. Recheck the spare target identity and authorization immediately before
   Restore. Confirm the displayed model, serial and capacity, then restore the
   verified job. Save the complete restore result; successful process exit alone
   does not establish successful recovery.
7. Shut down. Physically disconnect or otherwise reliably isolate the original
   source before mounting or booting the restored copy, avoiding duplicate
   filesystem UUIDs. Never erase source signatures to achieve isolation on real
   hardware. Keep unrelated disks isolated where practical, especially disks
   containing another EFI system partition.
8. Boot the restored system in UEFI mode. Confirm it boots from the restored
   disk's own EFI partition and root filesystem. Compare the selected file
   hashes, subvolume layout and swap configuration, and exercise representative
   applications. Record any repair steps; a boot requiring repairs must not be
   reported as an unassisted restore/boot pass.
9. Shut down and isolate the restored disk before reconnecting the original.
   Preserve the backup and evidence. Update the checkpoint with observed results
   before deciding whether a final release is justified.

## Results to fill in

| Evidence | Result / log location |
| --- | --- |
| Candidate checksum and rescue-media verification | Pending |
| Fresh identities and target erase authorization | Pending |
| Rescue hardware and launcher checks | Pending |
| Backup job and capture exit status | Pending |
| Deep verification exit status | Pending |
| Restore exit status and complete log | Pending |
| Source isolation and restored EFI/root identity | Pending |
| Restored-system boot and any repairs | Pending |
| Independent file hashes, subvolumes and swap checks | Pending |
| Final release decision | Pending |

The exclusions in [recovery testing](recovery-testing.md) still apply. This
rehearsal validates the recorded hardware and filesystem layout only.
