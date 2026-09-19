# Recovery checkpoint

## Real-hardware round trip — ext4 Linux Mint NVMe (2026-09-19)

I ran a full backup → restore of a 4 TB NVMe holding a Linux Mint install (GPT:
a 512 MiB vfat EFI partition and a 3.6 TiB ext4 root), then rebooted into Mint
with no issues (my report). As in candidate 4, source and restore target were
the **same physical disk**. The manifest and logs are kept privately, not in
this repo.

- **Backup** (2026-09-19T19:03:57Z → 19:07:21Z): both partitions captured with
  `partclone.vfat` / `partclone.ext4` (6.2 MiB used on the EFI partition; 21 GiB
  and 568,629 inodes on ext4), each compressed image checksummed after capture.
- **Restore** (19:40:24Z → 19:46:07Z): re-verified both image checksums and
  partclone structure *before* touching the target, then erased and restored
  the GPT table and both partitions. Partclone reported 100% and
  "Syncing... OK!" for both. Post-restore occupancy: ext4 matched used bytes
  **and** inode count; vfat matched used bytes only (it reports no inode
  count). The tool's own log states these checks do not verify file contents
  or bootability.
- **Independent check** (read-only, after the restore): the restored
  filesystem and partition UUIDs were identical to the manifest.
- **Boot:** my report only. No file-hash comparison, `fsck` or repair-step log
  was captured.

This is not the isolated-spare rehearsal: with one disk as both source and
target there was no untouched original to isolate or compare against, and
duplicate-UUID handling was not exercised. It also cannot supply the identity
of the 2026-09-14 spare disk. What it adds is a complete, logged real-hardware
round trip on a non-Btrfs (ext4) installed OS. Not recorded: which rescue USB
was booted (presumably candidate 5, the only current build), the backup
storage's identity, and whether the separate Verify workflow ran before the
restore (the restore's own pre-verification did).

## Candidate 5 — restore-label fix, hardware verification (2026-09-14)

`dist/system-rescue-0.1.0-candidate5-restore-label-fix.iso` (1,770,061,824 bytes)

SHA-256: `42a666f55cc7075456e5366373283a14e7dba8592dee6c2ad13270a08cb3d5eb`

Fixes the restore/verify picker (`lib/job_select.sh`) to label entries by the
job directory's own name instead of the source disk's model/serial, so a
single physical disk reformatted and re-backed-up under different OS installs
(e.g. renamed job dirs like `KINGSTON_COSMIC_11SEPT2026` vs
`KINGSTON_LINUXMINT_12SEPT2026`) no longer shows as identical, indistinguishable
rows. Built via `sysrescue-customize --auto` against the already-verified
candidate 4 ISO as source, since the pristine `baseline/` archive isn't present
on this machine (see [build inputs](build-inputs.md) for the recovery path).

The build receipt records `source_dirty: true`: the `lib/job_select.sh` fix was
uncommitted at build time. It was committed immediately after ("Label
restore/verify picker by job dir name, not source disk model"), and no other
dirty changes were present, so the built ISO's payload matched that commit
exactly. (Commit hashes in the private development history don't exist in this
repo, which is a squashed snapshot.) This build is reproducible from source, no
longer a dirty-tree artifact.

Flashed to a PNY USB 3.0 flash drive. Direct readback of all 1,770,061,824
bytes matched the ISO SHA-256; see
[flash receipt](evidence/candidate5-pny-flash.json) (device serial redacted).

**Hardware verification (2026-09-14):** I booted this exact USB, took a fresh
backup snapshot, then performed a full restore to a spare 4 TB disk kept
normally offline and disconnected from the workstation, isolated from every
disk currently attached. The restore completed, and the restore/verify picker
displayed correct, distinct names for the job entries — confirming the
`job_select.sh` fix works on real hardware. This is a live, in-person console
observation; no `manifest.json` or backup/restore log files were saved from
this run, so unlike the [candidate 4 round trip](#candidate-4--real-hardware-backuprestore-round-trip-2026-09-10)
there's no file-based evidence receipt to archive.

I also confirmed this boot used the normal NVIDIA-enabled entry, not the
basic-display fallback that disables NVIDIA. This is the first confirmed
physical boot of the RTX 5080 under this project's NVIDIA build (added in
candidate 3, carried unchanged through candidates 4 and 5 — see
[candidate 3](#candidate-3--nvidia)), closing that previously pending item.

In substance this is the first real backup → restore cycle against a properly
isolated spare disk (not the source disk itself), which is what the
[hardware rehearsal checklist](hardware-rehearsal.md)'s item 2/3 has been
waiting on since the candidate-4 in-place test. It falls short of that
checklist's own protocol in two ways: the spare disk's by-id/model/serial/
capacity weren't recorded, and no manifest/log evidence was saved. The spare
disk has since been wiped, so neither gap can be closed retroactively — this
test's evidence is permanently limited to the live console observation above.
Any future rehearsal on a different spare should capture identity and logs at
the time, since this opportunity is gone.

## Candidate 4 — backup progress

`dist/system-rescue-0.1.0-candidate4-nvidia-progress.iso`

SHA-256: `52522b5b8d5f657d5e6019d303efc15e36fdb4e3167d6af0a659435e168dd651`

Enables Partclone progress and dd transfer statistics; announces checksum start
and completion. Built with `packaging/build_progress.py`. Application payload
verified against source; NVIDIA SRM, base filesystem, kernel, initramfs and boot
configs match candidate 3 byte for byte. All 25 regression tests and isolated
NVIDIA guest packaging and GPT/DOS backup/restore checks passed. Guest log:
[Candidate 4](evidence/candidate4-roundtrip.log). Progress updates are present
in the guest log. Downloads copy hash matches. Candidate 4 was flashed to a
KANGURU SS3 USB drive on September 10. Direct readback of all 1,768,292,352
bytes matched the ISO checksum; see
[flash receipt](evidence/candidate4-kanguru-flash.json) (device serial redacted).

Candidate 3 booted successfully with NVIDIA, backed up a 2 TB Windows disk to
a separate 4 TB drive, and that backup was verified. This is user-reported
physical backup evidence, not a physical restore test.

### Candidate 4 — real hardware backup/restore round trip (2026-09-10)

Physical boot of candidate 4 is now established: I booted the KANGURU SS3
media flashed above and used it to back up, then restore, the workstation's
live production NVMe (the disk it normally boots from) — with that disk as
**both** source and restore target, not an isolated spare. Evidence lives
with the image on offline backup storage, in a dated job folder:

- **Backup** (`backup_20260910T174445Z.log`, `manifest.json`): captured
  partition 1 (vfat, 552 MiB) and partition 2 (btrfs, 58 GiB) via
  `partclone.vfat`/`partclone.btrfs`, each image checksummed after capture.
  The manifest records both filesystem UUIDs.
- **Restore** (`restore_20260910T192731Z.log`,
  `partclone_restore_20260910T192731Z_part{1,2}.log`): verified both image
  checksums and partclone structure *before* touching the target, then erased
  and restored the GPT table and both partitions. Partclone reported 100%
  complete for both, "Syncing... OK!". Post-restore occupancy checks matched
  the manifest within 1 MiB on both filesystems (the tool's own log notes this
  is a bytes-used check, not a per-file/inode or content check).
- **Reboot verification** (done independently, from the running restored
  system, not from the rescue log): root is mounted rw on the restored btrfs
  partition with no errors, its UUID and the `/boot` vfat
  UUID match the manifest exactly, used space (58G) matches the
  manifest's 58 GiB, `bootctl status` shows a normal Limine/UKI boot with the
  expected entry, `systemctl --failed` is empty, and `journalctl -b -p err`
  shows no filesystem errors (only a pre-existing, already-tracked desktop
  crash-loop and one harmless `nofail` mount timeout for an unrelated drive
  that was separately reformatted the same day — unconnected to this restore).

This is the first confirmed real, physical, full backup → restore → reboot
cycle on production hardware, and it passed. It is **not** a substitute for
the [hardware rehearsal](hardware-rehearsal.md) protocol's spare-disk
isolation step below — source and target were the same physical disk, so
there was no untouched original to isolate or compare against, and
duplicate-UUID handling was never exercised. This was run deliberately,
in-place, against prior caution, with a separate scripts/state snapshot
already saved to offline backup storage as a fallback in case the restore
failed.

## Candidate 3 — NVIDIA

`dist/system-rescue-0.1.0-candidate3-nvidia.iso` (1,770,061,824 bytes)

SHA-256: `370eddd462eb57e4f12aa28a382fa532e665368b31d62871b7538a39241bb3a3`

Adds NVIDIA 610.57.04 open kernel modules built for `6.18.41-1-lts`, matching
firmware/userspace and EGL dependencies, as a separate early-loaded SRM.
Candidate 2's base system, kernel, initramfs and application are unchanged.
Normal boot entries blacklist Nouveau/Nova; the basic-display entry also
disables NVIDIA. See [build details](nvidia-image.md).

Completed checks on this exact ISO:

- All 25 application regression tests pass.
- Existing 21-file application payload verified; extracted NVIDIA SRM hash
  matches the built module. Signed package inputs and overlay hashes recorded.
- Live-guest kernel ABI/version metadata and shared-library dependencies pass.
- GPT/EFI/Btrfs/swap/raw and DOS/ext4 backup/restore fixtures pass, guest exit 0.
- OVMF UEFI desktop, packaged launcher via `gio launch`, and tty2 menu pass.
- Test VMs stopped. No host disks were attached to either test VM.

[Results](evidence/candidate3-results.json), [guest log](evidence/candidate3-roundtrip.log),
[desktop](evidence/candidate3-desktop.png), [launcher](evidence/candidate3-launcher.png),
[tty2](evidence/candidate3-tty2.png).

Physical RTX 5080 boot was pending as of this candidate; confirmed 2026-09-14
via candidate 5, which carries this NVIDIA build unchanged (see
[candidate 5](#candidate-5--restore-label-fix-hardware-verification-2026-09-14)
above). The candidate-2 installed-OS two-VM boot rehearsal was not repeated
for candidate 3. No physical restore was authorized as of this candidate.

Candidate 3 was flashed to a KANGURU SS3 USB drive on September 10. All
1,770,061,824 bytes were read back using direct I/O and matched the ISO
SHA-256. See the [flash receipt](evidence/candidate3-kanguru-flash.json)
(device serial redacted). This candidate was later booted on real hardware
(see candidate 4 above). Original source media and `baseline/` were untouched.

## Candidate 2

`dist/system-rescue-0.1.0-candidate2.iso`

SHA-256: `ac9a63432b290eee910f3160bd17f7e185d19694820b7a2c62586b4a20b77cff`

Built from clean commit `5fae2b0b21ed13d7c268b4bc5b52c20ca9df46ea`.
The receipt is `dist/system-rescue-0.1.0-candidate2.iso.json`.
Later changes to test harnesses and documentation do not alter its payload.
This is a development candidate, not a final hardware-tested release.

## Completed

- Source and partition-table safety repairs, described in [repair pass 2](repair-pass-2.md).
- 25 file-only regression tests pass. All runtime shell scripts pass syntax checks.
- Extracted and compared all 21 runtime/desktop payload files, permissions,
  root ownership, YAML launch settings and custom-module activation.
- Booted this exact ISO via OVMF UEFI in QEMU with networking disabled and no
  host disks. Reached the XFCE desktop, activated the packaged `.desktop` file
  through `gio launch`, and confirmed Ctrl+Alt+F2 opens the fallback text menu.
  The boot-test VM was stopped.
- Candidate-2 GPT fixture backup/restore passed SHA-256 file checks for EFI and
  Btrfs content, subvolume UUID/hierarchy comparison, snapshot read-only state,
  hard/symbolic links, swapfile mapping, swap UUID preservation, and raw bytes.
  Whole-source hashes matched before/after capture. Corrupt images were rejected
  with the entire target unchanged; interrupted Partclone capture published no
  completed manifest.

Screenshots: [desktop](evidence/candidate2-desktop.png),
[activated launcher](evidence/candidate2-launcher.png),
[text fallback](evidence/candidate2-tty2.png).

## Final combined VM result

**PASS**, guest exit 0: both GPT/EFI/Btrfs/swap/raw and primary DOS/ext4 round
trips completed using the application installed in candidate 2.
A readable copy of the raw log is committed as
[candidate-2 round-trip evidence](evidence/candidate2-roundtrip.log).
The VM was stopped automatically. No test VMs remain intentionally running.

The prior candidate-2 run completed the GPT checks but stopped at the test
fixture's interactive ext4-format confirmation. That harness issue was fixed
with explicit `mkfs.ext4 -F` on the disposable guest source. The idle VM was
stopped, and the complete corrected run passed. No runtime application
change was required.

## Resume / release boundary

The [two-VM installed-system rehearsal](two-vm-rehearsal.md) passed on September
10 using this exact candidate. A source disk booted under UEFI, was captured and
deep-verified without changing its whole-disk hash, then was restored to a blank
disk in a separate VM. The restored disk booted alone with fresh firmware
variables and passed file/hash/link/subvolume checks without repairs. Both VMs
are stopped. This closes the installed-OS boot gap in the synthetic VM fixtures;
it did not establish physical hardware or actual workstation recovery as of
that rehearsal; the real-hardware round trips recorded above followed it.

As of 2026-09-10 a separate NVMe drive had been designated for system backup
storage, not as a restore target, and no physical target had been authorized
for erasure. That has since changed: a production NVMe (2026-09-10), an
isolated spare disk (2026-09-14) and a second NVMe (2026-09-19) were each
restored on real hardware, as recorded above. The proposed USB restore had
been replaced by the two-VM rehearsal.

The [hardware rehearsal checklist](hardware-rehearsal.md) provides the media
identity, authorization and results record for the spare-disk protocol below.
On 2026-09-10, all 25 file-only regression tests passed again. Separately that
same day, a real in-place backup/restore of the production NVMe was performed
and confirmed (candidate 4, see above) — real physical evidence, but against
the source disk itself rather than an isolated spare, so it did not close
item 2/3 below.

On 2026-09-14, a real backup → restore cycle was performed with candidate 5
against an isolated spare 4 TB disk kept normally offline (see
[candidate 5](#candidate-5--restore-label-fix-hardware-verification-2026-09-14)
above) — in substance this closes item 2/3. The checklist's own identity/
logging protocol wasn't followed for this run (no recorded by-id/model/serial/
capacity for the spare, no saved manifest/logs), and that spare disk has since
been wiped, so this can't be retroactively completed. Treat item 2/3 as
functionally satisfied by this test; the missing paperwork is a permanent gap
in this record, not an open follow-up.

On 2026-09-19 a third real round trip was run and logged (in place, on an ext4
Linux Mint NVMe; see the [top section](#real-hardware-round-trip--ext4-linux-mint-nvme-2026-09-19)).
Source and target were the same disk, so it does not change item 2/3.

1. Review the completed VM evidence and known exclusions in
   [recovery testing](recovery-testing.md).
2. Obtain explicit designation of a spare target disk before any destructive
   hardware rehearsal. Verify its fresh by-id/model/serial/capacity and
   logical sector size. The original SystemRescue USB is excluded.
3. Rehearse real backup/restore and boot with duplicate filesystem UUIDs isolated.
   The synthetic EFI fixture is not a bootable installed OS; BIOS bootstrap
   recovery, 4Kn hardware and every Btrfs feature combination are not established.
4. Only after recovery rehearsal, produce a final tagged release and release
   notes, then flash a separately identified new USB when explicitly requested.

Original source USB and `baseline/` remain untouched. On September 10,
candidate 2 was flashed to a KANGURU SS3 USB drive. Direct readback of all
1,386,020,864 ISO bytes matched the candidate SHA-256. See
[flash receipt](evidence/candidate2-kanguru-flash.json) (device serial
redacted). Physical boot testing was pending at the time of that build.
Candidate 1 was preserved alongside candidate 2 at the time. As of 2026-09-19,
`dist/` holds only candidate 5: the `dist/` paths above for candidates 2–4 record
what was built, those ISOs are no longer present on the development machine
(their SHA-256 values above still identify them), and
`baseline/last-known-good.iso` is candidate 5.
