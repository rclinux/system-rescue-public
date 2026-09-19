# Pinned SystemRescue customizer

`sysrescue-customize` was extracted unchanged from the preserved SystemRescue 13.02 root filesystem at `/usr/share/sysrescue/bin/sysrescue-customize`.

SHA-256: `93065ceb8d96520d0c9efbd769fecb9fe912d747fb344ef90ac4d23ab2fc62cb`

Author: Gerd v. Egidy. SPDX license: GPL-3.0-or-later. The accompanying license text was recovered from `/usr/share/licenses/spdx/GPL-3.0-or-later.txt` in the same root filesystem. The script's argument-parser comments also retain their upstream attribution.

Documentation: https://www.system-rescue.org/scripts/sysrescue-customize/

This is the customizer shipped on the preserved media, not a claim that it is the latest upstream version. It was reviewed before use. Builds call it with explicit regular-file inputs and disposable staging directories; they never invoke its implicit live-USB discovery mode.
