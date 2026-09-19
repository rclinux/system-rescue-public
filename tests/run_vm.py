"""Run a guest integration script with disposable disks and read-only code sharing.

No host block devices, networking, privileged mounts, or hardware acceleration.
Logs and sparse test disks remain under packaging/build for inspection.
"""
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run():
    iso = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'dist/system-rescue-0.1.0-candidate1.iso'
    app_root = '/usr/local/system_rescue' if len(sys.argv) > 1 else '/mnt/project'
    work = Path(tempfile.mkdtemp(prefix='roundtrip-', dir=ROOT / 'packaging/build'))
    share = work / 'share'; share.mkdir()
    for name in ('lib', 'bin'):
        shutil.copytree(ROOT / name, share / name, ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copyfile(ROOT / 'tests/vm_roundtrip.sh', share / 'vm_roundtrip.sh')
    guest_script = 'vm_roundtrip.sh'
    if len(sys.argv) > 2:
        script = Path(sys.argv[2]).resolve()
        if not script.is_file() or script.parent != ROOT / 'tests':
            raise ValueError('Guest script must be a project test file')
        guest_script = script.name
        if guest_script != 'vm_roundtrip.sh':
            shutil.copyfile(script, share / guest_script)
    command = ['qemu-system-x86_64', '-machine', 'q35,accel=tcg', '-m', '3072', '-smp', '2',
               '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-nic', 'none', '-no-reboot',
               '-kernel', str(ROOT / 'baseline/usb-files/sysresccd/boot/x86_64/vmlinuz'),
               '-initrd', str(ROOT / 'baseline/usb-files/sysresccd/boot/x86_64/sysresccd.img'),
               '-append', 'archisobasedir=sysresccd archisolabel=RESCUE1302 console=ttyS0,115200 nomdlvm systemd.unit=multi-user.target',
               '-drive', f'file={iso},media=cdrom,readonly=on',
               '-virtfs', f'local,path={share},mount_tag=project,security_model=none,readonly=on']
    for name, size in [('source', 2 << 30), ('target', 2 << 30), ('vault', 4 << 30)]:
        path = work / f'{name}.raw'
        with path.open('xb') as stream:
            stream.truncate(size)
        command += ['-drive', f'file={path},format=raw,if=none,id={name}',
                    '-device', f'virtio-blk-pci,drive={name},serial=SR_TEST_{name.upper()}']
    print(f'VM evidence: {work}', flush=True)
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray(); started = False; login_sent = False; deadline = time.monotonic() + 1800
    try:
        with (work / 'serial.log').open('wb') as log:
            while time.monotonic() < deadline:
                control = work / 'input.txt'
                if control.exists():
                    process.stdin.write(control.read_bytes()); process.stdin.flush()
                    control.unlink()
                if (work / 'stop').exists():
                    raise RuntimeError('Test VM stopped by operator')
                for key, _ in selector.select(1):
                    block = key.fileobj.read1(65536)
                    if not block:
                        raise RuntimeError(f'VM exited: {process.poll()}')
                    log.write(block); log.flush(); output.extend(block)
                    tail = bytes(output[-8000:])
                    if not login_sent and b'login:' in tail:
                        process.stdin.write(b'root\n'); process.stdin.flush(); login_sent = True
                    if not started and (b'root@sysrescue' in tail or b'root@archiso' in tail):
                        time.sleep(1)
                        process.stdin.write(("export SR_APP_ROOT=" + app_root + "; mkdir -p /mnt/project; mount -t 9p -o trans=virtio,ro project /mnt/project; bash /mnt/project/" + guest_script + "; result=$?; printf '\\nSR_VM_EXIT=%s\\n' \"$result\"\n").encode())
                        process.stdin.flush(); started = True
                        print('Guest script started', flush=True)
                    if b'SR_VM_EXIT=0\r\n' in tail or b'SR_VM_EXIT=0\n' in tail:
                        print('PASS: guest integration completed', flush=True)
                        return
                    if started and b'SR_VM_EXIT=' in tail:
                        import re
                        match = re.search(rb'SR_VM_EXIT=([1-9][0-9]*)[\r\n]', tail)
                        if match:
                            raise RuntimeError(f'Guest failed: {match[1].decode()}; see {work}/serial.log')
                if process.poll() is not None:
                    raise RuntimeError(f'VM exited early: {process.returncode}')
            raise TimeoutError('VM integration exceeded 30 minutes')
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
        selector.close()


if __name__ == '__main__':
    run()
