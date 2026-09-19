#!/bin/bash
# Runs only inside the disposable guest created by run_vm.py.
set -euo pipefail
test "$(uname -r)" = 6.18.41-1-lts
for module in nvidia nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem; do
    test "$(modinfo -F version "$module")" = 610.57.04
    [[ $(modinfo -F vermagic "$module") == '6.18.41-1-lts '* ]]
done
modprobe --show-depends nvidia_drm
test -s /usr/lib/firmware/nvidia/610.57.04/gsp_ga10x.bin
test -s /usr/lib/firmware/nvidia/610.57.04/gsp_tu10x.bin
test -s /usr/share/X11/xorg.conf.d/10-nvidia-drm-outputclass.conf
for file in /usr/bin/nvidia-smi /usr/lib/libEGL_nvidia.so.0 \
    /usr/lib/libGLX_nvidia.so.0 /usr/lib/xorg/modules/drivers/nvidia_drv.so \
    /usr/lib/nvidia/xorg/libglxserver_nvidia.so \
    /usr/lib/libnvidia-egl-gbm.so.1 /usr/lib/libnvidia-egl-wayland.so.1 \
    /usr/lib/libnvidia-egl-wayland2.so.1 \
    /usr/lib/libnvidia-egl-xcb.so.1 /usr/lib/libnvidia-egl-xlib.so.1; do
    test -f "$file"
    output=$(ldd "$file" 2>&1)
    printf '%s\n%s\n' "$file" "$output"
    if [[ $output == *'not found'* ]]; then exit 1; fi
done
# No NVIDIA device is attached. Loading may fail with ENODEV, but unresolved
# kernel symbols or a module ABI failure would be a packaging failure.
modprobe nvidia 2>/tmp/nvidia-load-error || cat /tmp/nvidia-load-error
if dmesg | grep -E 'nvidia.*(Unknown symbol|disagrees about version|invalid module format)'; then
    exit 1
fi
printf 'PASS: NVIDIA guest packaging, ABI metadata and shared-library dependencies\n'
bash /mnt/project/vm_roundtrip.sh
