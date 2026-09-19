"""Read-only verification of the preserved original; no device access.

Run from any directory: python3 tests/verify_preservation.py
Requires zstd. Reads the entire decompressed full-device archive.
"""

import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "baseline"


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    metadata = json.loads((BASELINE / "preservation.json").read_text())
    entries = json.loads((BASELINE / "usb-files.sha256.json").read_text())
    for entry in entries:
        path = BASELINE / "usb-files" / entry["path"]
        if path.stat().st_size != entry["bytes"] or sha256_file(path) != entry["sha256"]:
            raise SystemExit(f"FAIL: copied USB file: {entry['path']}")
    print(f"PASS: {len(entries)} preserved USB files", flush=True)

    archive = BASELINE / metadata["archive"]
    if sha256_file(archive) != metadata["archive_sha256"]:
        raise SystemExit("FAIL: compressed archive checksum")
    digest = hashlib.sha256()
    count = 0
    with subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE) as process:
        for chunk in iter(lambda: process.stdout.read(4 * 1024 * 1024), b""):
            count += len(chunk)
            digest.update(chunk)
        if process.wait() != 0:
            raise SystemExit("FAIL: zstd decompression")
    if count != metadata["raw_bytes"] or digest.hexdigest() != metadata["raw_sha256"]:
        raise SystemExit("FAIL: decompressed image differs from captured USB stream")
    print(f"PASS: full-device archive reproduces all {count:,} captured bytes")


if __name__ == "__main__":
    main()
