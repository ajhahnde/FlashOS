<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/flashos_logo_dark.png">
    <img src="../../assets/flashos_logo_light.png" alt="FlashOS" width="420">
  </picture>

<h3>UNIX-artiges Bare-Metal-Betriebssystem für AArch64, entwickelt für Raspberry Pi 4B und QEMU</h3>

<p>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajhahnde/FlashOS/ci.yml?branch=main&style=flat-square&label=ci" alt="CI"></a>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/security.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajhahnde/FlashOS/security.yml?branch=main&style=flat-square&label=security" alt="Security"></a>
    <a href="https://github.com/ajhahnde/FlashOS/releases/latest"><img src="https://img.shields.io/github/v/release/ajhahnde/FlashOS?style=flat-square&label=release" alt="Neuestes Release"></a>
    <a href="https://codecov.io/gh/ajhahnde/FlashOS"><img src="https://img.shields.io/codecov/c/github/ajhahnde/FlashOS?style=flat-square&label=coverage" alt="Coverage"></a>
    <img src="https://img.shields.io/badge/version-v0.8.0-f59e0b?style=flat-square" alt="Version">
    <img src="https://img.shields.io/badge/rust-toolchain--pinned-dea584?style=flat-square" alt="Repository-gepinnte Rust-Toolchain">
    <img src="https://img.shields.io/badge/target-aarch64--unknown--none--softfloat-lightgrey?style=flat-square" alt="aarch64-unknown-none-softfloat">
    <img src="https://img.shields.io/badge/license-apache--2.0-lightgrey?style=flat-square" alt="Lizenz">
  </p>

<p>
    <b>README</b> ·
    <a href="DOCUMENTATION.md"><b>Dokumentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
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
  <img src="../../assets/boot_demo.gif" alt="FlashOS startet auf einem Raspberry Pi bis zur fsh-Shell" width="780">
</p>

> Der gezeigte Boot ist eine Reproduktion eines FlashOS-Starts auf echter
> Raspberry-Pi-4B-Hardware bis zum `login:`-Prompt.

## Über FlashOS

FlashOS ist ein Bare-Metal-AArch64-Betriebssystem für Raspberry-Pi-4B-Hardware
und QEMU. Der Kernel-Core ist in Rust implementiert; Boot-Pfad,
Exception-Vektoren und Context-Switching bleiben AArch64-Assembly.

Der aktuelle Release bietet einen vollständigen Uniprozessor-Prozesslebenszyklus
mit `fork`, `exec`, `exit`, `wait` und `kill` und bleibt auch unter
wiederholtem Stresstest frei von Leaks. Ein kernelinternes
`[TEST]`/`[PASS]`/`[FAIL]`-Harness und crate-lokale Rust-Hosttests prüfen die
Korrektheit.

Installation, Buildbefehle, QEMU, SD-Karten-Deployment und Konsolen-Setup sind
unter **[Setup](SETUP.md)** beschrieben.

> FlashOS befindet sich vor Version 1.0; Kompatibilität zwischen Releases ist
> noch nicht garantiert.

## Eckdaten

**Hardware**: Raspberry Pi 4 Model B (BCM2711)<br>
**Qualifizierter RAM**: 4-GiB-Konfiguration<br>
**Architektur**: AArch64 (ARMv8-A)<br>
**Sprachen**: Rust und AArch64-Assembly<br>
**Toolchain**: Cargo, Clang und die gepinnten Rust-LLVM-Werkzeuge<br>
**Targets**: RPi-4B-Hardware und `qemu-system-aarch64 -M raspi4b`<br>
**Release-Image**: beim aktuellen `kernel8.img` etwa 1,2 MiB

## Features

- **Zweistufiger Boot.** Ein EL3-Armstub wechselt auf dem Pi für den Kernel
  nach EL1.
- **Vierstufige MMU.** Frühes Identity-Mapping, lineares High-Mapping des
  Kernels und bedarfsweise allozierte User-Pages mit regionsabhängigen Rechten.
- **Priority-Round-Robin-Scheduler** mit timergetriebener Präemption.
- **Prozesslebenszyklus.** Leak-freies `fork`, `exec`, `exit`, `wait` und
  `kill` einschließlich Zombie-Reaping.
- **ELF64-Loader.** `sys_execve` lädt ELF-Segmente über die VFS in einen neuen
  Adressraum und bereitet den User-Stack samt `argv` vor.
- **Userland-Mini-libc (`flibc`).** Syscall-Wrapper, formatierte Ausgabe,
  Heap-Allokation und Prozess-APIs für ELF-Programme.
- **Dynamischer Heap.** `sys_brk` und `sys_sbrk` erweitern den Heap
  bedarfsweise und geben Pages beim Verkleinern zurück.
- **Regionsbewusste Page Faults.** Ungültige Zugriffe beenden nur den
  verursachenden Prozess.
- **Stack-Guard.** Eine ungemappte Guard-Page erkennt Stack-Überläufe, bevor
  sie Speicher beschädigen.
- **Vereinheitlichte File Descriptors.** Konsole, Pipe und Datei teilen eine
  API mit vererbbarer und umleitbarer Standard-Ein-/Ausgabe.
- **Künftiger Plattform-Stack.** Nach dem Rust-Port-Release definiert
  **FlashSDK** den schmalen öffentlichen Syscall-/Userspace-ABI-Vertrag, die
  EL0-Runtime, die Basisbibliothek und den Target-/Link-Vertrag. Danach wird
  **[FlashShell](https://github.com/ajhahnde/FlashShell)** erster
  Produkt-Consumer. **[FlashUI](https://ajhahn.de/repos/FlashUI/)** folgt als
  native TUI, bettet FlashShell ein und wird später die Standardoberfläche
  nach dem Login. Das heutige `/bin/fsh` bleibt als getestete Recovery-Shell
  erhalten. Diese Verträge bleiben bis zum FlashOS-v1.0-Stabilitätsschnitt
  pre-1.0.
- **Benutzer, Login und Berechtigungen.** UID/GID-Identität, Unix-artige
  Dateimodi, Privilege-Drop, PBKDF2-HMAC-SHA256-Authentifizierung und
  geschützter Passwortspeicher mit read-only Fallback.
- **Syscalls** über `svc` und eine indizierte Tabelle.
- **USB-C-Gadget-Konsole.** CDC-ACM liefert Strom und interaktive Konsole über
  ein Kabel, mit automatischem Mini-UART-Fallback.
- **Zwei UARTs.** Mini-UART führt Diagnostik und Fallback-Konsolen-I/O; PL011
  stellt einen separaten Trace-Kanal bereit.
- **Kernel-Symboltabelle.** Ein zweiphasiger Build generiert Symbole für den
  Function-Entry-Tracer.
- **Testsuiten.** Kernelinternes `[TEST]`/`[PASS]`/`[FAIL]`-Harness und
  crate-lokale Rust-Hosttests.

Eine ausführliche Tour durch die Subsysteme steht in der
[Dokumentation](DOCUMENTATION.md).

## Repository-Layout

```text
arch/aarch64/               AArch64-ISA-Core (Boot, Vektoren, Context Switch)
src/                        Board-/Linker-Glue, Trace-Assembly, generierte Symbole
src/board/<name>/           Board-spezifische Assembly-Definitionen + Linker-Skript
crates/abi/                 kernelprivate Task-, ELF- und Page-Deskriptor-Layouts
crates/kernel/              Rust-Kernelimplementierung
crates/flibc/               Rust-Userland-Engines (Readline, Pager, TUI) für ELF-Programme
user/                       Rust-PID-1, Shell, Tools und Testprogramme
rootfs/                     statische Initramfs- und FAT32-Seed-Dateien
tools/                      verbliebene ELF-Linker-Skripte + Initramfs-Embed-Assembly
armstub/                    EL3→EL1-Bootstrap-Shim (nur Pi)
xtask/                      nativer Build-, Prüf-, Generator- und Guard-Treiber
scripts/                    QEMU-Watchdog, SD-Fixture, Hygiene, Baseline-Prüfung
assets/                     Logo und visuelle Assets
Cargo.toml                  Rust-Workspace
flashos.zsh                 Shell-Helper einschließlich zweiphasigem `build`
config.txt                  Raspberry-Pi-Firmwarekonfiguration
```

## Siehe auch

- **[FlashOS Tour →](https://ajhahn.de/flashos/)**
- **[ajhahn.de →](https://ajhahn.de/)**
- **[FlashSDK →](https://github.com/ajhahnde/FlashSDK)**
- **[FlashShell →](https://ajhahn.de/repos/FlashShell/)**
- **[FlashUI →](https://ajhahn.de/repos/FlashUI/)**

---

[Weiter: Dokumentation →](DOCUMENTATION.md)
