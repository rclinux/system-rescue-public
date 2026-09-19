"""Source safety tests use command stubs, with no device reads or writes."""
import unittest
from test_backup_validation import shell
import test_backup_validation


class SourceSafety(unittest.TestCase):
    def test_btrfs_subvolume_and_swap_ancestors(self):
        result = shell(r'''
source "$1/lib/disk_detect.sh"
_mounted_btrfs_disks() { :; }
findmnt() { printf '/dev/mapper/root[/@]\n'; }
swapon() { printf '/dev/sdb2\n'; }
lsblk() {
 case "${@: -1}" in
 /dev/mapper/root) printf 'dm-0 crypt\nsda2 part\nsda disk\n';;
 /dev/sdb2) printf 'sdb2 part\nsdb disk\n';;
 *) return 99;; esac
}
busy_disks
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ['sda', 'sdb'])

    def test_discovery_failures_close_candidate_list(self):
        for failing in ('findmnt', 'swapon', 'lsblk'):
            result = shell(r'''
source "$1/lib/disk_detect.sh"
_mounted_btrfs_disks() { :; }
findmnt() { [[ "$2" != unused ]]; }
swapon() { :; }
lsblk() { return 1; }
''' + f'\n{failing}() {{ return 1; }}\nlist_candidate_disks')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')

    def test_btrfs_budget_does_not_use_statvfs(self):
        result = shell(r'''
source "$1/lib/backup_engine.sh"
_probe_fs_stats() { printf '1\0371\n'; }
_partition_used_bytes /dev/FAKE btrfs 1073741824
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '1073741824')

    def test_engine_rejects_source_before_destination_or_imaging(self):
        result = shell(r'''
source "$1/lib/common.sh"
source "$1/lib/backup_engine.sh"
require_root() { :; }
validate_source_disk() { log_error 'ineligible source'; return 1; }
lsblk() { echo UNEXPECTED >&2; }
backup_disk /dev/FAKE /not-a-directory
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ineligible source', result.stderr)
        self.assertNotIn('UNEXPECTED', result.stderr)


class RawSize(unittest.TestCase):
    setUp = test_backup_validation.BackupValidation.setUp
    verify = test_backup_validation.BackupValidation.verify
    def test_valid_compression_with_wrong_raw_length(self):
        import hashlib
        import subprocess
        data = subprocess.run(['zstd', '-q', '-c'], input=b'short but valid', capture_output=True, check=True).stdout
        (self.job / 'part1.img.zst').write_bytes(data)
        self.manifest['partitions'][0]['checksum_sha256'] = hashlib.sha256(data).hexdigest()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('raw size differs', result.stderr)
