# Third-party components

This project is licensed under GPL-3.0-or-later (see [LICENSE](LICENSE)). It
bundles or builds against the following third-party components, under their
own licenses:

## `packaging/tools/sysrescue-customize`

Extracted unchanged from the SystemRescue 13.02 root filesystem
(`/usr/share/sysrescue/bin/sysrescue-customize`).

- Author: Gerd v. Egidy
- License: GPL-3.0-or-later ([full text](packaging/tools/LICENSE.GPL-3.0-or-later.txt))
- Docs: https://www.system-rescue.org/scripts/sysrescue-customize/

## `vendor/gum`

Bundled prebuilt binary of [Charm's `gum`](https://github.com/charmbracelet/gum),
used unmodified for the application's terminal UI prompts. Not built from
source in this repository.

- License: MIT

## NVIDIA driver packages (not redistributed)

The NVIDIA candidate image (see [docs/nvidia-image.md](docs/nvidia-image.md))
is built against NVIDIA's open kernel modules, firmware and userspace
utilities (`nvidia-open-dkms`, `nvidia-utils`, and related packages). **These
packages are never committed to this repository or its history** —
`packaging/build/` is git-ignored, and built ISOs (which do bundle these
binaries) live only in the locally gitignored `dist/` directory. Anyone
rebuilding the NVIDIA image must obtain these packages themselves (e.g. from
the Arch Linux repositories) and accept NVIDIA's own license terms for them.
The open kernel modules (`nvidia-open-dkms`) are dual MIT/GPL; the userspace
utilities (`nvidia-utils`) remain under NVIDIA's proprietary EULA.

## Everything else

The application (`bin/`, `lib/`), packaging/build tooling (`packaging/*.py`,
excluding the files noted above), and test suite (`tests/`) are original
work licensed under GPL-3.0-or-later along with the rest of the repository.
