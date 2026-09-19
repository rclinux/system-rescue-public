# Project boundaries

- Never write to the original SanDisk SystemRescue USB. User explicitly requires it remain unchanged until the new project is finalized; prefer keeping it unchanged afterward as well.
- Treat the original USB capture as immutable evidence (it is no longer present; see `docs/build-inputs.md`). `baseline/last-known-good.iso` is a build cache, refreshed deliberately after each verified candidate. Work in `bin/`, `lib/`, `packaging/`, and `tests/`.
- Do not execute the recovered backup/restore scripts against real disks during development. Use fixtures and isolated virtual disks.
- This repository contains recovered deployment files, not the complete original source repository. Do not claim original tests, packaging, or provenance have been recovered if absent.
- An application exit status, matching occupancy statistics, image checksum, and successful boot are separate pieces of evidence. Report each accurately.
- Final release requires artifact/payload verification and documented recovery testing. Never describe a revised ISO as tested until the relevant checks have run.
- Do not flash any drive without an explicit request and a freshly verified target identity. The existing original USB is excluded.
- User prefers no OpenPGP prompts for local day-to-day work; commit signing stays disabled on the private working branch. This published snapshot is signed, since it's on GitHub — set locally on this branch/repo only, never via global Git settings.
