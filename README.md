# SVCAPPD.R4X

`SVCAPPD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.6`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/SVCAPPD.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

## Generation 2

The normal Start2/Query2 service fixture uses owned endpoint registration/receive/reply/unregister and common bounded admission. Its normal endpoint keeps the 200 ms stop check; the deliberate STALL fixture never drains. Full inventory reads publish only complete staged snapshots and match both process ID and generation under one deadline, including restarts and capacity growth. Exact kill, wait and reap checks, echo/status/BADOP, small/large-buffer negatives and the existing modes remain in place. Arguments use the common UTF8 cursor.
