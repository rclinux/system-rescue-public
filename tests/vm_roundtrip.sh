#!/usr/bin/env bash
# Runs only inside tests/run_vm.py's disposable QEMU guest.
set -euo pipefail
[[ $(cat /sys/class/dmi/id/product_name) == *Q35* || $(cat /sys/class/dmi/id/sys_vendor) == QEMU ]]
for pair in 'vda SOURCE' 'vdb TARGET' 'vdc VAULT'; do
    read -r dev identity <<< "$pair"
    [[ $(lsblk -dno SERIAL "/dev/$dev") == "SR_TEST_$identity" ]]
done
source "${SR_APP_ROOT:-/mnt/project}"/lib/common.sh
source "${SR_APP_ROOT:-/mnt/project}"/lib/disk_detect.sh
source "${SR_APP_ROOT:-/mnt/project}"/lib/partition_table.sh
source "${SR_APP_ROOT:-/mnt/project}"/lib/backup_engine.sh
source "${SR_APP_ROOT:-/mnt/project}"/lib/verify_engine.sh
source "${SR_APP_ROOT:-/mnt/project}"/lib/restore_engine.sh
mkdir -p /mnt/vault /mnt/fixture /mnt/efi
mkfs.ext4 -q /dev/vdc
mount -t ext4 /dev/vdc /mnt/vault
sgdisk --clear --new=1:2048:+128M --typecode=1:ef00 --new=2:0:+1G --typecode=2:8300 --new=3:0:+64M --typecode=3:8200 --new=4:0:+16M --typecode=4:8300 /dev/vda
partprobe /dev/vda
udevadm settle
mkfs.fat -F32 /dev/vda1
mkfs.btrfs -f /dev/vda2
mkswap -U 11111111-2222-3333-4444-555555555555 /dev/vda3
head -c 1048576 /dev/urandom > /mnt/vault/raw.expected
dd if=/mnt/vault/raw.expected of=/dev/vda4 bs=1M conv=fsync
mount -t vfat /dev/vda1 /mnt/efi
mkdir -p /mnt/efi/EFI/BOOT
printf 'EFI content fixture; not a bootloader\n' > /mnt/efi/EFI/BOOT/fixture.txt
(cd /mnt/efi && sha256sum EFI/BOOT/fixture.txt) > /mnt/vault/efi.sha256
umount /mnt/efi
mount -t btrfs /dev/vda2 /mnt/fixture
btrfs subvolume create /mnt/fixture/@
btrfs subvolume create /mnt/fixture/@home
mkdir -p /mnt/fixture/@/etc
printf 'restore fixture\n' > /mnt/fixture/@/etc/fixture
head -c 8388608 /dev/urandom > /mnt/fixture/@home/random.bin
ln /mnt/fixture/@/etc/fixture /mnt/fixture/@/etc/hardlink
ln -s fixture /mnt/fixture/@/etc/symlink
btrfs subvolume snapshot -r /mnt/fixture/@ /mnt/fixture/snapshot
btrfs subvolume create /mnt/fixture/@swap
btrfs filesystem mkswapfile --size 128M /mnt/fixture/@swap/swapfile
(cd /mnt/fixture && find . -type f ! -path './@swap/*' -print0 | sort -z | xargs -0 sha256sum) > /mnt/vault/btrfs.sha256
btrfs subvolume list -u -q /mnt/fixture | sed -E 's/ gen [0-9]+//' > /mnt/vault/subvolumes.before
if validate_source_disk /dev/vda; then echo 'FAIL mounted source accepted'; exit 1; fi
umount /mnt/fixture
swapon /dev/vda3
if validate_source_disk /dev/vda; then echo 'FAIL active swap source accepted'; exit 1; fi
swapoff /dev/vda3
udevadm trigger --subsystem-match=block
udevadm settle
sha256sum /dev/vda > /mnt/vault/source.before
mkdir -p /mnt/vault/interrupted
(
    backup_partition() {
        (set -o pipefail
         timeout --signal=TERM 0.1 "$3" -c -q -L "$5" -s "$1" -o - | zstd -q -o "$4")
    }
    if backup_disk /dev/vda /mnt/vault/interrupted; then
        echo 'FAIL interrupted capture reported success'; exit 1
    fi
    [[ -z $(find /mnt/vault/interrupted -name manifest.json -print) ]]
)
echo 'PASS: terminated Partclone capture did not publish a manifest'
job=$(backup_disk /dev/vda /mnt/vault)
verify_backup_job "$job"
sha256sum -c /mnt/vault/source.before
# Corruption must fail before any target change.
cp "$job/part4.img.zst" /mnt/vault/raw.good
printf 'broken' > "$job/part4.img.zst"
before=$(sha256sum /dev/vdb)
if restore_disk "$job" /dev/vdb SR_TEST_TARGET; then echo 'FAIL corrupt restore accepted'; exit 1; fi
[[ "$before" == "$(sha256sum /dev/vdb)" ]]
cp /mnt/vault/raw.good "$job/part4.img.zst"
# Duplicate Btrfs UUIDs must be isolated before mounting the restored copy.
restore_disk "$job" /dev/vdb SR_TEST_TARGET
# virtio disks cannot always be unplugged via sysfs; remove its Btrfs signature
# only in this disposable guest after proving source preservation above.
if [[ -b /dev/vda2 ]]; then wipefs -a /dev/vda2; btrfs device scan --forget /dev/vda2 || true; fi
mount -t btrfs -o ro,rescue=nologreplay,subvolid=5 /dev/vdb2 /mnt/fixture
(cd /mnt/fixture && sha256sum -c /mnt/vault/btrfs.sha256)
[[ $(stat -c %i /mnt/fixture/@/etc/fixture) == "$(stat -c %i /mnt/fixture/@/etc/hardlink)" ]]
[[ $(readlink /mnt/fixture/@/etc/symlink) == fixture ]]
[[ $(stat -c %s /mnt/fixture/@swap/swapfile) == 134217728 ]]
btrfs inspect-internal map-swapfile /mnt/fixture/@swap/swapfile
btrfs subvolume list -u -q /mnt/fixture | sed -E 's/ gen [0-9]+//' > /mnt/vault/subvolumes.after
cmp /mnt/vault/subvolumes.before /mnt/vault/subvolumes.after
[[ $(btrfs property get -ts /mnt/fixture/snapshot ro) == ro=true ]]
umount /mnt/fixture
mount -t vfat -o ro /dev/vdb1 /mnt/efi
(cd /mnt/efi && sha256sum -c /mnt/vault/efi.sha256)
umount /mnt/efi
[[ $(blkid -p -s UUID -o value /dev/vdb3) == 11111111-2222-3333-4444-555555555555 ]]
cmp -n 1048576 /mnt/vault/raw.expected /dev/vdb4
echo 'PASS: GPT EFI/Btrfs/subvolumes/snapshot/swapfile/swap/raw roundtrip, source preservation, busy-source and corrupt-image rejection'
sync

# Separate DOS/ext4 primary-partition round trip on the same disposable disks.
sgdisk --zap-all /dev/vda
sgdisk --zap-all /dev/vdb
wipefs -a /dev/vda /dev/vdb
printf 'label: dos\nstart=2048,size=524288,type=83,bootable\n' | sfdisk /dev/vda
partprobe /dev/vda; partprobe /dev/vdb; udevadm settle
mkfs.ext4 -F -q /dev/vda1
mount -t ext4 /dev/vda1 /mnt/fixture
printf 'DOS ext4 content fixture\n' > /mnt/fixture/fixture
(cd /mnt/fixture && sha256sum fixture) > /mnt/vault/ext4.sha256
umount /mnt/fixture
udevadm trigger --subsystem-match=block; udevadm settle
job=$(backup_disk /dev/vda /mnt/vault)
verify_backup_job "$job"
restore_disk "$job" /dev/vdb SR_TEST_TARGET
mount -t ext4 -o ro,noload /dev/vdb1 /mnt/fixture
(cd /mnt/fixture && sha256sum -c /mnt/vault/ext4.sha256)
umount /mnt/fixture
echo 'PASS: DOS primary table/ext4 roundtrip (file contents, not BIOS boot)'
sync
