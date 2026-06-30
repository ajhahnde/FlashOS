<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/flashos_logo_dark.png">
    <img src="../../assets/flashos_logo_light.png" alt="FlashOS" width="420">
  </picture>

<h3>AArch64-Bare-Metal-Kernel für den Raspberry Pi 4B und QEMU <code>-M virt</code></h3>

<p>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajhahnde/FlashOS/test.yml?branch=main&style=flat-square&label=ci" alt="CI"></a>
    <a href="https://codecov.io/gh/ajhahnde/FlashOS"><img src="https://img.shields.io/codecov/c/github/ajhahnde/FlashOS?style=flat-square&label=coverage" alt="Coverage"></a>
    <img src="https://img.shields.io/badge/version-v0.7.1-f59e0b?style=flat-square" alt="Version">
    <img src="https://img.shields.io/badge/zig-0.16.0-lightgrey?style=flat-square" alt="Zig 0.16.0">
    <img src="https://img.shields.io/badge/target-aarch64--elf-lightgrey?style=flat-square" alt="aarch64-elf">
    <img src="https://img.shields.io/badge/license-Apache--2.0-lightgrey?style=flat-square" alt="License">
  </p>

<p>
    <a href="DOCUMENTATION.md"><b>Dokumentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="../../PORT.md"><b>Port</b></a> ·
    <a href="../../VERSIONING.md"><b>Versionierung</b></a> ·
    <a href="../../CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="../../LICENSE.md"><b>Lizenz</b></a>
  </p>

<p>
    <a href="../../README.md">English</a> ·
    <b>Deutsch</b>
  </p>
</div>

---

<p align="center">
  <img src="../../assets/boot_demo.gif" alt="FlashOS booting on a Raspberry Pi into the fsh shell" width="780">
</p>

> Der Boot oben ist eine echte Serial-Console-Aufnahme von FlashOS
> beim Booten auf echter Raspberry-Pi-4B-Hardware bis zum
> `login:`-Prompt; die anschließende `fsh`-Session — `help`, `ls` und
> `sysinfo` — spielt die echte Ausgabe der Shell in einer lesbaren Kadenz ab,
> bevor ein abschließendes `reboot` die Demo zurück zum Boot schleift.

## About

FlashOS ist ein Bare-Metal-AArch64-Kernel, der auf Raspberry-Pi-4B-
Hardware und unter QEMU bootet. Der Kernel-Core ist in
[Flash](https://github.com/ajhahnde/Flash) geschrieben — einer
Systemsprache, die zu Zig transpiliert — mit dem Boot-Pfad, den
Exception-Vektoren und dem Context Switch in AArch64-Assembly. Der
Build wird vollständig von `build.zig` gesteuert, das die
`.flash`-Module durch einen gepinnten `flashc` transpiliert.
Der aktuelle Release liefert einen vollständigen Uniprozessor-
Lebenszyklus (`fork`, `exec`, `exit`, `wait`, `kill`), leckfrei über
Stress-Zyklen hinweg, geprüft durch ein kernelinternes
`[TEST]/[PASS]/[FAIL]`-Harness und eine host-seitige Unit-Test-Suite.

## Spezifikationen

|                 |                                                                                       |
| :-------------- | :------------------------------------------------------------------------------------ |
| **Hardware**    | Raspberry Pi 4 Model B (BCM2711)                                                      |
| **Architektur** | AArch64 (ARMv8-A)                                                                     |
| **Sprachen**    | Flash (zu Zig transpiliert) + AArch64-Assembly                                        |
| **Toolchain**   | `flashc` (gepinnt) + Zig 0.16.0 +`aarch64-elf`-binutils                               |
| **Targets**     | RPi 4B-Hardware,`qemu-system-aarch64 -M raspi4b`, _und_ `qemu-system-aarch64 -M virt` |

## Features

- **Zweistufiger Boot.** Der EL3-armstub konfiguriert die GIC und
  `eret` in den Kernel auf EL1 (Pi). Auf QEMU `-M virt` führt `boot.S`
  den EL3→EL1-Drop selbst aus.
- **Dual-Target-Build.** `-Dboard=rpi4b` oder `-Dboard=virt` schaltet
  zur Compile-Zeit das pro-Board-Treiberbündel (`uart`, `gpio`,
  `timer`, `irq`), das Linker-Skript und die Boot-Eigenheiten um.
- **Vierstufige MMU.** Identity Map für das frühe Bring-up, lineare
  High Map für den Kernel, bedarfsweise allozierte User-Pages mit
  pro-Region-Flags (text RX, data/heap/stack RW+UXN).
- **Priority-Round-Robin-Scheduler** mit timergesteuerter Preemption.
- **Prozess-Lebenszyklus.** `fork` / `exec` / `exit` / `wait` / `kill`,
  Zombie-Reap-Pfad, leckfrei über Stress-Zyklen hinweg.
- **ELF64-Loader.** `sys_execve` löst einen Pfad über das VFS auf,
  streamt jedes PT_LOAD-Segment mit den richtigen Berechtigungen in
  einen frisch gebauten Adressraum und mappt eifrig die oberste
  Stack-Page, bevor der argv-Block auf den neuen User-Stack kopiert
  wird.
- **Userland-Mini-libc (`flibc`).** SVC-Wrapper, `printf` über
  `sys_writeConsole`, Bump-Allocator über `brk` / `sbrk`,
  `fork` / `wait` / `exit` / `execve`. Vom Build in die ELF-Demos
  gelinkt, abgelegt unter `user_space/lib/flibc/`.
- **Heap über `sys_brk` / `sys_sbrk`.** Pages werden vom
  Page-Fault-Pfad innerhalb von `[HEAP_BASE, brk)` bedarfsweise
  alloziert; ein Schrumpfen unmappt und gibt frei.
- **Regionsbewusstes Page-Fault-Dispatch.** `do_data_abort`
  klassifiziert nach User-VA-Region (heap / stack / stack-guard / text
  / wild) und panict-und-zombiet bei Zugriff außerhalb der Region; das
  `sys_wait` des Elternteils reapt den Übeltäter, sodass das Harness
  weiterläuft.
- **Stack Guard.** Eine 1-Page große ungemappte Region unterhalb des
  legalen Stack-Bereichs verwandelt eine außer Kontrolle geratene
  Rekursion in eine `[KERN] stack overflow`-Diagnose statt in
  Speicherkorruption.
- **Vereinheitlichte File Descriptors.** Eine einzige getaggte
  `fds`-Tabelle pro Task (`console` / `pipe` / `file`) hinter einer
  einzigen `read` / `write` / `close` / `dup2`-ABI; fd 0/1/2 sind
  vorinstallierte Console-Slots, `fork` erbt die Tabelle und `execve`
  bewahrt sie, sodass eine Shell einem Kind umgeleitetes stdio
  übergeben kann. Anonyme Pipes (`sys_pipe`) nutzen dieselbe Tabelle.
- **Interaktive Shell (`fsh`).** Eine Userland-REPL unter `/bin/fsh`
  über einer Mini-libc (`flibc`): ein `readline`-Zeileneditor mit
  TAB-Vervollständigung (Doppel-TAB listet die Kandidaten auf), ein
  Tokenizer mit einer einzelnen `|`-Pipe-Stufe, In-Process-Built-ins
  (`cd` / `pwd` / `exit` / `logout` / `help` / `free` / `whoami` /
  `reboot`), ein Unix-artiger `#`/`$`-Privileg-Prompt und `fork` +
  `execvp` (`/bin/<name>`-Auflösung) für externe Programme — dazu
  `/bin/echo`, `/bin/cat`, `/bin/ls` (der zustandslose
  `sys_readdir`-Konsument), `/bin/grep` (literale Zeilensuche),
  `/bin/cp` / `/bin/mv` / `/bin/rm` (FAT32-Dateiverwaltung über die
  create/unlink/rename-Syscalls), `/bin/meminfo`, `/bin/forkbomb` (eine
  gedeckelte Leak-Probe), `/bin/sysinfo` (eine Key/Value-System-
  Zusammenfassung), `/bin/cpuinfo` (CPU-Temperatur + Takt),
  `/bin/uptime` (Zeit seit Boot), `/bin/less` (ein Full-Screen-Pager),
  `/bin/edit` (ein Full-Screen-Texteditor), `/bin/clear` (eine
  Bildschirmlöschung) und `/bin/passwd`. Liest beim Start
  `/etc/fshrc`; `sys_chdir` gibt jedem Task ein Arbeitsverzeichnis. Die
  coreutils nutzen fest dimensionierte stack/static-Puffer; der
  Userland-Heap (`brk`/`sbrk` hinter flibcs Bump-`malloc`) hat seinen
  ersten Konsumenten im wachsbaren Puffer von `/bin/edit`.
- **Prozess-Identität, Login & Berechtigungen.** Jeder Task
  trägt reale + effektive uid/gid (über `fork` vererbt, über `execve`
  bewahrt) hinter einer ABI der `getuid`/`setuid`-Familie, und jede
  Datei trägt mode/uid/gid-Metadaten, die an der open/write/exec-
  Syscall-Grenze durchgesetzt werden (`-EACCES`, root umgeht sie). Der
  Boot führt `/bin/login` als Session-Supervisor aus: der Kernel
  verifiziert das Passwort mit PBKDF2-HMAC-SHA256 + einem
  konstant-zeitigen Vergleich (`sys_authenticate` — die KDF verlässt
  nie den Kernel), dann forkt login ein Kind, das Privilegien ablegt und
  die Shell des Users per exec startet; `exit` kehrt zum `login:`-Prompt zurück.
  Passwörter liegen in einem beschreibbaren `/mnt/shadow` auf der
  SD-Karte (durch ein FAT32-Permission-Overlay auf `0600 root:root`
  geschützt, mit dem read-only-initramfs-Seed als stets bootfähigem
  Fallback) und werden mit `passwd` / `sys_passwd` geändert — frisch
  kernel-generiertes Salt, splice-sicheres In-Place-Rewrite. Der
  Passwort-Echo wird über `SYS_SET_CONSOLE_MODE` unterdrückt. Die
  Seed-Accounts nutzen feste öffentliche Salts (Build-
  Reproduzierbarkeit); rotierte Records bekommen zufällige Salts.
- **Syscalls** werden über `svc` und eine indizierte Tabelle dispatcht
  — siehe
  [Dokumentation §5](DOCUMENTATION.md#5-syscalls--ausnahmen).
- **USB-C-Gadget-Konsole.** Der USB-C-Port des Pi enumeriert als
  CDC-ACM-Serial-Gerät (BCM2711 DWC2 OTG — Full-Speed, polled,
  Slave/PIO): ein einzelnes C-zu-C-Kabel zu einem Mac überträgt sowohl
  Strom als auch die interaktive `fsh`-Konsole
  (`/dev/tty.usbmodem…`, keine Treiberinstallation). Die User-/Shell-
  Ausgabe wechselt zu USB, sobald enumeriert, und fällt andernfalls
  auf die Mini-UART zurück.
- **Zwei UARTs.** Mini-UART (UART1) für den Console-Fallback +
  Kernel-Diagnose, dedizierte PL011 für einen Out-of-Band-Trace-Kanal.
- **Kernel-Symboltabelle**, generiert durch einen zweiphasigen
  `populate-syms`-Schritt und konsumiert vom Function-Entry-Tracer
  (Laufzeit intakt, aber derzeit inert — Zig hat noch kein Äquivalent
  zu `-fpatchable-function-entry=2`).
- **Kernelinternes Test-Harness** (`[TEST]/[PASS]/[FAIL]` + Bilanz, 30
  Szenarien) plus eine host-seitige `zig build test`-Suite (468
  Host-Tests über 41 Module).

## Schnellstart

Die Toolchain installieren:

```bash
brew install zig aarch64-elf-binutils qemu
```

Die Source-Module von FlashOS sind in
[Flash](https://github.com/ajhahnde/Flash) geschrieben und werden zur
Build-Zeit von `flashc` zu Zig transpiliert. Den gepinnten Compiler
einmal bauen — `build.zig` sucht ihn standardmäßig unter
`~/Flash/zig-out/bin/flashc-stage1` (mit `-Dflashc=<path>`
überschreiben):

```bash
git clone https://github.com/ajhahnde/Flash.git ~/Flash
git -C ~/Flash checkout "$(grep -oE '[0-9a-f]{40}' flash-toolchain.lock)"
( cd ~/Flash && zig build stage1 )   # → ~/Flash/zig-out/bin/flashc-stage1
```

Alles für den Pi bauen (`kernel8.img` + `armstub8.bin` landen in
`zig-out/`):

```bash
zig build                   # default: -Dboard=rpi4b
```

Oder für QEMU `-M virt` bauen (kein armstub):

```bash
zig build -Dboard=virt
```

Den Kernel unter QEMU ausführen:

```bash
zig build -Dboard=rpi4b run        # raspi4b machine (Pi 4 model)
```

```bash
zig build -Dboard=virt  run-virt   # generic ARMv8 virt machine
```

Host-seitige Unit-Tests ausführen (Page Allocator + ELF-Parser):

```bash
zig build test
```

Für den vollständigen Hardware-Ablauf (zweiphasiger Build mit
Symboltabellen-Befüllung und einem interaktiven `deploy`-Prompt):

```bash
./build.sh
```

Siehe [Setup](SETUP.md) für das SD-Karten-Layout, die Firmware-Dateien
und das Setup der seriellen Konsole.

## Build-Schritte

| Schritt                              | Was er tut                                                            |
| :----------------------------------- | :-------------------------------------------------------------------- |
| `zig build` (oder `-Dboard=rpi4b`)   | Default — Pi:`kernel8.img` + `armstub8.bin`                           |
| `zig build -Dboard=virt`             | virt:`kernel8.img` only (no armstub)                                  |
| `zig build kernel`                   | Nur Kernel-Image                                                      |
| `zig build armstub` (rpi4b only)     | Nur Armstub                                                           |
| `zig build populate-syms`            | `src/symbol_area.S` aus der gelinkten ELF neu generieren              |
| `zig build deploy` (rpi4b only)      | Artefakte + RPi-Firmware nach `$SD_BOOT` kopieren                     |
| `zig build -Dboard=rpi4b run`        | Boot unter `qemu-system-aarch64 -M raspi4b`                           |
| `zig build -Dboard=virt run-virt`    | Boot unter `qemu-system-aarch64 -M virt`                              |
| `zig build -Dboard=virt test-virt`   | virt booten, watchdog prüft, dass der Boot den fsh-Prompt erreicht    |
| `zig build -Dboard=rpi4b test-rpi4b` | raspi4b booten, watchdog prüft, dass der Boot den fsh-Prompt erreicht |
| `zig build -Dboard=virt iso`         | Eine GRUB-EFI-Rescue-ISO bauen (nur virt)                            |
| `zig build test`                     | Host-seitige Unit-Tests (468 tests, 41 modules)                      |
| `zig build clean`                    | `.zig-cache/` und `zig-out/` entfernen                                |

Der Standard-Optimierungsmodus ist `ReleaseSmall`. Mit
`-Doptimize=ReleaseSafe` (oder `Debug`, `ReleaseFast`) überschreiben.

## Repository-Layout

```text
src/                kernel core (Flash + AArch64 assembly)
src/board/<name>/   per-board driver bag (rpi4b / virt) + linker script
user_space/         PID 1 image + in-kernel test harness
user_space/lib/flibc/  userland mini-libc for ELF demos
lib/                shared kernel↔user constants (syscall IDs)
tools/              hand-rolled ELF demos (hello, stackbomb, flibc_demo)
tests/              host-side unit tests
armstub/            EL3 → EL1 bootstrap shim (Pi only)
scripts/            symbol-table generation, iso, QEMU test watchdog,
                    Pi-baseline verifier
assets/             logo and visual assets
build.zig           the only build entry point
build.sh            two-pass build orchestrator + deploy prompt
flash-toolchain.lock  pinned flashc revision (Flash→Zig transpiler)
config.txt          RPi 4 firmware configuration
```

Ein tieferer Durchgang durch jedes Subsystem findet sich in der
[Dokumentation](DOCUMENTATION.md).

## Versionierung

`v[MAJOR].[MINOR].[PATCH]`. Pro-Tag-Notizen finden sich auf der
[Releases-Seite](https://github.com/ajhahnde/FlashOS/releases).

## KI-Unterstützung

Die Prosa-Docs in diesem Repo (README, DOCUMENTATION, CHANGELOG, PORT)
sind LLM-entworfen unter meiner Durchsicht. Ehrlich gehalten werden sie
durch den Build, nicht durch Vertrauen: das OS wird verifiziert, indem
man es bootet, nicht indem man es beschreibt.

- Bootet von derselben Kernel-ABI in eine Login-Shell auf QEMU `virt`
  und Raspberry Pi 4B
- `-Dboot-selftest=true` führt das kernelinterne `[TEST]`-Harness als
  PID 1 vor dem Login-Prompt aus — Prozess-, Dateisystem-, Memory-Fault-
  und Geräte-Szenarien, jeweils von Free-Page-Checkpoints eingeklammert,
  um Leaks sichtbar zu machen
- Der Kernel ist in Flash geschrieben und über den Schwester-Compiler
  `flashc` zu Zig transpiliert — gepinnt in `flash-toolchain.lock`

Wenn ein Doc behauptet, ein Subsystem funktioniere, dann ist es der
Boot-Pfad, der es ausübt.

Die Docs werden außerdem durch eine automatisierte Drift-Prüfung aktuell
gehalten, die die darin zitierten Contract-Werte — Version,
Boot-Contract-Zahlen, ABI-Konstanten — mit dem Live-Tree synchron hält,
sodass eine veraltete Kopie erkannt statt ausgeliefert wird.

Der Source-Code (`src/*.flash`, die Zig-Treiber, die AArch64-Assembly)
ist von mir verfasst.

## Lizenz

Apache License, Version 2.0. Siehe [Lizenz](../../LICENSE.md).

## Siehe auch

- **[Flash](https://github.com/ajhahnde/Flash)** — eine Systemsprache und Zig-Transpiler.
- **[eeco](https://github.com/ajhahnde/eeco)** — selbstwartendes Workflow-Ökosystem.
- **[the-way-out](https://github.com/ajhahnde/the-way-out)** — Top-down-Pixel-Art-Escape-Room-Shooter.
- **[Theria](https://github.com/ajhahnde/Theria)** — 2.5D-MOBA, gebaut in Godot 4.


---

[Als Nächstes: Dokumentation →](DOCUMENTATION.md)

<!-- sync-ref: README.md @ 0a9d568ee52436afe4be497a523c67c369df150e | synced 2026-06-18 -->
