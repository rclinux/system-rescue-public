"""Regression tests for failures found in the recovered USB version; no block devices are accessed.

Run with: python3 -m unittest discover -s tests -v
"""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RecoveredRegressions(unittest.TestCase):
    def test_empty_backup_must_not_verify(self):
        with tempfile.TemporaryDirectory() as directory:
            job = Path(directory)
            (job / "manifest.json").write_text(json.dumps({
                "system_rescue_manifest_version": 4,
                "partition_table": {
                    "type": "gpt", "dump_file": "partition_table.gpt"
                },
                "partitions": [],
            }))
            (job / "partition_table.gpt").touch()
            result = subprocess.run([
                "bash", "-c",
                'source "$1/lib/common.sh"; '
                'source "$1/lib/verify_engine.sh"; '
                'verify_backup_job "$2"',
                "test", str(ROOT), directory,
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_failed_gpt_save_must_propagate_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([
                "bash", "-c",
                'source "$1/lib/common.sh"; '
                'source "$1/lib/partition_table.sh"; '
                'pttype_of() { echo gpt; }; '
                'sgdisk() { return 1; }; '
                'dump_partition_table /dev/FAKE_NOT_ACCESSED "$2"',
                "test", str(ROOT), directory,
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
