import sys, pathlib, tempfile, shutil, subprocess, hashlib, json, os
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'packaging'))
from verify_iso import verify

def run(*args): subprocess.run([str(a) for a in args],check=True)
def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
base=root/'dist/system-rescue-0.1.0-candidate3-nvidia.iso'
assert sha(base)=='370eddd462eb57e4f12aa28a382fa532e665368b31d62871b7538a39241bb3a3'
out=root/'dist/system-rescue-0.1.0-candidate4-nvidia-progress.iso'
assert not out.exists()
stage=pathlib.Path(tempfile.mkdtemp(prefix='progress-',dir=root/'packaging/build'))
payload=stage/'payload'
shutil.copytree(root/'packaging/recipe/srm_overlay',payload)
for d in ('bin','lib','vendor'):
    shutil.copytree(root/d,payload/'usr/local/system_rescue'/d,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
srm=stage/'customize.srm'
run('mksquashfs',payload,srm,'-noappend','-all-root','-processors','2','-comp','xz')
candidate=stage/'candidate.iso'
run('xorriso','-indev',base,'-outdev',candidate,'-boot_image','any','replay','-map',srm,'/sysresccd/customize.srm')
verify(candidate)
preserved={}
for i,relative in enumerate(('sysresccd/nvidia.srm','sysresccd/x86_64/airootfs.sfs','sysresccd/boot/x86_64/vmlinuz','sysresccd/boot/x86_64/sysresccd.img','boot/grub/grubsrcd.cfg','sysresccd/boot/syslinux/sysresccd_sys.cfg')):
    paths=[]
    for label,iso in [('before',base),('after',candidate)]:
        p=stage/f'{i}-{label}'
        run('xorriso','-osirrox','on','-indev',iso,'-extract','/'+relative,p)
        paths.append(p)
    assert sha(paths[0])==sha(paths[1]),relative
    preserved[relative]=sha(paths[1])
os.link(candidate,out)
checksum=sha(out)
receipt={'file':out.name,'sha256':checksum,'bytes':out.stat().st_size,'base_sha256':sha(base),'preserved':preserved,'payload_sha256':sha(srm),'build_directory':str(stage),'status':'payload verified; VM check pending','changes':'Enable Partclone and dd progress; announce checksum stage'}
out.with_suffix('.iso.json').write_text(json.dumps(receipt,indent=2)+'\n')
out.with_suffix('.iso.sha256').write_text(f'{checksum}  {out.name}\n')
print(json.dumps(receipt,indent=2))
