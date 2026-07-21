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
    <img src="https://img.shields.io/badge/rust-1.97.1-dea584?style=flat-square" alt="Rust 1.97.1">
    <img src="https://img.shields.io/badge/target-aarch64--unknown--none--softfloat-lightgrey?style=flat-square" alt="aarch64-unknown-none-softfloat">
    <img src="https://img.shields.io/badge/license-apache--2.0-lightgrey?style=flat-square" alt="Lizenz">
  </p>

<p>
    <b>README</b> ·
    <a href="DOCUMENTATION.md"><b>Dokumentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="../../CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="../../LICENSE"><b>Lizenz</b></a>
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
- **Plattform-Stack.** **FlashSDK** — die Crates `flashsdk-abi`,
  `flashsdk-rt` und `flashsdk-base` in diesem Workspace — definiert den
  schmalen öffentlichen Syscall-/Userspace-ABI-Vertrag, die EL0-Runtime, die
  Basisbibliothek und den Target-/Link-Vertrag; Kernel und jedes User-Programm
  konsumieren ihn in-tree als Path-Dependencies. **FlashShell**, in-tree als
  nested Consumer-Workspace (`components/flashshell/`) mit eigener gepinnter
  Toolchain und eigenem CI-Job eingebettet, ist der erste Produkt-Consumer.
  **FlashUI** folgt als native TUI, bettet FlashShell ein und wird später die
  Standardoberfläche nach dem Login; das heutige `/bin/fsh` bleibt als
  getestete Recovery-Shell erhalten. Diese Verträge bleiben bis zum
  FlashOS-v1.0-Stabilitätsschnitt pre-1.0.
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

## Siehe auch

- **[FlashOS Tour →](https://ajhahn.de/flashos/)**
- **[ajhahn.de →](https://ajhahn.de/)**

---

[Weiter: Dokumentation →](DOCUMENTATION.md)
