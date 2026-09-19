"""Add a signed-package NVIDIA SRM to candidate 2 without changing its base.

All builds and extraction occur in packaging/build; no host installation or
device access. See docs/nvidia-image.md for the pinned offline inputs.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from verify_iso import verify

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'packaging/build/nvidia'
KERNEL = '6.18.41-1-lts'
DRIVER = '610.57.04'
PACKAGES = [f'nvidia-utils-{DRIVER}-1', 'egl-gbm-1.1.3-1',
            'egl-wayland-4:1.1.21-1', 'egl-wayland2-1.0.1-1', 'egl-x11-1.0.5-1']
BASE_HASH = 'ac9a63432b290eee910f3160bd17f7e185d19694820b7a2c62586b4a20b77cff'
FLAGS = 'module_blacklist=nouveau,nova_core,nova_drm modprobe.blacklist=nouveau,nova_core,nova_drm nvidia_drm.modeset=1'


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def build(name):
    if Path(name).name != name or not name.endswith('.iso'):
        raise ValueError('Expected a new ISO filename')
    output = ROOT / 'dist' / name
    if output.exists() or output.is_symlink():
        raise FileExistsError(output)
    base = ROOT / 'dist/system-rescue-0.1.0-candidate2.iso'
    if sha(base) != BASE_HASH:
        raise RuntimeError('Candidate 2 checksum differs')
    verify(base)
    inputs = {}
    packages = {}
    for spec in PACKAGES + [f'nvidia-open-dkms-{DRIVER}-1', 'linux-lts-headers-6.18.41-1']:
        filename = spec + '-x86_64.pkg.tar.zst'
        package = WORK / filename
        if not package.exists():
            shutil.copyfile(Path('/var/cache/pacman/pkg') / filename, package)
        run('gpg', '--homedir', WORK / 'gnupg', '--batch', '--no-autostart',
            '--verify', str(package) + '.sig', package)
        inputs[filename] = sha(package)
        packages[spec] = package

    # Fresh trees prevent stale files being silently included in a new build.
    import tempfile
    stage = Path(tempfile.mkdtemp(prefix='assemble-', dir=WORK))
    overlay = stage / 'overlay'
    overlay.mkdir()
    for spec in PACKAGES:
        run('tar', '-xf', packages[spec], '-C', overlay, 'usr')
    headers = stage / 'headers'; headers.mkdir()
    source = stage / 'source'; source.mkdir()
    run('tar', '-xf', packages['linux-lts-headers-6.18.41-1'], '-C', headers)
    run('tar', '-xf', packages[f'nvidia-open-dkms-{DRIVER}-1'], '-C', source)
    kernel_headers = headers / f'usr/lib/modules/{KERNEL}/build'
    source = source / f'usr/src/nvidia-{DRIVER}'
    with (stage / 'compile.log').open('w') as log:
        run('make', '-C', source, '-j8', f'KERNEL_UNAME={KERNEL}',
            f'SYSSRC={kernel_headers}', 'modules', stdout=log, stderr=subprocess.STDOUT)
    modules = overlay / f'usr/lib/modules/{KERNEL}/extramodules'
    modules.mkdir(parents=True)
    for name in ('nvidia', 'nvidia-drm', 'nvidia-modeset', 'nvidia-uvm', 'nvidia-peermem'):
        module = source / f'kernel-open/{name}.ko'
        magic = subprocess.check_output(['modinfo', '-F', 'vermagic', module], text=True)
        version = subprocess.check_output(['modinfo', '-F', 'version', module], text=True).strip()
        if magic.split()[0] != KERNEL or version != DRIVER:
            raise RuntimeError(f'Wrong module ABI/version: {name}')
        shutil.copyfile(module, modules / module.name)

    # Generate merged indexes against the unchanged distribution modules, then
    # include only indexes and new modules in the SRM, never a replacement root.
    merged = stage / 'merged'
    run('xorriso', '-osirrox', 'on', '-indev', base,
        '-extract', '/sysresccd/x86_64/airootfs.sfs', stage / 'base.sfs')
    run('unsquashfs', '-no-xattrs', '-processors', '4', '-d', merged,
        stage / 'base.sfs', f'usr/lib/modules/{KERNEL}')
    shutil.copytree(modules, merged / f'usr/lib/modules/{KERNEL}/extramodules', dirs_exist_ok=True)
    (merged / 'lib').symlink_to('usr/lib')
    run('depmod', '-b', merged, KERNEL)
    for path in (merged / f'usr/lib/modules/{KERNEL}').glob('modules.*'):
        shutil.copyfile(path, overlay / f'usr/lib/modules/{KERNEL}' / path.name)
    conf = overlay / 'etc/modprobe.d'; conf.mkdir(parents=True)
    (conf / 'system-rescue-nvidia.conf').write_text('options nvidia_drm modeset=1\n')
    manifest = {}
    for path in sorted(overlay.rglob('*')):
        if path.is_symlink():
            manifest[str(path.relative_to(overlay))] = {'symlink': os.readlink(path)}
        elif path.is_file():
            manifest[str(path.relative_to(overlay))] = {'sha256': sha(path)}
    srm = stage / 'nvidia.srm'
    run('mksquashfs', overlay, srm, '-noappend', '-all-root', '-processors', '4', '-comp', 'xz')
    maps = ['-map', str(srm), '/sysresccd/nvidia.srm']
    for relative in ('boot/grub/grubsrcd.cfg', 'sysresccd/boot/syslinux/sysresccd_sys.cfg'):
        config = stage / Path(relative).name
        run('xorriso', '-osirrox', 'on', '-indev', base, '-extract', '/' + relative, config)
        lines = config.read_text().splitlines()
        count = 0
        for i, line in enumerate(lines):
            if ((line.lstrip().startswith('linux ') and '/vmlinuz ' in line)
                    or line.startswith('APPEND archisobasedir=')):
                extra = FLAGS
                if 'nomodeset' in line:
                    extra = 'module_blacklist=nouveau,nova_core,nova_drm,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm'
                lines[i] = line + ' ' + extra
                count += 1
        if count < 4:
            raise RuntimeError(f'Unexpected boot configuration: {relative}')
        config.write_text('\n'.join(lines) + '\n')
        maps += ['-map', str(config), '/' + relative]
    candidate = stage / 'candidate.iso'
    run('xorriso', '-indev', base, '-outdev', candidate, '-boot_image', 'any', 'replay', *maps)
    verify(candidate)
    extracted = stage / 'verified.srm'
    run('xorriso', '-osirrox', 'on', '-indev', candidate,
        '-extract', '/sysresccd/nvidia.srm', extracted)
    if sha(extracted) != sha(srm):
        raise RuntimeError('NVIDIA module differs in built ISO')
    os.link(candidate, output)
    checksum = sha(output)
    receipt = {'file': output.name, 'sha256': checksum, 'bytes': output.stat().st_size,
               'base_sha256': BASE_HASH, 'kernel': KERNEL, 'nvidia': DRIVER,
               'packages': inputs, 'overlay': manifest, 'srm_sha256': sha(srm),
               'build_directory': str(stage), 'compiler': subprocess.check_output(['gcc', '--version'], text=True).splitlines()[0],
               'status': 'payload verified; VM and physical NVIDIA boot tests pending'}
    output.with_suffix('.iso.json').write_text(json.dumps(receipt, indent=2) + '\n')
    output.with_suffix('.iso.sha256').write_text(f'{checksum}  {output.name}\n')
    print(f'Candidate: {output}\nSHA-256: {checksum}', flush=True)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 packaging/build_nvidia.py <new-name.iso>')
    build(sys.argv[1])
