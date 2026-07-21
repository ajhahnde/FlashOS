<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/flashos_logo_dark.png">
    <img src="../../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Setup</h1>

<p><i>Host-Toolchain, SD-Karten-Layout, serielle Konsole, QEMU und Test-Runner.</i></p>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Dokumentation</b></a> ·
    <b>Setup</b> ·
    <a href="../../CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="../../LICENSE"><b>Lizenz</b></a>
  </p>

<p>
    <a href="../../SETUP.md">English</a> ·
    <b>Deutsch</b>
  </p>
</div>

---

Referenz:
[BCM2711 ARM Peripherals (RPi 4)](https://pip-assets.raspberrypi.com/categories/545-raspberry-pi-4-model-b/documents/RP-008248-DS-1-bcm2711-peripherals.pdf?disposition=inline)

## Inhalt

1. [Host-Toolchain](#1-host-toolchain)
2. [Bauen](#2-bauen)
3. [Ausführen unter QEMU](#3-ausführen-unter-qemu)
4. [SD-Karten-Layout](#4-sd-karten-layout)
5. [Serielle Konsole](#5-serielle-konsole)
6. [Shell-Helper](#6-shell-helper)
7. [Host-seitige Unit-Tests](#7-host-seitige-unit-tests)

## 1. Host-Toolchain

| Werkzeug                 | Version / Quelle       | Zweck                                         |
| :----------------------- | :--------------------- | :-------------------------------------------- |
| Rust                     | Repository-Pin         | Kernel, Userland, Hostwerkzeuge und Tests      |
| Clang                    | Host-LLVM              | verbliebene AArch64-`.S`-Quellen assemblieren  |
| Rust `llvm-tools`        | Repository-Pin         | AArch64-Artefakte linken, prüfen und umwandeln |
| `qemu-system-aarch64`    | Repository-Vertragspin | `raspi4b`-Bootvertrag ausführen                |
| `mtools`                 | aktuell                | QEMU-FAT32-Testdisk erzeugen                   |
| `screen` (oder ähnlich)  | –                      | serielle Konsole für den Pi                    |
| Python 3                 | aktuell                | unbeaufsichtigtes Pi-Capture mit stabilem DTR  |

Unter macOS:

```bash
brew install llvm qemu mtools
rustup show
```

`versions.env` ist die einzige redaktionelle Quelle für die laufenden
FlashOS-, Rust- und QEMU-Versionen. `scripts/sync_versions.sh` synchronisiert
daraus die von Cargo, rustup, CI und den öffentlichen Badges benötigten
Konventionsdateien. `rust-toolchain.toml` definiert zusätzlich das Target
`aarch64-unknown-none-softfloat` und die Komponenten `rustfmt`, `clippy`,
`llvm-tools` sowie `rust-src`. `flashos.zsh` löst diese exakte Toolchain über
`rustup` auf, auch wenn ein Paketmanager-Rust früher im `PATH` steht.
`FLASHOS_CLANG=/pfad/zu/clang` überschreibt den verwendeten Assembler.

### Systemanforderungen zur Laufzeit

| Komponente | Aktuelle Anforderung |
| :--------- | :------------------- |
| Board | Raspberry Pi 4 Model B (BCM2711) mit AArch64-Boot |
| RAM | Release-qualifiziert ist das 4-GiB-Modell. Das 1-GiB-Modell wird nicht unterstützt, weil der physische Seitenpool bei 1 GiB beginnt; andere Kapazitäten gehören nicht zum v0.8.0-Hardware-Gate. |
| Bootmedium | Eine FAT32-microSD-Partition. Das aktuelle Boot-Bundle belegt etwa 3,4 MiB; jede übliche Karte bietet damit ausreichend Platz. |
| Kernel-Image | Das aktuelle Produktions-`kernel8.img` ist etwa 1,2 MiB groß und enthält ein Initramfs von ungefähr 87 KiB. Diese Größen können sich zwischen Builds ändern. |
| Konsole | Eine datenfähige USB-C-Verbindung für die User-Konsole; ein 3,3-V-Mini-UART-Adapter ist für frühe Diagnose und Tracing optional. |
| Emulation | `qemu-system-aarch64 -M raspi4b`; die EMMC2- und USB-Device-Hardwarepfade benötigen weiterhin einen echten Pi. |

## 2. Bauen

Direkter Produktions-Build:

```bash
cargo xtask build --board rpi4b
cargo xtask armstub
```

Für den vollständigen zweiphasigen Symbol-Build werden die Shell-Helper
eingebunden:

```bash
source flashos.zsh         # stellt den `build`-Helper bereit
build                      # clean, Hygiene, zweiphasiger Build, Armstub
build -d                   # derselbe Build, danach Deployment auf die SD-Karte
```

`build` führt `cargo xtask clean` und die Source-Hygieneprüfungen aus, linkt
den Kernel zunächst einmal, regeneriert `crates/kernel/generated/symbol_area.S` mit
`populate-syms`, linkt erneut und prüft, ob das Symbol-Layout konvergiert ist.
Für `rpi4b` baut der Helper außerdem den Armstub. Es gibt keinen interaktiven
Deploy-Prompt; `-d` ist die ausdrückliche Zustimmung zum Deployment.

### Build-Schritte

| Befehl                                             | Ergebnis                                    |
| :------------------------------------------------- | :------------------------------------------ |
| `cargo xtask build --board rpi4b`                  | Pi-Kernel, Userland und Initramfs           |
| `cargo xtask armstub`                              | Pi-EL3→EL1-Armstub                          |
| `cargo xtask populate-syms --board rpi4b`          | `crates/kernel/generated/symbol_area.S` regenerieren            |
| `cargo xtask test`                                 | Rust-Hosttests                              |
| `cargo xtask guard --board rpi4b --full`           | vollständiger Clean-Room-Produktions-Build  |
| `cargo xtask build --board rpi4b --trace`          | Kernel mit Trace-Feature                    |
| `cargo xtask clean`                                | `target/` und `rust-out/` entfernen         |
| `run qemu`                                         | QEMU `-M raspi4b` bauen und starten         |
| `run watchdog rpi4b`                               | unbeaufsichtigten Bootvertrag ausführen     |
| `build -d`                                         | zweiphasig bauen und nach `$SD_BOOT` deployen |

Produktionsartefakte verwenden das Cargo-Profil `release`. Das Bare-Metal-
Target und die Soft-Float-ABI werden vom Buildtreiber festgelegt und nicht
interaktiv gewählt.

## 3. Ausführen unter QEMU

Nach `source flashos.zsh` wird der gepflegte `raspi4b`-Pfad so gestartet:

```bash
run qemu
run watchdog rpi4b
```

`rpi4b` ist das validierte Board und das Release-Gate. Der erhaltene
`virt`-Build ist eingefroren und depriorisiert; `run virt` steht für
historische Vergleiche bereit, ist aber kein aktuelles
Kompatibilitätsversprechen.

Der unbeaufsichtigte Lauf prüft Testbilanz, Page-Checkpoints und den finalen
`fsh`-Prompt:

```bash
run watchdog rpi4b
```

Vor dem Flashen kann die Byte-Identität zur Pi-Baseline geprüft werden. Das
Skript sichert `crates/kernel/generated/symbol_area.S` vorübergehend, bereinigt den Build, baut neu
und vergleicht mit `scripts/pi_baseline.sha256`:

```bash
scripts/verify_pi_baseline.sh
```

`run qemu` routet die `raspi4b`-Mini-UART auf Host-stdio. Der Watchdog baut mit
`--boot-selftest` und `--ci-login-seed`, erzeugt die FAT32-Fixture und erzwingt
den seriellen Ausgabevertrag innerhalb von 720 Sekunden.

Ein grüner Lauf meldet `30/30 passed`, weder `[FAIL]` noch `ERROR CAUGHT`, die
erwarteten Page-Checkpoints und drei Shell-Homescreen-Marker. Die exakten
Invarianten stehen in
[Dokumentation §7](DOCUMENTATION.md#qemu-watchdog-vertrag). QEMU ist das
maßgebliche Signal der inneren Entwicklungsschleife; auf echter Hardware läuft
dasselbe Image, abgesehen vom Timing.

## 4. SD-Karten-Layout

Der Raspberry Pi 4 bootet von einer FAT32-formatierten Karte. Ihr Root muss
mindestens diese Dateien enthalten:

```text
config.txt              # Teil dieses Repositorys
kernel8.img             # von `cargo xtask build --board rpi4b`
armstub8.bin            # von `cargo xtask armstub`
bcm2711-rpi-4-b.dtb     # im Repository gebündelt
start4.elf              # im Repository gebündelt
fixup4.dat              # im Repository gebündelt
overlays/miniuart-bt.dtbo
```

Die Firmware-Blobs liegen unter `vendor/raspberrypi-firmware/rpi4b/`. Sie
stammen aus dem offiziellen
[raspberrypi/firmware](https://github.com/raspberrypi/firmware/tree/master/boot)-
Projekt und werden aus Komfort- sowie Lizenz-/Credit-Gründen mitgeführt.
Provenance und Checksummen stehen in `README.md` und `SHA256SUMS` dieses
Verzeichnisses. Der Deploy-Schritt verwendet dieses Verzeichnis standardmäßig:

```bash
SD_BOOT=/Volumes/BOOT build -d
```

| Variable   | Standardwert    | Zweck                                  |
| :--------- | :-------------- | :------------------------------------- |
| `SD_BOOT`  | `/Volumes/BOOT` | SD-Karten-Mountpoint unter macOS       |
| `FIRMWARE` | `vendor/raspberrypi-firmware/rpi4b` | Verzeichnis mit Pi-Firmwaredateien |

## 5. Serielle Konsole

Der Kernel besitzt auf dem Pi drei Konsolen-/Debug-Kanäle:

- **Mini-UART (UART1)** auf GPIO 14/15 – Hauptkonsole und Fallback, solange
  USB nicht enumeriert ist.
- **PL011 (UART4)** auf GPIO 8/9 – separater Trace-Kanal.
- **USB-C-Gadget-Konsole** – interaktive `fsh`-Konsole über den USB-C-Port des
  Pi, ohne Adapter oder Jumper-Kabel.

`config.txt` routet Firmware-Diagnostik auf GPIO 14/15. Beim Kernelstart
schaltet `mini_uart_init` dieselben Pins auf Mini-UART und stellt so einen
nahtlosen Firmware-zu-Kernel-Übergang auf demselben Kabel bereit.

### UART1-Pinout (RPi 4 → USB-TTL-Adapter)

| RPi-Pin | Funktion       | USB-TTL-Pin |
| :------ | :------------- | :---------- |
| Pin 6   | GND            | GND         |
| Pin 8   | TXD (GPIO 14)  | RXD         |
| Pin 10  | RXD (GPIO 15)  | TXD         |

VCC **nicht** verbinden, wenn der Pi separat versorgt wird.

### Verbindung unter macOS

Der PL2303G-Chip wird nativ unterstützt. Device-Node suchen und eine Session
mit 115200 Baud öffnen:

```bash
ls /dev/cu.usbserial-*
screen /dev/cu.usbserial-XXXX 115200
```

`screen` wird mit `Ctrl-A`, danach `K` und Bestätigung mit `y` beendet. Ein
unbeaufsichtigtes Capture lässt sich aus einem zweiten Terminal mit `piquit`
beenden (siehe §6).

### USB-C-Konsole (ein C-zu-C-Kabel)

Der USB-C-Port des Pi enumeriert als CDC-ACM-Gerät und führt Stromversorgung
und interaktive `fsh`-Konsole. Unter macOS ist kein zusätzlicher Treiber nötig.

```bash
ls /dev/cu.usbmodem*            # erscheint nach der Enumeration
screen /dev/cu.usbmodemDEVICE 115200
```

Nach der Enumeration wechselt die User-Ausgabe auf USB; Kernel-Diagnostik
bleibt auf Mini-UART. Ohne USB-Enumeration – auch unter QEMU – greift der
Konsolen-Fallback automatisch. Die Baudrate für `screen` ist beim USB-Gerät
nur kosmetisch. Falls die Konsole nach erneutem Einstecken nicht zurückkehrt,
den Pi aus- und wieder einschalten.

## 6. Shell-Helper

[`flashos.zsh`](../../flashos.zsh) aus dem Repository oder aus `~/.zshrc`
einbinden:

```bash
source ~/FlashOS/flashos.zsh
```

| Helper                         | Zweck                                              |
| :----------------------------- | :------------------------------------------------- |
| `build [-d]`                   | zweiphasiger Symbol-Build; `-d` deployt zusätzlich |
| `run qemu` / `run virt`        | ausgewähltes QEMU-Board bauen und starten          |
| `run watchdog [rpi4b \| virt]` | unbeaufsichtigte Bootvalidierung                    |
| `run test [--NAME]`            | alle oder gefilterte Hosttests                     |
| `run hw [--trace]`             | Verbindung zur Pi-Konsole                          |
| `pi capture [usb \| mu]`       | Boot in `boot.log` aufzeichnen                     |
| `pi connect [usb \| mu]`       | interaktive Konsole öffnen                         |
| `pi list` / `pi quit`          | Devices auflisten oder Capture beenden             |
| `pi log` / `pi tail [N]`       | neueste Aufzeichnung lesen oder verfolgen          |
| `flashos` / `flashos list`     | Helper und native Build-Befehle auflisten          |
| `flashos versions [show \| check \| sync]` | zentrales Versionsmanifest prüfen oder übertragen |
| `flashos check [all \| versions \| docs \| hygiene \| shell]` | gepflegte Repository-Prüfungen ausführen |

Die alten Namen `picapture`, `piconnect`, `piquit` und `pilist` bleiben
Aliase. USB-CDC-Geräte werden als `/dev/cu.usbmodem*`, Mini-UART-Adapter als
`/dev/cu.usbserial-*` erkannt. `PI_USB_CONSOLE_DEVICE` beziehungsweise
`PI_SERIAL_DEVICE` überschreiben die Erkennung; `PI_CAPTURE_TIMEOUT` und
`PI_PROBE_TIMEOUT` ändern die Timeouts.
`pi capture usb` hält DTR/RTS gesetzt und sendet den Prompt-Probe über denselben
offenen Deskriptor. Das vermeidet unter macOS Reconnects durch abgetrennte
Terminal-Sessions. Das interaktive `pi connect` verwendet weiterhin `screen`.

`BOARD=virt` richtet `build` auf den eingefrorenen `virt`-Input aus;
`NM=/pfad/zu/llvm-nm` überschreibt das Symbolwerkzeug. Kernel-Faults erscheinen
nur auf Mini-UART, deshalb für die Diagnose `pi capture mu` verwenden.

`build`, `run qemu`, `run virt`, `run watchdog` und `run test` verwerfen
Versionsdrift vor dem Kompilieren. Release-, Rust- oder QEMU-Versionen werden
nur in `versions.env` geändert und danach mit `flashos versions sync` verteilt.

## 7. Host-seitige Unit-Tests

```bash
cargo xtask test
```

Der Befehl führt die Rust-Hosttests des Workspace gegen Kernel-, ABI-,
Userland- und Buildwerkzeug-Logik aus. Ausgeschlossen sind nur die zwei
Bare-Metal-Static-Libraries, die nicht als Host-Testbinary gelinkt werden
können. Die Ausgabe des Befehls ist die maßgebliche Testzahl und das schnellste
Signal für die reine Logik.

---

[← Zurück: Dokumentation](DOCUMENTATION.md) · [Weiter: Changelog →](../../CHANGELOG.md)
