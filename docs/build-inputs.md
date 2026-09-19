# Build inputs — what's needed to build an ISO, and where it lives

Building a candidate (`bin/build-iso.sh <name>.iso`) needs two things beyond
this repo, neither of which git tracks:

1. **A base ISO** to layer the repo's `bin/`, `lib/`, `vendor/` and recipe
   onto, via `packaging/tools/sysrescue-customize`.
2. **Build tools**: `xorriso`, `squashfs-tools` (`mksquashfs`/`unsquashfs`),
   `rsync`, `zstd`. On Arch: `pacman -S squashfs-tools xorriso` (rsync/zstd
   are normally already present). Use `pkexec`, not `sudo`, for the install.

## Where the base ISO comes from

`packaging/prepare_base.py:prepare()` tries, in order:

1. `packaging/build/recovered-base.iso` — a cache from a previous run of
   step 2, skipped if already present and checksum-valid.
2. `baseline/<archive>` — the *pristine* original capture named in
   `docs/preservation.json` (`system-rescue-original-full-disk.img.zst`,
   ~5.6GB compressed, decompresses+truncates to the ISO/hybrid-boot extent
   of the original SanDisk Ultra "RESCUE1302" USB). **As of 2026-09-14 this
   file is not present on this machine, and its whereabouts are unknown** —
   it was captured once (2026-09-08) but the archive itself wasn't kept
   anywhere this repo could find. If you ever locate the original SanDisk
   drive again, recreate it with a read-only `dd`+`zstd` capture and verify
   against the `raw_bytes`/`raw_sha256` already recorded in
   `docs/preservation.json` before trusting it.
3. `baseline/last-known-good.iso` — **the fallback that actually matters day
   to day.** Any previously-built, verified candidate ISO works fine as a
   `sysrescue-customize --source`, since it's just as much a valid
   SystemRescue-format image as the pristine base — it just already has our
   payload baked in from last time, which `sysrescue-customize` overwrites
   with the current repo contents anyway. `prepare()` falls back to this
   file automatically — **plain `bin/build-iso.sh <name>.iso` just works**,
   no flags needed, as long as this file is present.

You can also bypass all of the above for a one-off build from a specific
ISO: `bin/build-iso.sh --base-iso=/path/to/some.iso <name>.iso`.

## Where it's backed up

`baseline/` is gitignored (large binaries, and it's a cache, not source).
The durable copy lives on an offline external backup drive, under
`project_backups/system-rescue_build_inputs/`:

```
last-known-good.iso
last-known-good.iso.sha256
last-known-good.iso.json      # provenance: source revision, prior base, etc.
```

**If `baseline/last-known-good.iso` is ever missing on a machine** (fresh
clone, cleared cache, whatever), recover it from that backup location:

```sh
mkdir -p baseline
cp /path/to/backup/system-rescue_build_inputs/last-known-good.iso baseline/
cp /path/to/backup/system-rescue_build_inputs/last-known-good.iso.sha256 baseline/
sha256sum -c baseline/last-known-good.iso.sha256
```

## Keeping it current

After building and verifying a new candidate you intend to keep as the new
baseline (i.e. it passed `bin/verify-iso.sh` and, ideally, a real boot/hardware
test — see `docs/hardware-rehearsal.md`), refresh both copies so the *next*
change builds on top of it instead of an older candidate:

```sh
cp dist/<new-candidate>.iso baseline/last-known-good.iso
sha256sum baseline/last-known-good.iso | awk '{print $1"  last-known-good.iso"}' > baseline/last-known-good.iso.sha256
cp baseline/last-known-good.iso baseline/last-known-good.iso.sha256 \
   /path/to/backup/system-rescue_build_inputs/
cp dist/<new-candidate>.iso.json /path/to/backup/system-rescue_build_inputs/last-known-good.iso.json
```

This is how `baseline/last-known-good.iso` currently holds candidate 5
(`system-rescue-0.1.0-candidate5-restore-label-fix.iso`, sha256
`42a666f5…`), built the same way — from candidate 4 as `--base-iso`, since
the pristine baseline archive was already missing when that change was made.
