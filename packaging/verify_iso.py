"""Extract and compare the entire custom payload and launch configuration."""
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def inventory(directory, ignore_cache=False):
    return {str(p.relative_to(directory)): p for p in directory.rglob('*') if p.is_file()
            and not (ignore_cache and ('__pycache__' in p.parts or p.suffix == '.pyc'))}


def verify(iso):
    iso = Path(iso).resolve()
    if not iso.is_file():
        raise ValueError('ISO must be a regular file')
    with tempfile.TemporaryDirectory(prefix='verify-iso-') as work:
        work = Path(work)
        subprocess.run(['xorriso', '-osirrox', 'on', '-indev', str(iso),
                        '-extract', '/sysresccd/customize.srm', str(work / 'customize.srm'),
                        '-extract', '/sysrescue.d', str(work / 'sysrescue.d')], check=True)
        subprocess.run(['unsquashfs', '-no-xattrs', '-d', str(work / 'root'),
                        str(work / 'customize.srm')], check=True, stdout=subprocess.DEVNULL, umask=0)
        expected = inventory(ROOT / 'packaging/recipe/srm_overlay')
        for directory in ('bin', 'lib', 'vendor'):
            for relative, path in inventory(ROOT / directory, ignore_cache=True).items():
                expected[f'usr/local/system_rescue/{directory}/{relative}'] = path
        actual = inventory(work / 'root')
        if expected.keys() != actual.keys():
            raise RuntimeError(f'Payload file set differs: {expected.keys() ^ actual.keys()}')
        for relative, source in expected.items():
            target = actual[relative]
            if source.read_bytes() != target.read_bytes():
                raise RuntimeError(f'Payload differs: {relative}')
            if stat.S_IMODE(source.stat().st_mode) != stat.S_IMODE(target.stat().st_mode):
                raise RuntimeError(f'Permissions differ: {relative}')
        for relative, source in inventory(ROOT / 'packaging/recipe/iso_add/sysrescue.d').items():
            if source.read_bytes() != (work / 'sysrescue.d' / relative).read_bytes():
                raise RuntimeError(f'Launch configuration differs: {relative}')
        if (work / 'sysrescue.d/200-customize.yaml').read_text() != '---\nglobal:\n    loadsrm: true\n':
            raise RuntimeError('Custom module is not enabled as expected')
        listing = subprocess.check_output(['unsquashfs', '-ll', str(work / 'customize.srm')], text=True)
        entries = [line for line in listing.splitlines() if line.startswith(('-', 'd', 'l'))]
        if not entries or any(line.split()[1] != 'root/root' for line in entries):
            raise RuntimeError('Custom module contains unexpected ownership')
        print(f'PASS: {len(actual)} payload files, permissions, root ownership, launcher YAML and module activation')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: bin/verify-iso.sh <candidate.iso>')
    verify(sys.argv[1])
