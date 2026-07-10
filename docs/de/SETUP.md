<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/flashos_logo_dark.png">
    <img src="../../assets/flashos_logo_light.png" alt=".flashOS" width="280">
  </picture>

<h1>Setup</h1>

<p><i>Host-Toolchain, SD-Karten-Layout, serielle Konsole, QEMU und der Test-Runner.</i></p>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Dokumentation</b></a> ·
    <b>Setup</b> ·
    <a href="../../PORT.md"><b>Port</b></a> ·
    <a href="../../VERSIONING.md"><b>Versionierung</b></a> ·
    <a href="../../CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="../../LICENSE.md"><b>Lizenz</b></a>
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
6. [Hilfs-Shell-Funktionen](#6-hilfs-shell-funktionen)
7. [Host-seitige Unit-Tests](#7-host-seitige-unit-tests)

## 1. Host-Toolchain

| Tool                     | Mindestversion | Zweck                                     |
| :----------------------- | :-------------- | :---------------------------------------- |
| Flash                    | 1.4.1           | Flash kompilieren und `build.flash` ausführen |
| Zig                      | 0.16.0          | Verbleibende Zig-Host-Tools kompilieren   |
| `aarch64-elf-objcopy`    | 2.40+           | ELF → Roh-Binary                          |
| `aarch64-elf-nm`         | 2.40+           | Symbol-Extraktion für `populate-syms`     |
| `qemu-system-aarch64`    | 11.0.0+         | Den kernel unter QEMU ausführen           |
| `screen` (oder Äquivalent) | –             | Serielle Konsole für den Pi               |

Unter macOS:

```bash
brew install zig aarch64-elf-binutils qemu
```

### Flash-Compiler (`flashc`)

FlashOS nutzt die gepinnte
[Flash](https://github.com/ajhahnde/Flash)-Toolchain. Flash veröffentlicht
keine vorgebauten Binaries; baue sie deshalb aus dem in
`flash-toolchain.lock` festgelegten Source-Stand:

```bash
git clone https://github.com/ajhahnde/Flash.git ~/Flash
git -C ~/Flash checkout "$(grep -oE '[0-9a-f]{40}' flash-toolchain.lock)"
( cd ~/Flash && zig build )   # → ~/Flash/zig-out/bin/flashc
```

## 2. Bauen

Baue zuerst Flash (siehe §1) und starte anschließend den nativen Build:

```bash
flash build                 # default: kernel8.img + armstub8.bin → flash-out/
```

```bash
source flashos.zsh    # stellt den `build`-Helper bereit
build                     # vollständiger zweiphasiger Build
build -d                  # zweiphasiger Build + Deploy auf die SD-Karte
```

Der `build`-Helper ruft `flash build`, `flash build populate-syms` und dann
erneut `flash build` auf, prüft per Diff, dass das Symbol-Layout
konvergiert ist, und führt — mit `-d` — `flash build deploy` aus. Es gibt
keinen interaktiven Prompt; das `-d`-Flag ist die Deploy-Zustimmung.

### Build-Schritte

| Kommando                                  | Ergebnis                                    |
| :---------------------------------------- | :------------------------------------------ |
| `flash build`                             | Pi-Kernel und Armstub                       |
| `flash build -Dboard=virt`                | `virt`-Kernel ohne Armstub                  |
| `flash build kernel`                      | Nur das Kernel-Image                        |
| `flash build armstub`                     | Nur der Pi-Armstub                          |
| `flash build populate-syms`               | `src/symbol_area.S` neu erzeugen            |
| `flash build deploy`                      | Pi-Build und Firmware nach `$SD_BOOT` kopieren |
| `flash build -Dboard=rpi4b run`           | QEMU `-M raspi4b` starten                   |
| `flash build -Dboard=virt run-virt`       | QEMU `-M virt` starten                      |
| `flash build -Dboard=rpi4b test-rpi4b`    | Einen `raspi4b`-Boot validieren             |
| `flash build -Dboard=virt test-virt`      | Einen `virt`-Boot validieren                |
| `flash build -Dboard=virt iso`            | GRUB-EFI-Rescue-ISO bauen                   |
| `flash build test`                        | Host-Tests ausführen                        |
| `flash build clean`                       | Cache und Build-Ausgabe entfernen           |

Der Standard-Optimierungsmodus ist `ReleaseSmall`. Überschreibe ihn mit
`-Doptimize=ReleaseSafe`, `Debug` oder `ReleaseFast`.

## 3. Ausführen unter QEMU

Zwei QEMU-Maschinen sind verdrahtet; Auswahl über `-Dboard=`:

```bash
flash build -Dboard=rpi4b run        # Pi 4 model (raspi4b)
flash build -Dboard=virt  run-virt   # generic ARMv8 (virt)
```

`-Dboard=rpi4b` ist das validierte Board. `-M virt` ist seit
[v0.5.0](https://github.com/ajhahnde/FlashOS/releases/tag/v0.5.0) nicht mehr
CI-gegated — dem letzten Release, dessen Boot dort verifiziert wurde —, sodass
spätere Releases regrediert sein könnten. Für einen bekanntermaßen stabilen
`-M virt`-Build verwende v0.5.0.

Für einen selbstvalidierenden Lauf, der mit 0 endet, wenn der Boot den
interaktiven `fsh`-Prompt erreicht (die dritte Homescreen-Markierung
`type 'help' for commands` — siehe unten) ohne `[FAIL]` / `ERROR CAUGHT` und mit
den erwarteten Free-Page-Checkpoints, und mit 1 bei einem Fehler oder einem
watchdog-Timeout (keine manuelle QEMU-Überwachung):

```bash
flash build -Dboard=rpi4b test-rpi4b  # (matches run); das CI-Boot-Gate
flash build -Dboard=virt  test-virt   # depriorisiert, nicht CI-gegated
```

Um die Byte-Identitäts-Baseline des Pi vor dem Flashen der SD-Karte zu
verifizieren (legt `src/symbol_area.S` beiseite, säubert, baut neu, vergleicht
per Diff gegen `scripts/pi_baseline.sha256`):

```bash
scripts/verify_pi_baseline.sh
```

`run` ruft
`qemu-system-aarch64 -M raspi4b -serial null -serial stdio -kernel flash-out/kernel8.img`
auf — die Mini-UART (UART1) wird auf das Host-stdio geleitet, sodass die
Ausgabe des kernel und die `[TEST]/[PASS]/[FAIL]`-Zeilen des Test-Harness
direkt im steuernden Terminal erscheinen. `run-virt` verwendet
`-M virt,gic-version=3 -cpu cortex-a72 -m 1G -nographic`, mit der auf das
Host-stdio geleiteten PL011.

Ein grüner Lauf auf beiden Boards landet bei `30/30 passed`, 34
Free-Page-Checkpoints pro Szenario (`0xbbff2` auf rpi4b, `0x3be45` auf virt)
plus der passenden Boot-Baseline (`0xbc000` / `0x3be53`) und 0 `ERROR CAUGHT`.
Der Boot übergibt dann an `/bin/login` → `/bin/fsh`; mit dem
Login-Lifecycle erscheint die Homescreen-Markierung von fsh
(`type 'help' for commands`) dreimal (zwei skriptgesteuerte
`[TEST] login`-Sitzungen + der echte Boot-Login), und der CI-watchdog
(`scripts/run_qemu_test.sh`) zählt genau das. Die Free-Page-Invarianten sind in
[Dokumentation §8](DOCUMENTATION.md#free-page-invarianten) dokumentiert.

QEMU ist das maßgebliche Signal der inneren Schleife. Der Boot-Pfad stimmt
Byte für Byte mit echter Hardware überein, abgesehen vom Timing.

## 4. SD-Karten-Layout

Der Raspberry Pi 4 bootet von einer FAT32-formatierten Karte, deren Root-Verzeichnis
mindestens Folgendes enthalten muss:

```text
config.txt              # ships in this repo
kernel8.img             # built by `flash build`
armstub8.bin            # built by `flash build`
bcm2711-rpi-4-b.dtb     # bundled in this repo
start4.elf              # bundled in this repo
fixup4.dat              # bundled in this repo
overlays/miniuart-bt.dtbo
```

Die firmware-Blobs sind in diesem Repo unter `firmware/`
(`bcm2711-rpi-4-b.dtb`, `start4.elf`, `fixup4.dat`,
`overlays/miniuart-bt.dtbo`) gebündelt. Sie stammen aus dem offiziellen
[raspberrypi/firmware](https://github.com/raspberrypi/firmware/tree/master/boot)-Projekt
und werden hier der Bequemlichkeit sowie der Lizenz-/Credit-Klarheit halber
mitgeführt. Der Deploy-Schritt verweist standardmäßig auf dieses Verzeichnis:

```bash
SD_BOOT=/Volumes/BOOT FIRMWARE=firmware flash build deploy
```

Der Deploy-Schritt liest zwei Umgebungsvariablen:

| Variable   | Default         | Zweck                                            |
| :--------- | :-------------- | :----------------------------------------------- |
| `SD_BOOT`  | `/Volumes/BOOT` | SD-Karten-Mountpunkt unter macOS                 |
| `FIRMWARE` | `firmware`      | Verzeichnis mit den gebündelten RPi-firmware-Dateien |

## 5. Serielle Konsole

Der kernel hat auf dem Pi drei Konsolen-/Debug-Kanäle:

- **Mini-UART (UART1)** an GPIO 14 / 15 — Hauptkonsole (und Fallback,
  wenn USB nicht enumeriert wird).
- **PL011 (UART4)** an GPIO 8 / 9 — dedizierter Trace-Kanal.
- **USB-C-Gadget-Konsole** — die interaktive `fsh`-Konsole über den
  USB-C-Port des Pi; kein Adapter oder Jumper-Kabel (siehe unten).

GPIO 14/15 wird absichtlich mit der firmware geteilt. `config.txt`
aktiviert `uart_2ndstage=1` und `dtoverlay=miniuart-bt`, was das PL011_0
der firmware auf GPIO 14/15 leitet, sodass die `MESS:…`-Zeilen von
`start4.elf` auf demselben Kabel sichtbar sind. Sobald der kernel läuft,
konfiguriert `mini_uart_init` (`src/board/rpi4b/uart.flash`) die Pins auf alt5
(Mini-UART) um — der letzte Schreibzugriff auf den GPIO-Funktionsselektor
gewinnt, sodass das firmware-seitige PL011_0-Routing stillschweigend ersetzt
wird. Dies ist eine sequentielle Übergabe, kein Konflikt.

### UART1-Pinout (RPi 4 → USB-TTL-Adapter)

| RPi-Pin | Funktion      | USB-TTL-Pin |
| :------ | :------------ | :---------- |
| Pin 6   | GND           | GND         |
| Pin 8   | TXD (GPIO 14) | RXD         |
| Pin 10  | RXD (GPIO 15) | TXD         |

Verbinde **nicht** VCC, wenn der Pi unabhängig mit Strom versorgt wird.

### Verbinden unter macOS

Der PL2303G-Chip wird nativ unterstützt. Finde den Device-Node und
öffne eine Sitzung mit 115200 Baud:

```bash
ls /dev/cu.usbserial-*
```

```bash
screen /dev/cu.usbserial-XXXX 115200
```

Beende `screen` mit `Ctrl-A`, dann `K`, bestätigt mit `y`. Um eine
abgetrennte `picapture`-Sitzung von einem zweiten Terminal zu beenden,
führe `piquit` aus (siehe §6).

### USB-C-Konsole (einzelnes C-zu-C-Kabel)

Der eigene USB-C-Port des Pi dient zugleich als Konsole. Der kernel bringt
den DWC2-OTG-Controller des BCM2711 als **CDC-ACM-USB-Gerät**
(`src/board/rpi4b/usb.flash`) hoch, sodass ein USB-C-↔-USB-C-Kabel zum Mac
sowohl **Strom als auch die interaktive `fsh`-Konsole** überträgt. macOS
bindet seinen eingebauten `AppleUSBCDCACM`-Treiber — nichts zu installieren.

```bash
ls /dev/cu.usbmodem*            # node appears once the gadget enumerates
```

```bash
screen /dev/cu.usbmodem00011 115200
```

Sobald enumeriert, wechselt die Ausgabe von user/`fsh` (der `# ` / `$ `-Prompt,
Befehlsausgaben) automatisch von der Mini-UART zur USB-Konsole; die
`[Debug]`-Ausgaben des kernel und der eigene Bring-up-Trace des USB-Treibers
bleiben auf der Mini-UART. Wenn das Gadget nie enumeriert (kein Host
angeschlossen, oder unter QEMU, das den DWC2-Gerätepfad nicht emuliert),
fällt die Konsole auf die Mini-UART zurück, und der oben beschriebene
GPIO-Ablauf funktioniert unverändert.

Die Baudrate ist kosmetisch — hinter dem USB-Gerät steckt keine physische
UART; jede Rate funktioniert. In `screen` getippte Tastenanschläge erreichen
`fsh` über USB-Bulk-OUT; die Härtung von Replug / Re-Enumeration ist ein
bekannter Arbeitsposten; wenn die Konsole nach dem erneuten Einstecken des
Kabels also hängt, mache einen Power-Cycle des Pi.

## 6. Hilfs-Shell-Funktionen

Lade [`flashos.zsh`](../../flashos.zsh) aus dem Repository oder über
`~/.zshrc`:

```bash
source ~/FlashOS/flashos.zsh
```

| Helper | Zweck |
| :----- | :---- |
| `build [-d]` | Zweiphasiger Symbol-Build; `-d` deployt zusätzlich |
| `run qemu` / `run virt` | Gewähltes QEMU-Board bauen und starten |
| `run watchdog [rpi4b|virt]` | Unbeaufsichtigte Boot-Validierung |
| `run test [--NAME]` | Alle oder gefilterte Host-Tests ausführen |
| `run hw [--trace]` | Mit der Pi-Konsole verbinden |
| `pi capture [usb|mu]` | Boot nach `boot.log` mitschneiden |
| `pi connect [usb|mu]` | Interaktive Konsole öffnen |
| `pi list` / `pi quit` | Geräte anzeigen oder Capture beenden |
| `pi log` / `pi tail [N]` | Letzten Mitschnitt lesen oder verfolgen |
| `flashos` | Helper und Build-Schritte auflisten |

Die alten Namen `picapture`, `piconnect`, `piquit` und `pilist`
bleiben Aliase. USB CDC wird als `/dev/cu.usbmodem*`, Mini-UART als
`/dev/cu.usbserial-*` erkannt. Überschreibe die Erkennung mit
`PI_USB_CONSOLE_DEVICE` oder `PI_SERIAL_DEVICE`; die Timeouts mit
`PI_CAPTURE_TIMEOUT` und `PI_PROBE_TIMEOUT`.

Mit `BOARD=virt` zielt `build` auf `virt`; `NM=llvm-nm` überschreibt
das Symbol-Tool. Kernel-Fehler erscheinen nur auf Mini-UART, daher eignet
sich `pi capture mu` zur Fehlerdiagnose.

## 7. Host-seitige Unit-Tests

```bash
flash build test
```

Führt die host-seitigen Unit-Tests gegen Pure-Logic-kernel-Module aus.
Jedes Modul mit Tests bildet seinen eigenen Test-Root, gelinkt gegen
`tests/host_stubs.flash` (Stubs für reine Assembly-Externs). Die aktuelle
Suite deckt 41 Module ab (464 Host-Tests); sie ist weit unter einer Sekunde
fertig und ist das schnellste Signal dafür, dass die Kernlogik des kernel
weiterhin hält.

---

[← Zurück: Dokumentation](DOCUMENTATION.md) · [Als Nächstes: Port →](../../PORT.md)

<!-- sync-ref: SETUP.md @ 8d306a79130b85ad3ba5502a83d80be45709d1f9 | synced 2026-07-01 -->
