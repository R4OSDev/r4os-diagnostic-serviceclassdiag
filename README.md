# SVCAPPD.R4X

`SVCAPPD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.2`
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

Version 0.1.4: Der normale Test-Endpoint `/HOLD /ENDPOINT` wartet mit
`serviceEndpointWait` auf Requests und prüft Stop spätestens nach 200 ms.
Damit entfällt der leere Queue-Poll nach jedem Tick. Echo-, Status- und
BADOP-Antworten werden weiterhin vom vorhandenen Requesthandler erzeugt.
Die absichtlich schweigende Variante `/STALLENDPOINT` und `/HOLD` behalten
ihr bisheriges Verhalten.

Der normale KVM4-Lauf mit Kernel 451 und Spectra 105 bestätigt alle sechs
bestehenden Serviceprüfungen, Stop/Start mit echten Taskgenerationen 49→163
und IDLE256 mit zwei ruhigen APs, zwei freigegebenen Tasks und 16 Timed Wakes.
Der vollständige Kernel127-Kontext brach vorher bei Cooldown Phase 3 ab
(eigenständiger Befund 0.88.107); seine erfolgreiche Wiederherstellung und
der formale Roadmapabschluss sind noch offen. Vollständige Originale:
ExFiles/Reports/Core/0.88.106-idle-admission/FirstNative/.
