<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/flashos_logo_dark.png">
    <img src="../../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Dokumentation</h1>

<p><i>Wie Build, Boot-Pfad, Speicher, Tasks, Userland, Tracing und Release-Gates zusammenspielen.</i></p>

<p>
    <a href="README.md"><b>README</b></a> ·
    <b>Dokumentation</b> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="../../CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="../../LICENSE"><b>Lizenz</b></a>
  </p>

<p>
    <a href="../../DOCUMENTATION.md">English</a> ·
    <b>Deutsch</b>
  </p>
</div>

---

Dieses Dokument beschreibt die aktuelle Rust-Implementierung. Historische
Source-Layouts und stillgelegte Buildpfade bleiben über Git-Historie und
Changelog nachvollziehbar, sind aber keine aktuellen Buildanweisungen.

## Inhalt

1. [Source-Layout](#1-source-layout)
2. [Build- und Boot-Pfad](#2-build--und-boot-pfad)
3. [Memory-Management](#3-memory-management)
4. [Tasks, Dateien und Userland](#4-tasks-dateien-und-userland)
5. [Syscalls und Exceptions](#5-syscalls-und-exceptions)
6. [Kernel-Symbole und Tracing](#6-kernel-symbole-und-tracing)
7. [Tests und Release-Gates](#7-tests-und-release-gates)
8. [Build-Artefakte](#8-build-artefakte)

## 1. Source-Layout

Die aktive Implementierung ist nach Verantwortung statt nach Sprache
aufgeteilt:

```text
arch/aarch64/                       AArch64-Boot, Vektoren, IRQ-Entry, Switching
  boot.S                            Reset-Entry, Page Tables, MMU-Aktivierung
  entry.S                           Exception-Vektoren und Syscall-Dispatch
  sched.S                           Context-Switch-Primitive
  irq.S, generic_timer.S            Architektur-IRQ-/Timer-Helper
  asm_defs*.inc                     für Assembly sichtbare ABI-Konstanten
  trace/                            Function-Entry-Trampolines und Hook

board/                              Per-Board-Assembly und Linker-Inputs
  rpi4b/                            Pi-Assembly-Definitionen und Linker-Skript
  virt/                             eingefrorene virt-Assembly-/Linker-Inputs

generated/                          eingecheckte build-generierte Quellen
  symbol_area.S                     generierte Kernel-Symboltabelle fester Größe

crates/kernel-abi/                  gemeinsame Task-, Syscall-, ELF- und EL0-ABI
crates/kernel/                      aktive Rust-Kernelimplementierung
  crates/kernel/src/kmain.rs        Bring-up, PID 0 und Start von PID 1
  crates/kernel/src/page_alloc.rs
  crates/kernel/src/mm_user.rs      physischer und virtueller User-Speicher
  crates/kernel/src/sched.rs
  crates/kernel/src/fork.rs
  crates/kernel/src/execve.rs       Task-Lebenszyklus und ELF-Laden
  crates/kernel/src/sys.rs          Syscall-Handler und Dispatch-Tabelle
  crates/kernel/src/vfs.rs
  crates/kernel/src/file.rs
  crates/kernel/src/fdtable.rs      VFS, offene Dateien, Descriptor-Ownership
  crates/kernel/src/initramfs.rs
  crates/kernel/src/initramfs_backend.rs schreibgeschütztes Root-Dateisystem
  crates/kernel/src/fat32.rs
  crates/kernel/src/fat32_backend.rs FAT32-Parser und veränderbares /mnt-Backend
  crates/kernel/src/rpi4b_emmc2.rs, rpi4b_usb.rs  repräsentative Pi-Treiber
  crates/kernel/src/trace/          Symbollookup, Entry-Tracing und Sampling
crates/klib/                        Static-Link- und C-ABI-Export-Seam
crates/flibc/                       Userland-Engines (Readline, Pager, TUI)
crates/console-ui/                  gemeinsame Boot-/Statusdarstellung
crates/pwfile/                      gemeinsamer /etc/passwd-Parser

userland/                           Rust-EL0-Programme
  init/pid1/                        PID 1 und Runtime-Harness mit 30 Szenarien
  shells/fsh/                       interaktive Shell
  auth/login/, auth/passwd/         Authentifizierungsprogramme
  interactive/edit/, .../less/      Vollbildprogramme
  coreutils/                        cat, clear, cp, echo, grep, ls, mv, rm
  system/                           cpuinfo, dmesg, meminfo, sysinfo, uptime
  fixtures/                         argv-echo, flibc-demo, hello,
                                    forkbomb, stackbomb — ABI-, Stress-, Fault
  link/                             beibehaltene EL0-Linker-Skripte

rootfs/                             eingecheckte Dateisystem-Seeds
  etc/passwd                        Account-Datenbank
  etc/perms.tab                     FAT32-Berechtigungs-Overlay
  etc/fshrc                         Shell-Startdatei

xtask/                              nativer Build-, Generator- und Prüftreiber
userland/link/                      userland ELF-Linker-Skripte
armstub/                            Pi-EL3→EL1-Bootstrap
scripts/                            Watchdog, Disk-Image, Hygiene und Baseline
vendor/raspberrypi-firmware/rpi4b/  gebündelte Raspberry-Pi-Firmware-Inputs
Cargo.toml                          Rust-Workspace und Release-Profil
versions.env                        Quelle für Release-, Rust- und QEMU-Version
rust-toolchain.toml                 synchronisierter Compiler-Pin, Target, Komponenten
flashos.zsh                         Build-/Run-/Deploy- und Pi-Konsolen-Helper
```

Die außerhalb von Rust verbleibenden Assembly- und Linker-Inputs liegen neben
dem, was sie beschreiben: ISA-Code in `arch/aarch64/`, Per-Board-Link-Inputs in
`board/` und die build-generierte Symboltabelle in `generated/`. Der
maschinenunabhängige Kernel liegt in `crates/kernel/`; der gemeinsame
Assembly-Vertrag in `crates/kernel-abi/` wird mit `cargo xtask asm-defs --check` geprüft.

## 2. Build- und Boot-Pfad

### Nativer Produktions-Build

`cargo xtask build --board rpi4b` führt den vollständigen Produktions-Link aus:

1. Cargo baut die Kernel-Static-Library für
   `aarch64-unknown-none-softfloat`.
2. Jedes EL0-Programm wird gebaut, geprüft, gestript und gestaged.
3. `xtask` generiert den deterministischen `/etc/shadow`-Seed.
4. Die sortierte Initramfs-Eintragsliste wird als deterministisches newc-CPIO
   kodiert.
5. Clang assembliert die verbliebenen `.S`-Dateien.
6. `rust-lld` linkt `kernel8.elf` mit dem Board-Linker-Skript.
7. `llvm-objcopy` erzeugt `kernel8.img`.
8. Der Build verwirft undefined Symbols, `core::fmt`, FP/SIMD-Instruktionen,
   doppelte Memory-Provider und Artefakte außerhalb ihrer Größenbudgets.

Rust-Compiler, Target, `rust-src` und LLVM-Werkzeuge stammen aus
`rust-toolchain.toml`. Clang ist der einzige Compiler außerhalb der gepinnten
Rust-Toolchain. Der von `cargo xtask guard --board rpi4b --full` geprüfte
Build-Trace belegt, welche Subprozesse gelaufen sind.

Der `build`-Helper aus `flashos.zsh` verwirft zuerst Abweichungen von
`versions.env` und ergänzt danach einen sauberen Start, Source-Hygieneprüfungen,
zweiphasige Symbolgenerierung, eine Symbolkonvergenzprüfung und den Pi-Armstub.
`run` nutzt dieselbe Versionsvorprüfung vor jedem Build- oder Testpfad. Die
exakten Befehle stehen unter [Setup](SETUP.md).

### Raspberry-Pi-Boot

1. Die Pi-Firmware liest `config.txt`, lädt `armstub8.bin` und `kernel8.img`
   und startet den Armstub auf EL3.
2. `armstub/src/armstub8.S` richtet den Übergang von EL3 nach EL1 ein.
3. `_start` in `arch/aarch64/boot.S` setzt den frühen Stack und die Page
   Tables, löscht BSS, programmiert die EL1-Übersetzungsregister, aktiviert die
   MMU und springt über das High-Mapping nach `kernel_main`.
4. `kernel_main_impl` in `crates/kernel/src/kmain.rs` läuft auf Core 0.
   Secondary Cores bleiben geparkt; FlashOS arbeitet derzeit Single-Core.
5. Der Bring-up initialisiert Page-Allocator, Mini-UART, PL011-Trace-UART,
   Vektoren, GIC, USB-Gadget, Symbol- und Syscall-Tabelle, Initramfs, EMMC2,
   optionales FAT32-Mount, Entropiequelle und Generic Timer.
6. Der Scheduler erzeugt PID 1 als Kernel-Thread. Dieser erhält die
   Konsolen-Descriptors 0, 1 und 2, findet `/sbin/init` im Initramfs und lädt
   dessen ELF-Image nach EL0.
7. `userland/init/pid1/src/lib.rs` führt optional das Boot-Selftest-Harness aus und
   exect danach `/bin/login`. Login authentifiziert, forkt ein Session-Kind,
   legt dessen UID/GID ab und exect die konfigurierte Shell.

Das normale Deploy-Image führt das Selftest-Harness nicht aus und endet am
interaktiven Login. Das Watchdog-Image ergänzt `--boot-selftest` und
`--ci-login-seed`, damit derselbe Pfad unbeaufsichtigt abgeschlossen werden
kann.

Der erhaltene `virt`-Board-Input ist eingefroren und depriorisiert. Das aktive
QEMU-Gate bootet ein `rpi4b`-Image mit Selftest-/Login-Features; die exakten
Default- und Trace-Artefakte werden separat auf echter Raspberry-Pi-Hardware
qualifiziert.

## 3. Memory-Management

### Kernel- und physischer Speicher

FlashOS verwendet 4-KiB-Pages und eine vierstufige AArch64-Übersetzung. Die
Boot-Assembly erzeugt ein frühes Identity-Mapping und das lineare High-Mapping
ab `0xffff000000000000`. Die Helper in `crates/kernel/src/mm_user.rs`
übersetzen zwischen physischer Adresse und High-Alias.

Der Page-Allocator in `crates/kernel/src/page_alloc.rs` besitzt auf dem Pi den
Bereich `0x40000000..0xfc000000`: 770.048 mögliche 4-KiB-Pages. Der Bring-up
reserviert Pages unterhalb des gelinkten Kernelendes und oberhalb des
Board-RAM-Limits. Beim aktuellen 4-GiB-Pi-Layout sind diese Reservierungen ein
No-op, weil der Kernel unterhalb des Pools liegt und RAM bis zu dessen Ende
reicht; beim eingefrorenen 1-GiB-`virt`-Input verkleinern sie den Pool.

Der Allocator verwendet ein Byte pro Page. Allokation liefert eine physische
Adresse oder null; jeder Consumer behandelt null als OOM und darf sie nicht
mappen. Pro Task werden höchstens 32 User-Pages und 32 Page-Table-Pages
verfolgt.

### Virtuelles EL0-Layout

`crates/kernel-abi/src/user.rs` ist die einzige Quelle der Wahrheit:

| Region | Beginn / Umfang | Aktuelle Mapping-Policy |
| :----- | :-------------- | :---------------------- |
| Text | `0x0000000000000000` | ausführbare PT_LOAD-Pages |
| Data | `0x0000000000100000` | nicht ausführbare PT_LOAD-Pages |
| Heap | ab `0x0000000000200000` bis `brk` | bedarfsweise RW+XN |
| Stack | 16 Pages unter `0x00000ffffffff000` | bedarfsweise RW+XN |
| Guard | eine Page unter dem legalen Stackfenster | beendet den Task |

Der ELF-Loader mappt ausführbare Segmente ohne XN und alle anderen Segmente
mit XN. Der aktuelle Descriptor-Satz kennt kein User-Read-only-Bit;
ausführbare Pages sind daher weiterhin schreibbar und W^X wird noch nicht
erzwungen.

Der Loader mappt die oberste Stack-Page eager und legt dort `argc`, `argv` und
Argumentstrings ab. Weitere legale Stack- und Heap-Pages werden bei
Translation Faults gemappt. Ein Fault in der Guard-Page, im Textbereich oder
in einem anderen unzulässigen EL0-Bereich macht den Task mit Diagnose zum
Zombie; der Parent reapt später dessen Adressraum.

`copy_from_user` und `copy_to_user` prüfen und prefaulten zunächst den gesamten
Bereich. Falsche oder übergroße User-Pointer liefern einen Fehler an den
Syscall zurück, statt einen behandelbaren Argumentfehler in einen Kernel-Fault
zu verwandeln.

### Task-Speicher und OOM

Jeder dynamisch erzeugte Task besitzt:

- eine Page mit seinem `TaskStruct`;
- eine separate 4-KiB-Kernel-Stack-Page;
- ein privates Page-Table-Root und verfolgte Page-Table-Pages;
- kopierte oder neu geladene User-Pages.

PID 0 behält den Boot-Stack. Die Trennung von Kernel-Stack und `TaskStruct`
verhindert, dass ein tiefer Syscall-Stack Credential-Felder erreicht. `KeRegs`,
der 272 Byte große gespeicherte Exception-Frame, liegt oben in der dedizierten
Stack-Page und lässt 3.824 Byte für die aktive Call-Chain; ein verschachtelter
IRQ verbraucht einen Teil dieses Budgets. Für Assembly sichtbare Größen und
Offsets werden aus `crates/kernel-abi/` generiert.

Teilweise Fork-, Page-Table-, Pipe-, File- und Exec-Allokationen besitzen
explizite Rollback-Pfade. Hat Exec seinen Point of no Return überschritten,
beendet ein OOM beim Laden den Task, statt das alte Image wiederherzustellen.

## 4. Tasks, Dateien und Userland

### Scheduler und Prozesslebenszyklus

`crates/kernel/src/sched.rs` verwaltet eine feste Tabelle von 64
Task-Pointern. Der Scheduler ist uniprozessor-, präemptiv und
prioritätsgewichtet: Runnable Tasks verbrauchen einen Counter; nach einer
erschöpften Runde werden die Counter aus den Prioritäten neu gefüllt.
`arch/aarch64/sched.S` tauscht Callee-saved Register, SP, FP, LR und die
Translation Base.

- `fork` allokiert Task-Page und Kernel-Stack, klont den User-Adressraum,
  vererbt File Descriptors, CWD und Credentials und veröffentlicht danach das
  Kind.
- `exit` markiert den aktuellen Prozess als Zombie und weckt den Parent.
- `wait` blockiert bis ein Kind reapbar ist und gibt dann Descriptors,
  User-Pages, Page-Table-Pages, Kernel-Stack und Task-Page frei.
- `kill` wendet den Zombie-Übergang auf einen anderen Prozess an. Self-kill
  wird abgewiesen; ein Prozess beendet sich selbst mit `exit`.
- `execve` löst ein ELF über die VFS auf, kopiert Programm und `argv` in
  begrenzten Kernel-Scratch-Speicher, ersetzt den Adressraum und tritt am
  ELF-Entry ein. PID, Credentials, CWD und Descriptors bleiben erhalten.

### File Descriptors, Pipes und Konsole

Jeder Task besitzt acht getaggte Descriptor-Slots. Ein Slot ist leer, Konsole,
Pipe oder Datei. Die vereinheitlichten Syscalls `read`, `write`, `close` und
`dup2` dispatchen anhand dieses Tags.

Konsolen-Descriptors verweisen auf prozessweite Devices und besitzen kein
allokiertes Objekt. Pipes und offene Dateien sind refcounted: `fork` erhöht
Referenzen, `close` und Reaping senken sie, die letzte Referenz gibt die
Backing-Page frei. Pipe- und Konsolen-Reads blockieren auf Wait Queues statt
im Userland zu pollen.

Mini-UART-RX-Interrupts speisen den 256-Byte-Ring aus
`crates/kernel/src/console.rs`; das USB-CDC-ACM-Gadget speist denselben Ring.
User-Ausgabe wechselt bei konfiguriertem Gadget zu USB und verwendet sonst
Mini-UART. Kernel-Diagnostik bleibt auf Mini-UART; Function-Entry-Traces laufen
über PL011 auf GPIO 8/9.

### VFS und Initramfs

`crates/kernel/src/vfs.rs` besitzt zwei Mount-Slots:

| Pfad | Backend |
| :--- | :------ |
| alles außer `/mnt/...` | schreibgeschütztes Initramfs-Root |
| `/mnt/...` | FAT32, wenn EMMC2 und Volume erfolgreich gemountet sind |

Der Prefix enthält den abschließenden Slash; `/mnt2/file` bleibt deshalb beim
Initramfs-Backend. Es gibt weder einen allgemeinen Mount-Syscall noch einen
Longest-Prefix-Mountbaum.

Das deterministische Initramfs enthält:

- `/sbin/init`;
- Shell, Login, Passwd, Editor, Pager und Core-Utilities unter `/bin`;
- `/etc/passwd`, `/etc/shadow` und `/etc/fshrc`;
- vier ELF-Fixtures unter `/test`.

Der newc-Encoder und die Mode-Policy pro Eintrag liegen in
`xtask/src/initramfs.rs` und `xtask/src/build.rs`. Programme sind `0755`,
öffentliche Konfiguration `0644` und Shadow `0600`; alle gehören root.

### FAT32

`crates/kernel/src/rpi4b_emmc2.rs` bietet polled Single-Block-I/O für den
BCM2711-Arasan-Controller. `crates/kernel/src/fat32.rs` parst MBR, BPB, FAT und
Directory Entries; `crates/kernel/src/fat32_backend.rs` stellt die
VFS-Operationen bereit.

Die veränderbare Oberfläche unterstützt Open, Read, Write, Seek, Create,
Unlink, Rename und indizierte Directory-Reads für reguläre Dateien. Namen sind
nur FAT 8.3; Long Filenames fehlen. Create und Unlink gelten nur für Dateien,
Rename nur innerhalb desselben Verzeichnisses.

QEMUs `raspi4b`-Maschine stellt keinen nutzbaren EMMC2-/SD-Pfad bereit. FAT32-
Roundtrip und Metadata-Mutation skippen daher unter QEMU und sind
Hardware-Akzeptanztests. Die Host-Suite prüft reine FAT32-Logik und einen
In-Memory-Backend-Seam, nicht das physische EMMC2-Timing.

FAT32 kennt keine Unix-Ownership-Felder. FlashOS liest beim Mount
`PERMS.TAB` und legt Mode/UID/GID nach Basename darüber. Fehlende Einträge
erhalten `0666` root:root; `SHADOW` wird selbst bei fehlendem oder ungültigem
Overlay mindestens auf `0600` root:root begrenzt.

### Identität und Authentifizierung

`/etc/passwd` verwendet `name:uid:gid:home:shell`, `/etc/shadow` das Format
`name:iterations:salt_hex:hash_hex`. Der Kernel führt PBKDF2-HMAC-SHA256 und
den Constant-Time-Vergleich aus; Userland erfährt nur Erfolg oder Misserfolg.

Der Shadow-Datensatz im Initramfs ist ein unveränderlicher Recovery-Seed.
Wenn verfügbar, dient `/mnt/shadow` als schreibbare Datenbank.
Passwortänderungen verwenden ein neues kernelgeneriertes Salt und schreiben
den gleich langen Record in place neu. Root darf jedes Account-Passwort
zurücksetzen; Nicht-root darf nur den eigenen Record nach Angabe des alten
Passworts ändern.

Der Seed nutzt bewusst feste öffentliche Salts und eine moderate Iterationszahl,
damit das Produktionsimage reproduzierbar und der Boottest unter QEMU TCG
praktikabel bleibt. Der aktuelle Entropieprovider ist ein timer-gemischter
Fallback und meldet diese Einschränkung; ein BCM2711-RNG200-Treiber ist nicht
implementiert.

Die Berechtigungsprüfung in `crates/kernel/src/perm.rs` wendet klassische
Owner-/Group-/Other-Bits auf Open, Write und Exec an. Effektive UID 0 umgeht
die Prüfung. ACLs, Supplementary Groups, Setuid-Bits, `chmod`, `chown` und
Open-Mode-Flags fehlen noch.

### Userland

Das FlashSDK-Crate `flashsdk-rt` stellt EL0-Entry und SVC-Transport bereit,
`flashsdk-base` die formatierte Ausgabe, Prozess-Wrapper und den Bump-Heap; beide
werden an einer fixierten Revision eingebunden. `crates/flibc/` ergänzt die
Userland-Engines darauf: Readline/History/Completion, Key-Decoding, Pager- und
Gap-Buffer-Cores sowie TUI-Rendering.

`fsh` führt Built-ins im eigenen Prozess aus und forkt externe Kommandos.
Bloße Kommandonamen werden als `/bin/<name>` aufgelöst; Environment und
`PATH` gibt es nicht. Der Parser akzeptiert eine Pipeline-Stufe und verbindet
beide Kinder mit `pipe` und `dup2`.

`less` und `edit` nutzen Alternate Screen und rohes Key-Decoding im Userland.
`edit` ist der wichtigste Heap-Consumer und speichert durch Unlink, Create und
Neuschreiben, weil der aktuelle FAT32-Write-Pfad eine vorhandene Datei nicht
truncaten kann.

Das aktuelle Produktionsimage enthält `fsh`, die genannten Textprogramme und
eine interne Rust-ABI in `crates/kernel-abi/`. Nach dem Rust-Port-Release ist diese
Reihenfolge geplant:

1. FlashSDK als schmalen öffentlichen Syscall-/Userspace-ABI-, EL0-Runtime-,
   Basisbibliotheks- und Target-/Link-Vertrag erstellen und aktivieren;
2. FlashShell zum ersten echten FlashSDK-Produkt-Consumer machen;
3. FlashUI als zweiten Consumer und native TUI bauen, die FlashShell einbettet;
4. den Standardpfad auf `PID 1 → login → flashui` umstellen und `/bin/fsh` als
   getestete Recovery-Shell behalten.

Kernel-private Records wie `TaskStruct`, Registerframes und VFS-/fd-Interna
werden nicht öffentlich, nur weil sie heute neben Syscall-Typen in
`crates/kernel-abi/` liegen. FlashSDK versioniert unabhängig als 0.x-Vertrag; erst der
FlashOS-v1.0-Stabilitätsschnitt ist ein dauerhaftes ABI-Versprechen.

## 5. Syscalls und Exceptions

EL0-Wrapper legen die Syscall-Nummer in `x8`, Argumente in `x0..x5` und führen
`svc #0` aus. `arch/aarch64/entry.S` speichert einen 272 Byte großen
`KeRegs`-Frame, weist `x8 >= 56` ab und verzweigt durch die relocierte Tabelle
aus `crates/kernel/src/sys.rs`.

| Slots | Oberfläche |
| :---- | :--------- |
| 1–13 | Prozesslebenszyklus, Free-Page-Debug, File-Open/Seek, Heap |
| 18 | anonyme Pipe |
| 25–26, 30 | Konsolenmodus, reserviertes Close, Test-Input-Injection |
| 31 | pfadauflösendes ELF-`execve` |
| 32–35 | `read`, `write`, `close`, `dup2` |
| 36–38, 48 | CWD, indiziertes `readdir`, Kernel-Log, `getcwd` |
| 39–47 | Credentials, Authentifizierung, Passwortänderung, Reboot |
| 49–52 | Gesamtspeicher, Uptime, CPU-Temperatur und -Frequenz |
| 53–55 | FAT32-Create, -Unlink und -Rename |

Die Slots 0, 5, 8, 9, 11, 23, 24 und 27–29 sind stillgelegt und liefern
dauerhaft einen Fehler; 14–17 und 19–22 sind reservierte Stubs. ABI-Definitionen,
`NR_SYSCALLS = 56`, `Dirent` und `EACCES = 13` liegen im FlashSDK-Crate
`flashsdk-abi`, das an einer fixierten Revision eingebunden wird.

Synchrone Faults dekodieren ESR und Fault-Adresse im Board-IRQ-/Exception-Pfad.
Behandelbare User-Translation-Faults übernimmt
`crates/kernel/src/mm_user.rs`; terminale ungültige Entries drucken
`ERROR CAUGHT`, was der Watchdog als harten Fehler wertet.

Der Kernel-Log ist ein 16-KiB-Overwrite-Oldest-Byte-Ring. `main_output` spiegelt
Kernelmeldungen hinein; `klog_read` liefert für `/bin/dmesg` einen Snapshot,
ohne Daten zu konsumieren.

## 6. Kernel-Symbole und Tracing

### Symboltabelle

Das gelinkte Image reserviert exakt 128 KiB für `_symbols`.
`xtask/src/syms.rs` kodiert jedes gefilterte Symbol als 64-Byte-Eintrag aus
Adresse und Name und hängt einen Null-Sentinel an. Zu lange Namen und eine
Tabelle oberhalb der festen Section-Größe werden abgewiesen.

Der `build`-Helper führt aus:

1. Kernel-Link mit dem aktuellen Platzhalter oder der Tabelle;
2. `cargo xtask populate-syms --board rpi4b`, das neu linkt, `kernel8.elf` mit
   dem gepinnten `llvm-nm` liest, Mapping- und Runtime-Aliase filtert und
   `crates/kernel/generated/symbol_area.S` neu schreibt;
3. finaler Link;
4. `nm`-Vergleich als Beleg der konvergierten Symboladressen.

Die feste Section-Größe verhindert, dass ihre Befüllung spätere Sections
verschiebt.

### Function-Entry-Tracing

`arch/aarch64/trace/patchable_trampolines.S` stellt je zwei patchbare NOPs für vier
kanonische Entries bereit: `kernel_main`, `_schedule`, `do_wait` und
`copy_process`. Der Bring-up relocatet ihre Linkertabelle, patcht den ersten
Slot zur LR-Sicherung und den zweiten als Branch zu `hook`. Der Hook löst den
Entry über ksyms auf und schreibt den Namen auf die PL011-Trace-UART.

Dieser Tracer gehört zum normalen Kernel. Das Runtime-Szenario `trace` führt
Fork, Scheduling, Exit und Wait durch die Trampolines und prüft die übliche
Page-Balance.

### Statistischer Sampler

`cargo xtask build --board rpi4b --trace` kompiliert zusätzlich den IRQ-Sampler.
Dasselbe Flag definiert `FLASHOS_TRACE` für `entry.S`, sodass der IRQ-Entry den
gespeicherten `KeRegs`-Pointer in `x0` übergibt. Der Sampler emittiert höchstens
einen Mini-UART-Backtrace pro Sekunde, enthält immer den unterbrochenen PC und
läuft nur über Frame Records innerhalb der aktuellen Kernel-Stack-Page.
Interrupts aus EL0 werden als User-Samples markiert; ein nicht vertrauenswürdiger
User-Stack wird nicht durchlaufen.

## 7. Tests und Release-Gates

### Hosttests

`cargo xtask test` führt die Workspace-Hosttests aus und schließt nur die zwei
Bare-Metal-Static-Libraries aus, die nicht als Host-Binaries linkbar sind. Am
aktuellen Tree-Stand findet der Befehl **746 Rust-Tests**. Seine eigene Ausgabe
bleibt die maßgebliche Testzahl.

Die Abdeckung umfasst:

- ABI-Layout und Syscall-Grenzen;
- Page-Allokation, User-Faults, Fork, Scheduling und Wait Queues;
- VFS, Initramfs, FAT32, Descriptors, Pipes, Konsole und Kernel-Log;
- ELF, Path-Normalisierung, Berechtigungen, Overlays, Account- und
  Shadow-Parsing;
- SHA-256, HMAC, PBKDF2, Entropiemischung, Mailbox-Daten und USB-Helper;
- Shell-Tokenisierung, Readline, Completion, Pager, Gap Buffer und User-Tools;
- `xtask`-Generatoren, Command-Parsing und Artefakt-Guards.

### Runtime-Harness

Mit `--boot-selftest` führt `userland/init/pid1/src/harness.rs` exakt **30
EL0-Szenarien** aus:

| Bereich | Szenarien |
| :------ | :-------- |
| Prozesse und Speicher | `fork-stress`, `oom-graceful`, `kill`, `brk`, `stack-overflow`, `wild-pointer`, `exec-fault`, `undef-instr`, `efault-syscall` |
| ELF und ABI | `exec-elf`, `execve`, `flibc`, `trace` |
| I/O und Dateisysteme | `pipe`, `console-echo`, `fd-redirect`, `initramfs-open`, `vfs-dispatch`, `fs-roundtrip`, `fs-empty`, `readdir`, `klog` |
| Hardwaredaten | `rng`, `hwmon-core`, `hwmon-mailbox` |
| Identität | `creds`, `authenticate`, `perm`, `login`, `passwd` |

Jedes Szenario emittiert genau ein `[TEST]` und ein `[PASS]` oder `[FAIL]` und
prüft danach die Free-Page-Baseline. FAT32-abhängige Legs melden einen
ausdrücklichen erfolgreichen Skip, wenn `/mnt` nicht verfügbar ist.

### QEMU-Watchdog-Vertrag

`run watchdog rpi4b` baut mit `--boot-selftest --ci-login-seed`, erzeugt
`rust-out/test_sd.img` und bootet QEMU mit einer Obergrenze von 720 Sekunden.
Ein grüner Lauf verlangt:

- `30/30 passed`;
- kein `[FAIL]` und kein `ERROR CAUGHT`;
- 34 User-Checkpoints bei `0xbbff1`;
- einen Boot-Checkpoint vor PID 1 bei `0xbc000`;
- genau eine gesunde Entropie-Ankündigung und keinen Entropie-Selftest-Fehler;
- einen exakten `elf hello`-Marker;
- drei `type 'help' for commands`-Shell-Marker.

Der erhaltene, eingefrorene `virt`-Matcher notiert derzeit `0x3be4f` für den
User-Checkpoint und `0x3be5e` für den Boot-Checkpoint. Solange `virt`
eingefroren bleibt, sind diese Werte kein aktives Release-Gate.

### Statische Gates

CI führt außerdem aus:

- `cargo fmt --all --check`;
- Workspace-Clippy mit verbotenen Warnings;
- `cargo xtask check-hygiene`;
- Build und Inspektion jedes ausgelieferten EL0-Payloads;
- `cargo xtask asm-defs --check`;
- `cargo xtask census`;
- `cargo xtask guard --board rpi4b --full`;
- den rpi4b-Watchdog.

Der Full-Guard führt den Produktions-Build hinter ablehnenden Command-Shims
aus und prüft danach seinen Subprozess-Trace. Die Artefaktprüfung verlangt
null undefined Symbols, null `core::fmt` und null FP/SIMD-Instruktionen.

### Reine Hardware-Akzeptanz

Das exakte Release-`kernel8.img` und `armstub8.bin` müssen zusätzlich auf
einem Raspberry Pi 4B booten. Die Hardware-Akzeptanz umfasst:

- den Login-zu-Shell-Pfad;
- EMMC2-Block-Read/-Write;
- persistenten FAT32-Roundtrip über zwei Boots;
- Create/Write/Read/Rename/Unlink auf der echten Karte;
- USB-C-CDC-ACM-Enumeration und Konsolen-Fallback;
- optionalen PL011-Trace-Capture für ein Trace-Image.

Eine SD-Karte zu flashen oder zu überschreiben bleibt eine ausdrückliche
Operator-Aktion; ohne `build -d` deployt der Build nichts.

## 8. Build-Artefakte

| Pfad | Beschreibung |
| :--- | :----------- |
| `rust-out/rpi4b/kernel8.img` | rohes Produktionsimage für die Pi-Firmware |
| `rust-out/rpi4b/kernel8.elf` | ungestripter gelinkter Kernel zur Inspektion |
| `rust-out/rpi4b/armstub8.bin` | roher Pi-EL3→EL1-Armstub |
| `rust-out/rpi4b/armstub8.elf` | gelinkter Armstub |
| `rust-out/initramfs-bin/initramfs.cpio` | deterministisches newc-Archiv |
| `rust-out/initramfs-stage/` | exakt in das Archiv kodierter Dateibaum |
| `rust-out/user/*.unstripped.elf` | ungestripte EL0-Artefakte |
| `rust-out/test_sd.img` | generierte QEMU-FAT32-Fixture |

`target/` ist Cargos Compilation-Cache; `rust-out/` ist der zusammengesetzte
Produktbaum. `cargo xtask clean` entfernt beide.

---

[← Zurück: README](README.md) · [Weiter: Setup →](SETUP.md)
