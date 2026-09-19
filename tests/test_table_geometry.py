"""Generate independent GPT tables with util-linux on regular sparse files."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import sys
sys.dont_write_bytecode = True
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('validate_table', ROOT / 'lib/validate_table.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class TableGeometry(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        disk = self.root / 'disk.raw'
        with disk.open('wb') as f:
            f.truncate(32 * 1024 * 1024)
        subprocess.run(['sfdisk', str(disk)], input='label: gpt\nstart=2048,size=8192,type=L\n',
                       text=True, check=True, capture_output=True)
        with disk.open('rb') as f:
            mbr = f.read(512); primary = f.read(512)
            location = struct.unpack_from('<Q', primary, 32)[0]
            f.seek(location * 512); secondary = f.read(512)
            f.seek(1024); entries = f.read(128 * 128)
        self.data = mbr + primary + secondary + entries
        import uuid
        self.manifest = {'source_disk': {'size_bytes': disk.stat().st_size},
                         'partition_table': {'type': 'gpt', 'dump_file': 'table.gpt'},
                         'partitions': [{'number': 1, 'size_bytes': 8192 * 512,
                                         'partuuid': str(uuid.UUID(bytes_le=entries[16:32]))}]}

    def validate(self, data=None, manifest=None):
        (self.root / 'table.gpt').write_bytes(self.data if data is None else data)
        p = self.root / 'manifest.json'; p.write_text(json.dumps(manifest or self.manifest))
        return module.validate(p)

    def test_real_gpt_table(self):
        self.assertEqual(self.validate(), 512)

    def test_corrupt_and_truncated_gpt(self):
        for offset in (510, 512, 530, 1040, 1552):
            with self.subTest(offset=offset):
                bad = bytearray(self.data); bad[offset] ^= 1
                with self.assertRaises(ValueError): self.validate(bytes(bad))
        with self.assertRaises(ValueError): self.validate(self.data[:-1])

    def test_manifest_mismatch(self):
        for field, value in [('number', 2), ('size_bytes', 1024), ('partuuid', 'wrong')]:
            manifest = copy.deepcopy(self.manifest); manifest['partitions'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate(manifest=manifest)
        manifest = copy.deepcopy(self.manifest); manifest['source_disk']['size_bytes'] += 512
        with self.assertRaises(ValueError): self.validate(manifest=manifest)

    def test_dos_rejects_overlap_and_extended(self):
        for record in ['/dev/sda2 : start=2, size=4, type=83', '/dev/sda2 : start=5, size=2, type=5']:
            with self.subTest(record=record):
                manifest = {'source_disk': {'size_bytes': 4096},
                            'partition_table': {'type': 'dos', 'dump_file': 'table.gpt'},
                            'partitions': [{'number': 1, 'size_bytes': 2048}, {'number': 2, 'size_bytes': 2048}]}
                data = ('label: dos\nlabel-id: 0x12345678\nunit: sectors\n/dev/sda1 : start=1, size=4, type=83\n' + record).encode()
                with self.assertRaises(ValueError): self.validate(data, manifest)


if __name__ == '__main__': unittest.main()
