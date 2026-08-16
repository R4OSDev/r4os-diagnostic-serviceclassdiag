SVCAPPD.R4X
===========

SVCAPPD.R4X ist die Service-App-Klassen-Diagnose.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\ServiceClassDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\ServiceClassDiag\zig-out\SVCAPPD.R4X

Contract:
- Build-Profil: `Zig/R4XStart-Service`
- R4XStart-Entry: `svcappd_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\SVCAPPD.R4X`
- Seit 0.53.16 prueft der Standard-Smoke den queue-basierten
  Service-Endpoint-Vertrag ueber `PERFDIAG.R4X` gegen den registrierten
  SVCAPPD-Autostart-Dienst: Queue-Flag, Queue-Depth, Queue-High-Water,
  Request-/Response-Zaehler und keine Busy-Rejections im normalen Echo-Pfad.
  SVCAPPD selbst bleibt eine Service-Class-App und wird nicht direkt aus
  Terminal gestartet.
- Seit 0.59.7 stellt `/STALLENDPOINT` den absichtlich nicht pollenden
  `SVCSTALL`-Endpoint fuer die dedizierte QEMU-Kill-waehrend-`io_wait`-
  Regression bereit. Der Modus wird nur als gebundener Auto-Service aus dem
  Test-Harness gestartet und beantwortet keine Requests.
