"""Install, boot, capture and recover a Linux fixture in two isolated VM identities.

Only newly created sparse files are writable disks. No networking or host disks.
Candidate application is used for capture/verification/restore, never host code.
"""
from pathlib import Path
import hashlib
import json
import re
import selectors
import shutil
import subprocess
import time
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ISO = ROOT / 'dist/system-rescue-0.1.0-candidate2.iso'
EXPECTED = 'ac9a63432b290eee910f3160bd17f7e185d19694820b7a2c62586b4a20b77cff'


def vm(work, stage, disk, firmware=False):
    identity = 'source' if stage in ('setup', 'source-boot', 'capture') else 'recovery'
    command = ['qemu-system-x86_64', '-name', f'sr-{identity}', '-uuid',
               '11111111-1111-4111-8111-111111111111' if identity == 'source' else '22222222-2222-4222-8222-222222222222',
               '-machine', 'q35,accel=tcg', '-m', '4096', '-smp', '4',
               '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-nic', 'none', '-no-reboot']
    if firmware:
        variables = work / f'{stage}-vars.fd'
        shutil.copyfile('/usr/share/edk2/x64/OVMF_VARS.4m.fd', variables)
        command += ['-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd',
                    '-drive', f'if=pflash,format=raw,file={variables}']
    else:
        command += ['-kernel', str(ROOT / 'baseline/usb-files/sysresccd/boot/x86_64/vmlinuz'),
                    '-initrd', str(ROOT / 'baseline/usb-files/sysresccd/boot/x86_64/sysresccd.img'),
                    '-append', 'archisobasedir=sysresccd archisolabel=RESCUE1302 console=ttyS0,115200 nomdlvm systemd.unit=multi-user.target',
                    '-drive', f'file={ISO},media=cdrom,readonly=on',
                    '-virtfs', f'local,path={work}/share,mount_tag=project,security_model=none,readonly=on']
    command += ['-drive', f'file={disk},format=raw,if=none,id=system',
                '-device', f'virtio-blk-pci,drive=system,serial=SR_REHEARSAL_{stage.upper()}']
    if not firmware:
        command += ['-drive', f'file={work}/vault.raw,format=raw,if=none,id=vault',
                    '-device', 'virtio-blk-pci,drive=vault,serial=SR_REHEARSAL_VAULT']
    (work / f'{stage}-command.json').write_text(json.dumps(command, indent=2) + '\n')
    print(f'Starting {stage}', flush=True)
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    tail = b''; login = False; started = False; success = False; diagnostic = False
    deadline = time.monotonic() + 3600
    try:
        with (work / f'{stage}.log').open('wb') as log:
            while time.monotonic() < deadline:
                control = work / 'input.txt'
                if control.exists():
                    process.stdin.write(control.read_bytes()); process.stdin.flush(); control.unlink()
                if (work / 'stop').exists():
                    raise RuntimeError('Stopped by operator')
                for key, _ in selector.select(1):
                    data = key.fileobj.read1(65536)
                    if not data:
                        raise RuntimeError(f'{stage}: guest exited before success')
                    log.write(data); log.flush(); tail = (tail + data)[-16000:]
                    if firmware:
                        success = success or b'\nSR_INSTALLED_BOOT_OK\r\n' in tail
                        if not success and not diagnostic and b'root@sr-rehearsal' in tail:
                            process.stdin.write(b"systemctl status rehearsal-check.service --no-pager; lsblk -o NAME,TYPE,SERIAL,FSTYPE,MOUNTPOINTS; findmnt /; findmnt /home; bash -x /usr/local/bin/rehearsal-check; result=$?; printf '\\nSR_BOOT_CHECK_EXIT=%s\\n' \"$result\"\n")
                            process.stdin.flush(); diagnostic = True
                        if re.search(rb'\nSR_BOOT_CHECK_EXIT=[1-9][0-9]*\r?\n', tail):
                            raise RuntimeError(f'{stage}: installed boot validation failed; inspect diagnostic log')
                    else:
                        if not login and b'login:' in tail:
                            process.stdin.write(b'root\n'); process.stdin.flush(); login = True
                        if not started and (b'root@sysrescue' in tail or b'root@archiso' in tail):
                            script = f"mkdir -p /mnt/project; mount -t 9p -o trans=virtio,ro project /mnt/project && bash /mnt/project/two_vm_guest.sh {stage}; result=$?; printf '\\nSR_RUN_EXIT=%s\\n' \"$result\"\n"
                            process.stdin.write(script.encode()); process.stdin.flush(); started = True
                        if re.search(rb'\nSR_RUN_EXIT=[1-9][0-9]*\r?\n', tail):
                            raise RuntimeError(f'{stage}: guest script failed; inspect log')
                        success = b'\nSR_RUN_EXIT=0\r\n' in tail and f'\nSR_STAGE_OK={stage}\r\n'.encode() in tail
                    if success:
                        # Flush and power off gracefully before the next VM uses a disk.
                        if firmware:
                            # Boot check service does not provide an interactive login.
                            # Wait for login, then request shutdown below.
                            if not login and b'login:' in tail:
                                process.stdin.write(b'root\n'); process.stdin.flush(); login = True
                            if b'root@' not in tail:
                                continue
                        process.stdin.write(b'sync; systemctl poweroff\n'); process.stdin.flush()
                        while process.poll() is None and time.monotonic() < deadline:
                            for key, _ in selector.select(1):
                                chunk = key.fileobj.read1(65536)
                                log.write(chunk); log.flush()
                        if process.poll() != 0:
                            raise RuntimeError(f'{stage}: clean shutdown failed')
                        print(f'PASS {stage}', flush=True)
                        return
                if process.poll() is not None:
                    raise RuntimeError(f'{stage}: QEMU exited {process.returncode}')
            raise TimeoutError(f'{stage}: exceeded one hour')
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        selector.close()


def main():
    if hashlib.file_digest(ISO.open('rb'), 'sha256').hexdigest() != EXPECTED:
        raise RuntimeError('Candidate ISO checksum mismatch')
    work = Path(tempfile.mkdtemp(prefix='two-vm-', dir=ROOT / 'packaging/build'))
    (work / 'share').mkdir()
    shutil.copyfile(ROOT / 'tests/two_vm_guest.sh', work / 'share/two_vm_guest.sh')
    for name, gib in [('source', 12), ('target', 12), ('vault', 24)]:
        with (work / f'{name}.raw').open('xb') as stream: stream.truncate(gib << 30)
    print(f'Evidence: {work}', flush=True)
    results = {'iso_sha256': EXPECTED, 'source_origin': 'Disk installation from preserved SystemRescue Linux root filesystem', 'stages': []}
    for stage, name, firmware in [('setup', 'source', False), ('source-boot', 'source', True),
                                  ('capture', 'source', False), ('restore', 'target', False),
                                  ('recovery-boot', 'target', True)]:
        vm(work, stage, work / f'{name}.raw', firmware)
        results['stages'].append({'stage': stage, 'result': 'PASS'})
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('PASS: separate source and recovery VM installed-system boot rehearsal', flush=True)


if __name__ == '__main__':
    main()
