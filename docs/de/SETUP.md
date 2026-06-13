<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/flashos_logo_dark.png">
    <img src="../../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Setup</h1>

<p><i>Host-Toolchain, SD-Karten-Layout, serielle Konsole, QEMU und der Test-Runner.</i></p>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Dokumentation</b></a> ·
    <b>Setup</b> ·
    <a href="../../MIGRATION.md"><b>Migration</b></a> ·
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

Diese Seite behandelt die Host-Toolchain, das SD-Karten-Layout, das der
Raspberry Pi 4 erwartet, die serielle Konsole, QEMU und den Test-Runner.

Referenz:
[BCM2711 ARM Peripherals (RPi 4)](https://pip-assets.raspberrypi.com/categories/545-raspberry-pi-4-model-b/documents/RP-008248-DS-1-bcm2711-peripherals.pdf?disposition=inline).

## Inhalt

1. [Host-Toolchain](#1-host-toolchain)
2. [Bauen](#2-bauen)
3. [Ausführen unter QEMU](#3-ausführen-unter-qemu)
4. [SD-Karten-Layout](#4-sd-karten-layout)
5. [Serielle Konsole](#5-serielle-konsole)
6. [Hilfs-Shell-Funktionen](#6-hilfs-shell-funktionen)
7. [Host-seitige Unit-Tests](#7-host-seitige-unit-tests)

## 1. Host-Toolchain

| Tool                       | Mindestversion | Zweck                                     |
| :------------------------- | :-------------- | :---------------------------------------- |
| Zig                        | 0.16.0          | Zig + Assembly kompilieren, `build.zig` ausführen |
| `flashc`                   | pinned          | Flash-Quellen (`.flash`) nach Zig transpilieren |
| `aarch64-elf-objcopy`    | 2.40+           | ELF → Roh-Binary                         |
| `aarch64-elf-nm`         | 2.40+           | Symbol-Extraktion für `populate-syms`   |
| `qemu-system-aarch64`    | 11.0.0+         | Den kernel unter QEMU ausführen           |
| `screen` (oder Äquivalent) | –              | Serielle Konsole für den Pi               |

Unter macOS:

```bash
brew install zig aarch64-elf-binutils qemu
```

### Flash-Compiler (`flashc`)

Die Source-Module von FlashOS sind in
[Flash](https://github.com/ajhahnde/Flash) geschrieben und werden zur
Build-Zeit nach Zig transpiliert. `build.zig` löst das `flashc`-Binary
standardmäßig unter `~/Flash/zig-out/bin/flashc-stage1` auf; überschreibe
den Pfad mit `-Dflashc=<path>`. Flash veröffentlicht keine vorgebauten
Binaries, also baue den gepinnten, selbst-gehosteten Compiler aus dem
Source — führe dies aus dem FlashOS-Checkout aus, damit der Pin aus
`flash-toolchain.lock` gelesen wird:

```bash
git clone https://github.com/ajhahnde/Flash.git ~/Flash
git -C ~/Flash checkout "$(grep -oE '[0-9a-f]{40}' flash-toolchain.lock)"
( cd ~/Flash && zig build stage1 )   # → ~/Flash/zig-out/bin/flashc-stage1
```

`zig build stage1` — nicht das bloße `zig build`, das nur den
stage0-Bootstrap-Seed `flashc` ausgibt — erzeugt `flashc-stage1`, die in
`flash-toolchain.lock` gepinnte Revision. Baue es nur dann neu, wenn sich
dieser Pin verschiebt.

## 2. Bauen

Jeder Build transpiliert die `.flash`-Source-Module mit `flashc`, also
baue ihn zuerst (siehe §1).

```bash
zig build                 # default: kernel8.img + armstub8.bin → zig-out/
```

```bash
./build.sh                # full two-pass build with optional deploy
```

`build.sh` ruft `zig build`, `zig build populate-syms` und dann erneut
`zig build` auf, prüft per Diff, dass das Symbol-Layout konvergiert ist,
und führt optional `zig build deploy` aus.

## 3. Ausführen unter QEMU

Zwei QEMU-Maschinen sind verdrahtet; Auswahl über `-Dboard=`:

```bash
zig build -Dboard=rpi4b run        # Pi 4 model (raspi4b)
zig build -Dboard=virt  run-virt   # generic ARMv8 (virt)
```

Für einen selbstvalidierenden Lauf, der mit 0 endet, wenn der Boot den
interaktiven `fsh`-Prompt erreicht (die dritte Homescreen-Markierung
`type 'help' for commands` — siehe unten) ohne `[FAIL]` / `ERROR CAUGHT` und mit
den erwarteten Free-Page-Checkpoints, und mit 1 bei einem Fehler oder einem
watchdog-Timeout (keine manuelle QEMU-Überwachung):

```bash
zig build -Dboard=virt  test-virt
zig build -Dboard=rpi4b test-rpi4b  # (matches run)
```

Um die Byte-Identitäts-Baseline des Pi vor dem Flashen der SD-Karte zu
verifizieren (legt `src/symbol_area.S` beiseite, säubert, baut neu, vergleicht
per Diff gegen `scripts/pi_baseline.sha256`):

```bash
scripts/verify_pi_baseline.sh
```

`run` ruft
`qemu-system-aarch64 -M raspi4b -serial null -serial stdio -kernel zig-out/kernel8.img`
auf — die Mini-UART (UART1) wird auf das Host-stdio geleitet, sodass die
Ausgabe des kernel und die `[TEST]/[PASS]/[FAIL]`-Zeilen des Test-Harness
direkt im steuernden Terminal erscheinen. `run-virt` verwendet
`-M virt,gic-version=3 -cpu cortex-a72 -m 1G -nographic`, mit der auf das
Host-stdio geleiteten PL011.

Ein grüner Lauf auf beiden Boards landet bei `28/28 passed`, 32
Free-Page-Checkpoints pro Szenario (`0xbbff2` auf rpi4b, `0x3be46` auf virt)
plus der passenden Boot-Baseline (`0xbc000` / `0x3be54`) und 0 `ERROR CAUGHT`.
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
kernel8.img             # built by `zig build`
armstub8.bin            # built by `zig build`
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
SD_BOOT=/Volumes/BOOT FIRMWARE=firmware zig build deploy
```

Der Deploy-Schritt liest zwei Umgebungsvariablen:

| Variable     | Default           | Zweck                                             |
| :----------- | :---------------- | :------------------------------------------------ |
| `SD_BOOT`  | `/Volumes/BOOT` | SD-Karten-Mountpunkt unter macOS                  |
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

Das Repo liefert [`flashos.env.zsh`](../../flashos.env.zsh) mit einer Handvoll Helfern,
bereitgestellt als zwei Verb-Dispatcher — `pi <verb>` (serielle Konsole) und
`run <mode>` (bauen, emulieren oder verbinden) — plus `build` und `flashos`. Source es
aus `~/.zshrc` (`source ~/FlashOS/flashos.env.zsh`), um sie in jeder Shell verfügbar
zu machen. Die alten flachen Namen (`picapture`, `piconnect`, `piquit`, `pilist`)
bleiben als dünne Aliase für die entsprechenden `pi`-Verben erhalten.

- **`picapture [usb|mu]`** — führt den kanonischen Boot-Capture-Ablauf aus
  und protokolliert die Sitzung in `boot.log` im Root-Verzeichnis des Repos
  (unabhängig vom aktuellen Verzeichnis; abgedeckt durch die `.gitignore` des
  Repos).
  - `usb` (default): wartet, bis das CDC-Gadget auf `/dev/cu.usbmodem*`
    enumeriert (das Einstecken des C-zu-C-Kabels versorgt den Pi mit Strom,
    sodass das Erscheinen des Nodes selbst das erste Boot-Signal ist), und
    fragt dann die Konsole einmal pro Sekunde ab, bis die Boot-Markierung
    `type 'help' for commands` erscheint (fsh hat seine interaktive REPL erreicht).
  - `mu`: erfasst den Mini-UART-Trace-Adapter
    (`/dev/cu.usbserial-*`), bis `type 'help' for commands` (der Boot hat die
    Shell über den MU-Fallback erreicht — kein USB-Host angeschlossen) oder
    `ERROR CAUGHT` erscheint. Mache einen Power-Cycle des Pi, wenn dazu
    aufgefordert.
  - kernel-Faults werden ausschließlich auf dem MU-Adapter ausgegeben —
    verwende den `mu`-Modus (Trace-Adapter + externe Stromversorgung) zur
    Fault-Diagnose.
- **`piconnect [usb|mu]`** — öffnet eine interaktive `screen`-Sitzung auf der
  Pi-Konsole mit 115200 Baud. Ohne Argument wählt es automatisch die
  USB-CDC-Konsole (`fsh`), wenn vorhanden, sonst den MU-Trace-Adapter;
  `usb` / `mu` erzwingen einen bestimmten Kanal.
- **`piquit`** — beendet die abgetrennte `pi_capture`-screen-Sitzung, die von
  `picapture` gestartet wurde. Von einem zweiten Terminal verwenden.
- **`pilist`** — listet die angeschlossenen Konsolengeräte auf: die
  USB-CDC-Konsole (`/dev/cu.usbmodem*`) und alle USB-Serial-Adapter
  (`/dev/cu.usbserial-*`, MU-Trace).
- **`pi log`** — zeigt die letzte `boot.log`-Aufzeichnung im Pager an.
- **`pi tail [N]`** — folgt `boot.log` live (letzte `N` Zeilen, default 40)
  und übersteht die Log-Rotation der nächsten Aufzeichnung.
- **`build`** — führt `./build.sh` aus dem Root-Verzeichnis des Repos aus
  (funktioniert aus jedem Verzeichnis): clean, Link-Pass 1, `populate-syms`,
  Link-Pass 2, Diff-Prüfung des Symbol-Layouts, optional `deploy`. `BOARD=virt
  build` wählt das virt-Board (deploy wird übersprungen); `NM=llvm-nm build`
  überschreibt das Symbol-Dump-Binary.
- **`run <mode>`** — baut und startet ein Board, fährt den Boot-Watchdog oder
  verbindet sich mit Hardware. `run qemu` (Alias `auto`) baut und startet das
  rpi4b-Modell in QEMU; `run virt` macht dasselbe für das virt-Board; `run test`
  führt die Host-Unit-Tests aus (`run test --NAME` filtert nach Name); `run hw`
  verbindet sich über die serielle Konsole mit dem Pi (`--trace` wählt den
  MU-Adapter).
- **`run watchdog [virt|rpi4b]`** — fährt den unbeaufsichtigten Boot-Watchdog mit
  den erforderlichen Flags `-Dci-login-seed=true` und `-Dboot-selftest=true`
  automatisch gesetzt; default ist das virt-Board (`rpi4b` ist ein langsamerer
  TCG-Lauf).
- **`flashos`** — listet die in [`flashos.env.zsh`](../../flashos.env.zsh)
  definierten Shell-Helfer und die verfügbaren `zig build`-Schritte auf — eine
  schnelle Inventur der Targets.

Der MU-Trace-Adapter wird automatisch aus `/dev/cu.usbserial-*` erkannt und
die USB-CDC-Konsole aus `/dev/cu.usbmodem*`; überschreibe mit
`PI_SERIAL_DEVICE=/dev/cu.usbserial-XXXX` /
`PI_USB_CONSOLE_DEVICE=/dev/cu.usbmodemXXXX`, wenn mehrere Geräte
angeschlossen sind. Die `picapture`-Timeouts liegen bei 120 s (gesamt) und
30 s (Prompt-Probe); überschreibe mit `PI_CAPTURE_TIMEOUT` / `PI_PROBE_TIMEOUT`.

### Auto-Source bei `cd` (optional)

Um `flashos.env.zsh` automatisch zu laden, sobald die Shell `~/FlashOS`
betritt, hänge einen `chpwd`-Hook an `~/.zshrc` an. Der folgende Befehl ist
idempotent:

```bash
grep -q '_FLASHOS_LOADED' ~/.zshrc || cat >> ~/.zshrc <<'EOF'

# --- FlashOS auto-source on cd ---
autoload -Uz add-zsh-hook
load_flashos_env() {
  if [[ "$PWD" == "$HOME/FlashOS"* && -z "$_FLASHOS_LOADED" ]]; then
    [[ -f "$HOME/FlashOS/flashos.env.zsh" ]] && source "$HOME/FlashOS/flashos.env.zsh" && typeset -g _FLASHOS_LOADED=1
  fi
}
add-zsh-hook chpwd load_flashos_env
load_flashos_env
EOF
```

Öffne eine neue Shell oder führe `source ~/.zshrc` aus, um zu aktivieren.
Setzt voraus, dass das Repo unter `~/FlashOS` liegt.

## 7. Host-seitige Unit-Tests

```bash
zig build test
```

Führt die host-seitigen Unit-Tests gegen Pure-Logic-kernel-Module aus.
Jedes Modul mit Tests bildet seinen eigenen Test-Root, gelinkt gegen
`tests/host_stubs.zig` (Stubs für reine Assembly-Externs). Die aktuelle
Suite deckt 39 Module ab (419 Host-Tests); sie ist weit unter einer Sekunde
fertig und ist das schnellste Signal dafür, dass die Kernlogik des kernel
weiterhin hält.

---

[← Zurück: Dokumentation](DOCUMENTATION.md) · [Als Nächstes: Migration →](../../MIGRATION.md)

<!-- sync-ref: SETUP.md @ e06f2f0724a207b7327749e3bf218e1cac18a774 | synced 2026-06-13 -->
