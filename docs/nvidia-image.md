# NVIDIA rescue image

Candidate 3 targets the workstation's GeForce RTX 5080 (PCI `10de:2c02`).
It adds an early-loaded `sysresccd/nvidia.srm` to candidate 2. The original
base SquashFS, kernel, initramfs and recovery application stay unchanged.
NVIDIA's open kernel modules, firmware and userspace components all use
version 610.57.04. Modules are compiled for `6.18.41-1-lts`.

Built ISO: `dist/system-rescue-0.1.0-candidate3-nvidia.iso`.
Payload and VM checks passed; it is flashed to a KANGURU SS3 USB drive with
complete direct-read checksum verification.
Physical RTX 5080 boot was confirmed on 2026-09-14 with candidate 5, which carries
this NVIDIA build unchanged, using the normal NVIDIA-enabled entry rather than the
basic-display fallback. This is a live console observation; no log was saved.
See [the checkpoint](build-checkpoint.md).

## Rebuild inputs

Run `python3 packaging/build_nvidia.py <new-candidate-name.iso>` from the
project. Builds never install packages on the host or access block devices.
The builder requires the pinned candidate-2 checksum and verifies its payload.
(As of 2026-09-19 `dist/` holds only candidate 5, so a rebuild needs the
candidate-2 ISO restored to `dist/` first.)
It retains build logs and staging directories under `packaging/build/nvidia`.

Pinned Arch packages (x86_64 `.pkg.tar.zst` files):

- `linux-lts-headers-6.18.41-1`
- `nvidia-open-dkms-610.57.04-1`
- `nvidia-utils-610.57.04-1`
- `egl-gbm-1.1.3-1`
- `egl-wayland-4:1.1.21-1`
- `egl-wayland2-1.0.1-1`
- `egl-x11-1.0.5-1`

Place packages and their detached `.sig` files in `packaging/build/nvidia`.
Packages already cached in `/var/cache/pacman/pkg` can be copied automatically.
Signatures come from `https://archive.archlinux.org/packages/<initial>/<name>/`.
Import the distribution's `/usr/share/pacman/keyrings/archlinux.gpg` into the
build-local `gnupg` directory first. Verification uses public keys only and
does not request a signing passphrase. Package hashes are recorded in the ISO
receipt, alongside the complete NVIDIA overlay manifest and compiler version.

The build host uses GCC 16.2.1; the rescue kernel records GCC 16.1.1. Both
use GCC 16, but the minor-version difference is recorded rather than hidden.
Runtime GPU operation was confirmed by a physical boot on 2026-09-14 (see above).

## Boot behavior and testing

Normal GRUB and Syslinux entries blacklist Nouveau and Nova from the initramfs
onward and enable NVIDIA DRM modesetting. The basic-display (`nomodeset`)
entry blacklists NVIDIA as well, providing a firmware-display fallback.
The existing desktop launcher and Ctrl+Alt+F2 recovery menu remain available.

`python3 tests/run_vm.py dist/<candidate.iso> tests/nvidia_guest.sh` checks
NVIDIA module metadata and shared-library dependencies in the live guest,
then runs the isolated backup/restore fixture tests. A separate UEFI boot
checks the actual boot menu and graphical desktop. QEMU has no NVIDIA GPU;
these checks cannot establish physical GPU acceleration or display output.
They passed against candidate 5 on 2026-09-19
([log](evidence/candidate5-nvidia-guest.log)).

On the workstation, boot normally and check `nvidia-smi`, the desktop,
launcher, keyboard, storage inventory and tty2 fallback. Record failures and
use the basic-display menu entry if necessary. No restore to a physical disk
is authorized by an image-build or USB-flash request.

References: [NVIDIA module build requirements](https://github.com/NVIDIA/open-gpu-kernel-modules)
and [SystemRescue boot options](https://www.system-rescue.org/manual/Booting_SystemRescue/).
