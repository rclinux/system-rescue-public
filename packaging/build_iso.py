"""Build a candidate into dist/ using disposable staging; never access devices."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from prepare_base import ROOT, prepare


def build(name, base_iso=None):
    if Path(name).name != name or not name.endswith('.iso'):
        raise ValueError('Supply an ISO filename, without directory components')
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    output = dist / name
    if output.exists() or output.is_symlink():
        raise FileExistsError(f'Refusing to overwrite {output}')
    for tool in ('xorriso', 'mksquashfs', 'unsquashfs', 'rsync', 'zstd'):
        if not shutil.which(tool):
            raise RuntimeError(f'Missing build tool: {tool}')
    # --base-iso lets sysrescue-customize layer this candidate onto any prior
    # SystemRescue-format ISO (e.g. the last verified candidate) instead of
    # the pristine baseline archive — see docs/build-inputs.md. prepare()
    # already falls back to baseline/last-known-good.iso on its own, so this
    # is only needed to point at something else specifically.
    if base_iso is not None:
        base = Path(base_iso)
        if not base.is_file():
            raise FileNotFoundError(f'--base-iso not found: {base}')
    else:
        base = prepare()
    with tempfile.TemporaryDirectory(prefix='iso-', dir=ROOT / 'packaging/build') as work:
        work = Path(work)
        recipe = work / 'recipe'
        shutil.copytree(ROOT / 'packaging/recipe/iso_add', recipe / 'iso_add')
        payload = recipe / 'build_into_srm'
        shutil.copytree(ROOT / 'packaging/recipe/srm_overlay', payload)
        for directory in ('bin', 'lib', 'vendor'):
            shutil.copytree(ROOT / directory, payload / 'usr/local/system_rescue' / directory,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        (payload / '.squashfs-options').write_text('-all-root -processors 2\n')
        candidate = work / name
        subprocess.run([str(ROOT / 'packaging/tools/sysrescue-customize'), '--auto',
                        f'--source={base}', f'--dest={candidate}', f'--recipe-dir={recipe}'],
                       cwd=work, check=True)
        subprocess.run(['bash', str(ROOT / 'bin/verify-iso.sh'), str(candidate)], check=True)
        # A hard link publishes without overwriting an existing release name.
        os.link(candidate, output)
    with output.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    output.with_suffix('.iso.sha256').write_text(f'{checksum}  {name}\n')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True))
    with base.open('rb') as stream:
        base_sha256 = hashlib.file_digest(stream, 'sha256').hexdigest()
    output.with_suffix('.iso.json').write_text(json.dumps({
        'file': name, 'bytes': output.stat().st_size, 'sha256': checksum,
        'source_revision': revision, 'source_dirty': dirty,
        'base': {'from_iso': str(base), 'sha256': base_sha256},
        'status': 'candidate; payload verified; hardware recovery not yet verified',
    }, indent=2) + '\n')
    print(f'Candidate: {output}\nSHA-256: {checksum}')


if __name__ == '__main__':
    argv = sys.argv[1:]
    base_iso = None
    positional = []
    for arg in argv:
        if arg.startswith('--base-iso='):
            base_iso = arg.split('=', 1)[1]
        else:
            positional.append(arg)
    if len(positional) != 1:
        raise SystemExit('Usage: bin/build-iso.sh [--base-iso=PATH] <candidate-name.iso>')
    build(positional[0], base_iso=base_iso)
