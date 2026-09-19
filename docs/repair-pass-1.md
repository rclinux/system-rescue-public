# First repair pass — 2026-09-08

## Result

The application now rejects the empty-backup fixture that previously passed verification, and propagates partition-table save failures through the backup caller. The original USB and preserved baseline were not modified.

## Changes

- Added a shared v3/v4 manifest schema, used before verification and restore. Rejects missing partitions, unsupported methods, invalid sizes/counts/checksums, duplicate partition numbers/images, unsafe filenames, and multiple JSON documents. Requires at least one image; swap-only disks are not accepted as image backups. Swap metadata alongside imaged partitions remains supported.
- Missing or empty partition-table dumps fail metadata validation, even when image verification is explicitly skipped.
- GPT/MBR save errors propagate. Backup also stops on failed partition enumeration, imaging, checksumming, JSON generation, or final manifest publication. A fresh job folder is required, and the completed manifest is published by renaming a validated temporary file.
- Deep verification no longer silently downgrades to checksum-only verification when the Partclone checker is unavailable. Raw images still receive zstd stream validation; Partclone images fail if their structural check cannot complete. Explicit `SR_DEEP_VERIFY=0` remains available.
- Btrfs probes use `ro,nologreplay`, following [Btrfs mount documentation](https://btrfs.readthedocs.io/en/stable/Administration.html#btrfs-specific-mount-options). Existing ext probes retain `ro,noload`. Failed probe unmounts are reported.

## Evidence

`python3 -m unittest discover -s tests -v`: 16 tests passed, with no expected failures. Tests include valid v3/v4 compressed raw fixtures, missing/empty tables, malformed manifests, missing or changed images, truncation with a matching stored checksum, failed Partclone checking, early restore rejection, simulated mount arguments, and six backup failure stages. A successful simulated backup also passes verification.

`bash -n`: all 16 shell scripts passed syntax checks. `git diff --check` passed.

All device operations in these tests are stubs. No real block device was opened, mounted, backed up, or restored. These are regression checks, not hardware recovery tests.

## Remaining before release

- Reconstruct packaging and build a candidate ISO; compare its extracted payload with the reviewed source, including the new `lib/manifest.jq` file.
- Validate partition-table contents and correspondence with the manifest, not just presence/nonzero size. The current file fixtures deliberately do not prove GPT/MBR table semantics.
- Finish the source-selection and error-path audit noted in the initial review.
- Test actual Partclone/Btrfs round trips on isolated virtual disks, including EFI, subvolumes, corruption and interrupted operations.
- Run UEFI boot checks and an explicitly authorized spare-disk restore/boot rehearsal.
- Improve duplicate-UUID guidance and distinguish occupancy checks from content/boot verification.

No release ISO has been built or approved for flashing in this pass.
