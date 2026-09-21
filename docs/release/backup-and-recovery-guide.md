# System Rescue — backup, verify and restore guide

Restore **erases a whole disk**. Read the "Before you start" section, and stop
if any step shows a disk you do not recognize.

## Before you start

- **Two separate disks are needed for a backup:** the disk you are backing up,
  and a destination disk with enough free space. The tool refuses to write a
  backup onto the disk it is copying.
- **Restore needs three roles:** the disk holding the backup, the target that
  will be erased, and the rescue USB. The target must not be the disk holding
  the backup.
- **The target must be at least as large as the original disk** and have the
  same logical sector size (almost all disks are 512 bytes; some are 4096).
- **Write down each disk's model and serial number before booting the rescue
  USB**, from the label or from the running system (`lsblk -o NAME,MODEL,SERIAL,SIZE`).
  Device names such as `/dev/nvme0n1` and `/dev/sda` can change from one boot
  to the next. The serial does not. Identify disks by serial.
- **Space:** the tool estimates what the backup needs (uncompressed, so the
  real backup is usually smaller) and refuses if the destination looks too
  small.
- Boot the rescue USB in **UEFI mode**. Legacy BIOS boot has not been tested.

## Making the rescue USB

Do this on any Linux machine. It **overwrites the USB stick completely**, and
picking the wrong device destroys that device's data.

1. Check the download:

   ```sh
   sha256sum -c system-rescue-0.1.0.iso.sha256
   ```

   It must print `OK`. If not, do not use the file.

2. Identify the stick by its stable ID, not by `/dev/sdX`:

   ```sh
   ls -l /dev/disk/by-id/ | grep usb
   lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN
   ```

   Confirm the model, serial and size match the stick in your hand, and that
   nothing on it is mounted or needed.

3. Write it (replace the placeholder with the exact by-id path from step 2):

   ```sh
   sudo dd if=system-rescue-0.1.0.iso of=/dev/disk/by-id/usb-EXAMPLE bs=4M conv=fsync status=progress
   sync
   ```

4. Read it back and compare. The image is 1,770,061,824 bytes:

   ```sh
   sudo head -c 1770061824 /dev/disk/by-id/usb-EXAMPLE | sha256sum
   ```

   The result must equal the SHA-256 in the release notes. If it does not,
   write it again, or try a different stick.

## Starting the rescue environment

1. Boot from the USB stick in UEFI mode (use the firmware's one-time boot menu).
2. At the boot menu, choose the **normal entry**. If the screen stays blank or
   the desktop will not start, reboot and choose the **basic-display** entry,
   which turns the NVIDIA driver off.
3. You get an XFCE desktop with a **"System Rescue — Backup & Restore"** icon.
   It opens a maximized terminal window running the menu. The same menu is also
   on the second console: press **Ctrl+Alt+F2** for it, and **Ctrl+Alt+F1** to
   return to the desktop. The menu offers **Backup**, **Restore**,
   **Verify a backup**, and, in the live environment, **Shut down** and
   **Reboot**. Move with the arrow keys and press Enter; Esc backs out of a
   picker.
4. Only one job can run at a time. If you start a second, it waits for the
   first to finish.

## Backup

1. Choose **Backup**.
2. **Select SOURCE disk** — the disk to back up. Check model, serial and size.
   Disks that are mounted, in use for swap, or the rescue USB itself are not
   offered.
3. **Select DESTINATION disk**, then the partition on it that will hold the
   backup. It must already have a filesystem. If the disk is blank, format it
   first. The tool mounts it for you.
4. The tool shows source and destination (model and size, plus the free space)
   and asks **"Back up … to this destination?"** Confirm.
5. Wait for **"Backup complete"**. The tool prints the job folder path.
   Anything else means the backup did not complete. Do not rely on it. Read the
   messages on screen.

**What you get:** a new folder on the destination named
`<model>_<serial>_<timestamp>`. It holds:

| File | What it is |
| --- | --- |
| `manifest.json` | Disk layout, sizes, per-partition checksums, and used-space figures |
| the partition table dump | GPT or DOS table |
| one compressed image per partition | used blocks only (or raw bytes for encrypted, LVM and unformatted partitions) |
| `backup_<timestamp>.log` | complete log of the run |
| `partclone_partN.log` | one per partition |

You can **rename the folder** to something meaningful (for example the
operating system and the date). The Restore and Verify lists show the folder
name, and nothing depends on the original name. Keep the folder intact. Copy it
as a whole.

## Verify a backup (do this before you rely on a backup)

Verify reads the backup back and checks it. It **writes nothing and erases
nothing.**

1. Choose **Verify a backup**.
2. Pick the disk that holds your backups, then the partition.
3. Choose **One backup** or **Every backup on this disk**.
4. Wait. It reads every byte and can take a while.
5. Each backup is reported **PASS** or **FAIL**. If any FAIL: do not rely on
   that backup, and take a fresh one.

Verify is the same check Restore runs before it erases anything, so a backup
that passes Verify will not be rejected at that stage. Passing Verify shows
that the stored image files are complete and match their checksums. It does
not show that the restored system will boot. Verification is the deep check by
default: checksums plus a full structural read of each image. It drops to
checksums only if `SR_DEEP_VERIFY=0` is set, which is faster and cannot tell a
whole image from a truncated one.

## Restore

**This erases the target disk completely.**

1. Choose **Restore**.
2. **Select the disk that HOLDS your backups**, then its partition.
3. **Select a backup to restore.** Entries are labelled with the folder name,
   so give folders clear names.
4. **Select TARGET disk to restore onto (THIS DISK WILL BE ERASED).**
5. The tool shows two blocks. Read both:
   - *Backup:* when it was taken, the source disk's model, serial and size,
     and a summary of what it holds.
   - *Target (WILL BE COMPLETELY ERASED):* the target's kernel name, model,
     **serial**, size and its current partitions.
   Compare the target's serial with your notes. If it is not the disk you
   mean, stop here and cancel.
6. Confirm at **"Everything on this disk will be destroyed."**
7. **Type the target disk's serial number** when asked. A mismatch cancels the
   restore, and nothing is written.
8. The tool then runs its checks and, only if they all pass, erases and writes:
   - re-verifies every image in the backup;
   - refuses a target that is mounted, that is the rescue USB, that is
     smaller than the source, or whose sector size differs;
   - re-reads the target's serial itself and compares it to what you typed.
   If any of these fail the tool says **"nothing was written"**.
9. It recreates the partition table, restores each partition, and recreates
   swap with its original UUID.
10. **After the restore**, the tool reads the restored filesystems and compares
    used bytes (and inode counts where the filesystem has them) with what was
    recorded at backup time. The log says how many partitions were checked and
    by which measure. **This is a consistency check on how much data is there.
    It does not compare file contents and does not prove the disk boots.**
11. The log is saved in the backup's job folder as
    `restore_<timestamp>.log`.

### Before you reboot after a restore

- **Restoring the machine's own system disk** (same disk that was backed up):
  there is no other copy, so there is nothing to clash with. Shut down, remove
  the rescue USB, and boot.
- **Restoring onto a different disk while the original is still in the same
  machine:** both disks now carry identical filesystem UUIDs. The system finds
  its filesystems by UUID, so it can boot the wrong copy, and may work one time
  and fail another. The tool prints an **"ACTION REQUIRED BEFORE YOU REBOOT"**
  notice. Do one of:
  - power off and physically disconnect the restored disk, or
  - disconnect the original disk and boot only the restored one.
  Do not try to work around this by erasing filesystem signatures on the real
  disks.
- Boot in UEFI mode from the restored disk's own EFI partition. If the machine
  boots from a different disk's EFI partition, check the firmware boot order.

### If something goes wrong

- **A backup verifies FAIL:** it is not usable. Restore from another copy. Take
  a fresh backup as soon as possible.
- **Restore reports a failure after it began writing:** the target is in an
  unknown state. Do not boot from it. Keep the backup and the restore log, fix
  the cause (usually a bad destination disk or cable), and run the restore
  again onto the same target.
- **The restore log flags a used-bytes or inode mismatch:** treat the restore
  as failed until you can show otherwise, for example by mounting the
  filesystem read-only and comparing files against known-good copies.
- **You need a root shell:** the text menu on tty2 relaunches itself when you
  leave it. Switch to the desktop (Ctrl+Alt+F1) and open a terminal.
- **The menu will not exit:** choose **Shut down** or **Reboot** from the menu.
  It flushes pending writes first. The screen goes blank when it is safe to
  remove the stick.

## Command-line checks (optional)

Available from a terminal in the rescue environment or from a clone of the
source repository:

```sh
bin/verify-backup.sh <job-dir>              # verify one backup
bin/verify-backup.sh --all <destination>    # verify every backup on a disk
```

Exit status 0 means every backup checked is sound, and 1 means at least one is
not. It needs no root and touches no block devices.

## Keep your backups safe

- One copy on one disk is not a backup plan. Keep a second copy of anything
  irreplaceable, on a different disk stored offline.
- Verify each backup after taking it, and again from time to time.
- The rescue USB itself is replaceable: keep the ISO and its checksum file
  with your backups.
