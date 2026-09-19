"""Recover the ISO-sized prefix from the verified full USB archive, read-only.

If baseline/<archive> isn't on this machine, prepare() falls back to
baseline/last-known-good.iso — a verified prior candidate ISO kept as a
standing build input (see docs/build-inputs.md), also mirrored onto
project_backups/system-rescue_build_inputs/ on the offline backup drive.
This is how a plain `bin/build-iso.sh <name>.iso` keeps working on a
machine that never had (or has lost) the original baseline archive,
without needing a physical rescue USB reattached each time.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


class BaselineMissing(FileNotFoundError):
    pass


def _last_known_good():
    iso = ROOT / 'baseline/last-known-good.iso'
    sidecar = ROOT / 'baseline/last-known-good.iso.sha256'
    if not (iso.is_file() and sidecar.is_file()):
        return None
    expected = sidecar.read_text().split()[0]
    with iso.open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual != expected:
        raise RuntimeError(f'{iso} does not match {sidecar} — re-copy it from '
                            'project_backups/system-rescue_build_inputs/ on the offline backup drive')
    return iso


def prepare():
    metadata = json.loads((ROOT / 'docs/preservation.json').read_text())
    directory = ROOT / 'packaging/build'
    directory.mkdir(parents=True, exist_ok=True)
    output = directory / 'recovered-base.iso'
    receipt = directory / 'recovered-base.json'
    if output.exists():
        expected = json.loads(receipt.read_text())
        with output.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if actual != expected['sha256']:
            raise RuntimeError('Recovered base checksum mismatch')
        return output
    archive = ROOT / 'baseline' / metadata['archive']
    if not archive.exists():
        fallback = _last_known_good()
        if fallback is not None:
            return fallback
        raise BaselineMissing(
            f'{archive} is not on this machine, and baseline/last-known-good.iso is '
            'also missing. See docs/build-inputs.md: recover either the original '
            'baseline archive or baseline/last-known-good.iso from '
            'project_backups/system-rescue_build_inputs/ on the offline backup drive, '
            'or pass an existing candidate ISO with build_iso.py --base-iso=PATH.')
    temporary = output.with_suffix('.partial')
    digest = hashlib.sha256()
    count = 0
    with subprocess.Popen(['zstd', '-dc', str(archive)], stdout=subprocess.PIPE) as process:
        header = process.stdout.read(65536)
        pvd = header[32768:34816]
        if pvd[:7] != b'\x01CD001\x01':
            raise RuntimeError('Missing ISO primary volume descriptor')
        blocks = struct.unpack_from('<I', pvd, 80)[0]
        block_size = struct.unpack_from('<H', pvd, 128)[0]
        if block_size != 2048:
            raise RuntimeError('Unexpected ISO logical block size')
        length = blocks * block_size
        # Retain any hybrid boot partition extending beyond the ISO volume.
        for index in range(4):
            entry = 446 + index * 16
            start, sectors = struct.unpack_from('<II', header, entry + 8)
            if sectors:
                length = max(length, (start + sectors) * 512)
        if not 65536 <= length <= metadata['raw_bytes']:
            raise RuntimeError('Invalid ISO/partition extent')
        with temporary.open('xb') as target:
            chunk = header
            while chunk:
                digest.update(chunk)
                if count < length:
                    target.write(chunk[:length - count])
                count += len(chunk)
                chunk = process.stdout.read(4 * 1024 * 1024)
        if process.wait() != 0:
            raise RuntimeError('Archive decompression failed')
    if count != metadata['raw_bytes'] or digest.hexdigest() != metadata['raw_sha256']:
        raise RuntimeError('Archive differs from preserved source stream')
    temporary.rename(output)
    with output.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    receipt.write_text(json.dumps({'bytes': length, 'sha256': checksum,
                                  'origin': 'Preserved custom USB, not an upstream official ISO'}, indent=2) + '\n')
    return output


if __name__ == '__main__':
    print(prepare())
