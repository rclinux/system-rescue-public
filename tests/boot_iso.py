"""Start an isolated UEFI GUI VM; inspect via tests/qmp.py, then quit it.

Only the read-only candidate ISO is attached. No host disk or networking.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
iso = Path(sys.argv[1]).resolve()
work = Path(tempfile.mkdtemp(prefix='uefi-', dir=ROOT / 'packaging/build'))
shutil.copyfile('/usr/share/edk2/x64/OVMF_VARS.4m.fd', work / 'vars.fd')
print(work, flush=True)
with (work / 'qemu.log').open('wb') as log:
    process = subprocess.Popen([
        'qemu-system-x86_64', '-machine', 'q35,accel=tcg', '-m', '2048', '-smp', '2',
        '-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd',
        '-drive', f'if=pflash,format=raw,file={work}/vars.fd',
        '-drive', f'file={iso},media=cdrom,readonly=on',
        '-display', 'none', '-nic', 'none', '-serial', f'file:{work}/serial.log',
        '-qmp', f'unix:{work}/qmp.sock,server=on,wait=off'], stdout=log, stderr=subprocess.STDOUT)
    try:
        code = process.wait(timeout=1200)
        if code:
            raise SystemExit(f"QEMU exited {code}; see {work}/qemu.log")
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=10)
