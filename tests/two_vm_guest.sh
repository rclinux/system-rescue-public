#!/usr/bin/env bash
# Only for disposable disks attached by two_vm_recovery.py.
set -euo pipefail
[[ $(cat /sys/class/dmi/id/product_name) == *Q35* || $(cat /sys/class/dmi/id/sys_vendor) == QEMU ]]
stage=$1
[[ $(lsblk -dno SERIAL /dev/vda) == "SR_REHEARSAL_${stage^^}" ]]
[[ $(lsblk -dno SERIAL /dev/vdb) == SR_REHEARSAL_VAULT ]]
mkdir -p /mnt/vault /mnt/system /mnt/top
if [[ $stage == setup ]]; then mkfs.ext4 -F -q /dev/vdb; fi
mount -t ext4 /dev/vdb /mnt/vault
if [[ $stage == setup ]]; then
    sgdisk --clear --new=1:2048:+512M --typecode=1:ef00 --new=2:0:0 --typecode=2:8300 /dev/vda
    partprobe /dev/vda; udevadm settle
    mkfs.fat -F32 /dev/vda1
    mkfs.btrfs -f /dev/vda2
    mount -t btrfs /dev/vda2 /mnt/top
    btrfs subvolume create /mnt/top/@
    btrfs subvolume create /mnt/top/@home
    mount -t btrfs -o subvol=@ /dev/vda2 /mnt/system
    unsquashfs -f -d /mnt/system /run/archiso/bootmnt/sysresccd/x86_64/airootfs.sfs
    mkdir -p /mnt/system/boot /mnt/system/home
    mount -t vfat /dev/vda1 /mnt/system/boot
    mount -t btrfs -o subvol=@home /dev/vda2 /mnt/system/home
    root_uuid=$(blkid -s UUID -o value /dev/vda2)
    efi_uuid=$(blkid -s UUID -o value /dev/vda1)
    printf 'UUID=%s / btrfs defaults,subvol=@ 0 0\nUUID=%s /home btrfs defaults,subvol=@home 0 0\nUUID=%s /boot vfat defaults 0 2\n' "$root_uuid" "$root_uuid" "$efi_uuid" > /mnt/system/etc/fstab
    echo sr-rehearsal > /mnt/system/etc/hostname
    # Drop live-media startup dependencies in this disposable installed fixture.
    find /mnt/system/etc/systemd/system -type l \( -name '*sysrescue*' -o -name '*choose-mirror*' -o -name '*pacman*' -o -name 'display-manager.service' \) -delete
    ln -sf /usr/lib/systemd/system/multi-user.target /mnt/system/etc/systemd/system/default.target
    mkdir -p /mnt/system/boot/EFI/BOOT /mnt/system/boot/loader/entries
    cp /mnt/system/usr/lib/systemd/boot/efi/systemd-bootx64.efi /mnt/system/boot/EFI/BOOT/BOOTX64.EFI
    cp /run/archiso/bootmnt/sysresccd/boot/x86_64/vmlinuz /mnt/system/boot/vmlinuz-linux
    printf 'default rehearsal.conf\ntimeout 0\n' > /mnt/system/boot/loader/loader.conf
    printf 'title System Rescue installed rehearsal\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=UUID=%s rootfstype=btrfs rootflags=subvol=@ rw console=ttyS0,115200\n' "$root_uuid" > /mnt/system/boot/loader/entries/rehearsal.conf
    cat > /mnt/system/etc/mkinitcpio-rehearsal.conf <<'CONFIG'
MODULES=(virtio_pci virtio_blk btrfs)
BINARIES=()
FILES=()
HOOKS=(base systemd modconf block filesystems)
COMPRESSION=zstd
CONFIG
    mount --rbind /dev /mnt/system/dev; mount --make-rslave /mnt/system/dev
    mount -t proc proc /mnt/system/proc
    mount --rbind /sys /mnt/system/sys; mount --make-rslave /mnt/system/sys
    chroot /mnt/system mkinitcpio -c /etc/mkinitcpio-rehearsal.conf -k "$(uname -r)" -g /boot/initramfs-linux.img
    umount -R /mnt/system/dev; umount /mnt/system/proc; umount -R /mnt/system/sys
    mkdir -p /mnt/system/home/rehearsal /mnt/system/etc/rehearsal
    printf 'Installed-system recovery fixture\n' > /mnt/system/etc/rehearsal/config
    head -c 8388608 /dev/urandom > /mnt/system/home/rehearsal/data.bin
    ln /mnt/system/home/rehearsal/data.bin /mnt/system/home/rehearsal/hardlink.bin
    ln -s data.bin /mnt/system/home/rehearsal/symlink.bin
    (cd /mnt/system && sha256sum etc/rehearsal/config home/rehearsal/data.bin boot/EFI/BOOT/BOOTX64.EFI boot/vmlinuz-linux boot/initramfs-linux.img) > /mnt/system/etc/rehearsal.sha256
    cp /mnt/system/etc/rehearsal.sha256 /mnt/vault/expected.sha256
    cat > /mnt/system/usr/local/bin/rehearsal-check <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
[[ -d /sys/firmware/efi ]]
[[ $(findmnt -n -o FSTYPE /) == btrfs ]]
[[ $(findmnt -n -o FSROOT /) == /@ ]]
[[ $(findmnt -n -o FSROOT /home) == /@home ]]
[[ $(lsblk -dn -o TYPE /dev/vda) == disk ]]
[[ $(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" {print $1}') == vda ]]
cd /
sha256sum -c /etc/rehearsal.sha256
[[ $(stat -c %i /home/rehearsal/data.bin) == "$(stat -c %i /home/rehearsal/hardlink.bin)" ]]
[[ $(readlink /home/rehearsal/symlink.bin) == data.bin ]]
findmnt /
findmnt /home
findmnt /boot
lsblk -o NAME,SERIAL,FSTYPE,UUID,MOUNTPOINTS
printf '\nSR_INSTALLED_BOOT_OK\n'
CHECK
    chmod 755 /mnt/system/usr/local/bin/rehearsal-check
    cat > /mnt/system/etc/systemd/system/rehearsal-check.service <<'UNIT'
[Unit]
Description=Verify installed recovery fixture
After=local-fs.target
RequiresMountsFor=/home /boot
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rehearsal-check
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
UNIT
    ln -s ../rehearsal-check.service /mnt/system/etc/systemd/system/multi-user.target.wants/rehearsal-check.service
    btrfs subvolume snapshot -r /mnt/top/@ /mnt/top/snapshot
    umount /mnt/system/home /mnt/system/boot /mnt/system
    umount /mnt/top
else
    for lib in common disk_detect partition_table backup_engine verify_engine restore_engine; do source "/usr/local/system_rescue/lib/$lib.sh"; done
    if [[ $stage == capture ]]; then
        sha256sum /dev/vda > /mnt/vault/source.before
        job=$(backup_disk /dev/vda /mnt/vault)
        verify_backup_job "$job"
        sha256sum -c /mnt/vault/source.before
        printf '%s\n' "$job" > /mnt/vault/job-path
        mount -t btrfs -o ro,rescue=nologreplay,subvolid=5 /dev/vda2 /mnt/top
        btrfs subvolume list -u -q /mnt/top | sed -E 's/ gen [0-9]+//' > /mnt/vault/subvolumes.before
        umount /mnt/top
    elif [[ $stage == restore ]]; then
        job=$(cat /mnt/vault/job-path)
        verify_backup_job "$job"
        restore_disk "$job" /dev/vda SR_REHEARSAL_RESTORE
        mount -t btrfs -o ro,rescue=nologreplay,subvolid=5 /dev/vda2 /mnt/top
        btrfs subvolume list -u -q /mnt/top | sed -E 's/ gen [0-9]+//' > /mnt/vault/subvolumes.after
        cmp /mnt/vault/subvolumes.before /mnt/vault/subvolumes.after
        [[ $(btrfs property get -ts /mnt/top/snapshot ro) == ro=true ]]
        umount /mnt/top
        mount -t btrfs -o ro,rescue=nologreplay,subvol=@ /dev/vda2 /mnt/system
        mount -t btrfs -o ro,rescue=nologreplay,subvol=@home /dev/vda2 /mnt/system/home
        mount -t vfat -o ro /dev/vda1 /mnt/system/boot
        (cd /mnt/system && sha256sum -c /mnt/vault/expected.sha256)
        umount /mnt/system/boot /mnt/system/home /mnt/system
    else exit 2; fi
fi
sync
umount /mnt/vault
printf '\nSR_STAGE_OK=%s\n' "$stage"
