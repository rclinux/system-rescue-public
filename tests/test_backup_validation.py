"""File-only fixtures and command stubs; never access real block devices."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def shell(code, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith('SR_')}
    return subprocess.run(['bash', '-c', code, 'test', str(ROOT), *map(str, args)],
                          env=env, capture_output=True, text=True)


class BackupValidation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.job = Path(self.temp.name)
        image = subprocess.run(['zstd', '-q', '-c'], input=b'x' * 2048,
                               capture_output=True, check=True).stdout
        (self.job / 'part1.img.zst').write_bytes(image)
        (self.job / 'partition_table.gpt').write_text('label: dos\nlabel-id: 0x12345678\nunit: sectors\nsector-size: 512\n/dev/FAKE1 : start=1, size=4, type=83\n')
        self.manifest = {
            'system_rescue_manifest_version': 4,
            'source_disk': {'size_bytes': 4096},
            'partition_table': {'type': 'dos', 'dump_file': 'partition_table.gpt'},
            'partitions': [{'number': 1, 'size_bytes': 2048, 'fstype': '',
                            'uuid': '', 'label': '', 'restore_method': 'rawdd',
                            'image_file': 'part1.img.zst',
                            'checksum_sha256': hashlib.sha256(image).hexdigest()}],
        }

    def verify(self):
        (self.job / 'manifest.json').write_text(json.dumps(self.manifest))
        return shell('source "$1/lib/common.sh"; source "$1/lib/verify_engine.sh"; '
                     'verify_backup_job "$2"', self.job)

    def test_valid_v3_and_v4_raw_images(self):
        for version in (3, 4):
            with self.subTest(version=version):
                self.manifest['system_rescue_manifest_version'] = version
                result = self.verify()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('zstd stream', result.stderr)

    def test_missing_and_empty_table(self):
        table = self.job / 'partition_table.gpt'
        table.unlink()
        self.assertNotEqual(self.verify().returncode, 0)
        table.touch()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing or empty', result.stderr)

    def test_invalid_manifest_fields(self):
        original = copy.deepcopy(self.manifest)
        mutations = [
            lambda m: m.update(partitions=[]),
            lambda m: m.update(partitions=None),
            lambda m: m.update(system_rescue_manifest_version=99),
            lambda m: m['source_disk'].update(size_bytes='4096'),
            lambda m: m['partitions'][0].update(number=-1),
            lambda m: m['partitions'][0].update(restore_method='unknown'),
            lambda m: m['partitions'][0].update(image_file='../outside'),
            lambda m: m['partitions'][0].update(checksum_sha256=''),
            lambda m: m['partitions'].append(copy.deepcopy(m['partitions'][0])),
            lambda m: m['partitions'][0].update(fs_inodes_used='invalid'),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(case=index):
                self.manifest = copy.deepcopy(original)
                mutate(self.manifest)
                result = self.verify()
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn('invalid or incomplete', result.stderr)

    def test_missing_image(self):
        (self.job / 'part1.img.zst').unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_multiple_json_documents_rejected(self):
        path = self.job / 'manifest.json'
        path.write_text(json.dumps(self.manifest) + '\n' + json.dumps(self.manifest))
        result = shell('source "$1/lib/common.sh"; source "$1/lib/verify_engine.sh"; '
                       'verify_backup_job "$2"', self.job)
        self.assertNotEqual(result.returncode, 0)

    def test_swap_metadata_allowed_alongside_image(self):
        self.manifest['partitions'].append({
            'number': 2, 'size_bytes': 1024, 'fstype': 'swap',
            'uuid': 'preserved-swap-uuid', 'label': '', 'restore_method': 'mkswap',
            'image_file': '', 'checksum_sha256': '',
        })
        with (self.job / 'partition_table.gpt').open('a') as stream:
            stream.write('/dev/FAKE2 : start=5, size=2, type=82\n')
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.manifest['partitions'][1]['uuid'] = ''
        self.assertNotEqual(self.verify().returncode, 0)

    def test_changed_image(self):
        (self.job / 'part1.img.zst').write_bytes(b'corrupt')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)

    def test_truncated_image_with_matching_hash(self):
        path = self.job / 'part1.img.zst'
        path.write_bytes(path.read_bytes()[:-2])
        self.manifest['partitions'][0]['checksum_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('zstd integrity', result.stderr)

        # The standalone CLI must preserve deep checking too, including
        # when partclone.chkimg is unavailable on the development host.
        result = shell('bash "$1/bin/verify-backup.sh" "$2"', self.job)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn('zstd integrity', result.stderr)

    def test_failed_partclone_checker_is_not_a_pass(self):
        self.manifest['partitions'][0]['restore_method'] = 'partclone'
        (self.job / 'manifest.json').write_text(json.dumps(self.manifest))
        result = shell('source "$1/lib/common.sh"; source "$1/lib/verify_engine.sh"; '
                       'partclone.chkimg() { cat >/dev/null; return 1; }; '
                       'verify_backup_job "$2"', self.job)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('partclone integrity', result.stderr)

    def test_restore_rejects_bad_metadata_before_disk_checks_even_if_skip_verify(self):
        (self.job / 'manifest.json').write_text('{}')
        result = shell('source "$1/lib/common.sh"; source "$1/lib/verify_engine.sh"; '
                       'source "$1/lib/restore_engine.sh"; SR_SKIP_VERIFY=1; '
                       'lsblk() { echo UNEXPECTED_DISK_ACCESS >&2; return 99; }; '
                       'validate_restore "$2" /dev/FAKE confirmation', self.job)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid or incomplete', result.stderr)
        self.assertNotIn('UNEXPECTED_DISK_ACCESS', result.stderr)

    def test_probe_mount_options(self):
        for fs, options in [('btrfs', 'ro,rescue=nologreplay'), ('ext4', 'ro,noload')]:
            with self.subTest(fs=fs):
                result = shell('source "$1/lib/common.sh"; '
                               'findmnt() { return 1; }; '
                               'mount() { printf "%s\\n" "$*"; }; '
                               'umount() { return 0; }; '
                               '_df_pair() { printf "123\\03712\\n"; }; '
                               '_probe_fs_stats /dev/FAKE "$2"', fs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(options, result.stdout)

    def test_mbr_dump_failure_in_conditional_context(self):
        result = shell('source "$1/lib/common.sh"; source "$1/lib/partition_table.sh"; '
                       'pttype_of() { echo dos; }; sfdisk() { return 1; }; '
                       'if dump_partition_table /dev/FAKE "$2"; then exit 0; else exit 1; fi', self.job)
        self.assertNotEqual(result.returncode, 0)


class BackupFlow(unittest.TestCase):
    STUBS = r'''
source "$1/lib/common.sh"
source "$1/lib/disk_detect.sh"
source "$1/lib/backup_engine.sh"
require_root() { :; }
validate_source_disk() { :; }
SR_SKIP_SPACE_CHECK=1
lsblk() {
    case "$1" in
        -Pdno) echo 'NAME="FAKE" SIZE="4K" MODEL="Test" SERIAL="TEST"' ;;
        -bdno) echo 4096 ;;
        -Pbno)
            [[ "${FAIL_STAGE:-}" == enumeration ]] && return 1
            [[ "${FAIL_STAGE:-}" == empty ]] && return 0
            echo 'PARTN="1" NAME="FAKE1" FSTYPE="" SIZE="2048" UUID="" PARTUUID="" LABEL="" TYPE="part"' ;;
        -dno) echo 2K ;;
        *) return 99 ;;
    esac
}
dump_partition_table() {
    [[ "${FAIL_STAGE:-}" == table ]] && return 1
    printf 'label: dos\nlabel-id: 0x12345678\nunit: sectors\nsector-size: 512\n/dev/FAKE1 : start=1, size=4, type=83\n' > "$2/partition_table.gpt"
    printf 'dos\tpartition_table.gpt\n'
}
backup_partition() {
    [[ "${FAIL_STAGE:-}" == image ]] && return 1
    head -c 2048 /dev/zero | zstd -q -o "$4"
}
sha256sum() {
    [[ "${FAIL_STAGE:-}" == hash ]] && return 1
    command sha256sum "$@"
}
jq() {
    [[ "${FAIL_STAGE:-}" == manifest && "$1" == -n ]] && return 1
    command jq "$@"
}
'''

    def test_backup_failures_never_publish_manifest_or_report_success(self):
        for stage in ('table', 'enumeration', 'empty', 'image', 'hash', 'manifest'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                result = shell(self.STUBS + '\nFAIL_STAGE="$3"\n'
                               'if backup_disk /dev/FAKE "$2"; then exit 0; else exit 1; fi',
                               directory, stage)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('backup complete', result.stderr)
                self.assertEqual(list(Path(directory).rglob('manifest.json')), [])

    def test_successful_simulated_backup_verifies(self):
        with tempfile.TemporaryDirectory() as directory:
            result = shell(self.STUBS + '\n'
                           'if job=$(backup_disk /dev/FAKE "$2"); then '
                           'source "$1/lib/verify_engine.sh"; verify_backup_job "$job"; '
                           'else exit 1; fi', directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list(Path(directory).rglob('manifest.json'))), 1)


if __name__ == '__main__':
    unittest.main()
