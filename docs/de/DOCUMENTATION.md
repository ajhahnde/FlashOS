<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/flashos_logo_dark.png">
    <img src="../../assets/flashos_logo_light.png" alt=".flashOS" width="280">
  </picture>

<h1>Dokumentation</h1>

<p><i>Wie Boot-Pfad, Memory-Layout, Scheduler, Syscalls, IRQs, Tracing und Test-Harness zusammenspielen.</i></p>

<p>
    <a href="README.md"><b>README</b></a> ·
    <b>Dokumentation</b> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="../../PORT.md"><b>Port</b></a> ·
    <a href="../../VERSIONING.md"><b>Versionierung</b></a> ·
    <a href="../../CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="../../LICENSE.md"><b>Lizenz</b></a>
  </p>

<p>
    <a href="../../DOCUMENTATION.md">English</a> ·
    <b>Deutsch</b>
  </p>
</div>

---

> **Board-Hinweis.** `-Dboard=rpi4b` ist das validierte Board. Das QEMU-Target
> `-M virt` wurde seit
> [v0.5.0](https://github.com/ajhahnde/FlashOS/releases/tag/v0.5.0) depriorisiert
> — dem letzten Release, das nachweislich damit bootet — und ist nicht mehr
> CI-gegatet. Die Per-Board-Beschreibungen weiter unten dokumentieren es
> weiterhin, aber spätere Releases können regrediert sein.

## Inhalt

1. [Source-Layout](#1-source-layout)
2. [Boot-Pfad](#2-boot-pfad)
3. [Memory-Management](#3-memory-management)
4. [Prozessverwaltung &amp; Scheduling](#4-prozessverwaltung--scheduling)
5. [Syscalls &amp; Exceptions](#5-syscalls--exceptions)
6. [Kernel-Symboltabelle (ksyms)](#6-kernel-symboltabelle-ksyms)
7. [Tracing](#7-tracing)
8. [Testen](#8-testen)
9. [Build-Artefakte](#9-build-artefakte)

## 1. Source-Layout

```text
arch/aarch64/                               AArch64 ISA core (assembly + shared asm macros)
  boot.S                                    _start, EL3→EL1, MMU bring-up, jump to high VAs
  entry.S                                   Exception vector table + syscall dispatch
  utils.S, mm.S                             Assembly helpers
  sched.S, irq.S                            Context switch + IRQ enable/disable
  generic_timer.S                           CNTP system register helpers
  asm_defs.inc                              Bridge header — pulls in board_asm_defs.inc
  asm_defs_common.inc                       Shared assembler-only macros (board-independent)

src/                                        Kernel core (Flash modules + Zig drivers)
  start.zig                                 Build root: comptime-imports every kernel module
  kernel.flash                              kernel_main + bring-up
  symbol_area.S                             Generated kernel symbol table (see §6)
  board.flash                               Comptime alias: build_options.board → board/<board>/*
  generic_timer.flash                       ARM generic timer
  page_alloc.flash                          Physical page allocator
  mm_user.flash                             map_page, copy_virt_memory, do_data_abort
  fork.flash                                copy_process, prepare_move_to_user[_elf]
  sched.flash                               Priority round-robin scheduler
  wait_queue.flash                          Blocking-syscall wait queue
  sys.flash                                 Syscall table + handlers
  execve.flash                              sys_execve — ELF load over the VFS + argv staging
  utilc.flash                               memcpy/memset/panic + main_output helpers
  klog_ring.flash                           Kernel byte-ring backing klog_read / dmesg
  console.flash                             Console RX ring + line input
  pipe.flash                                Anonymous pipe ring
  fdtable.flash                             Per-task fd table (install / get / dup)
  file.zig                                  File-handle pages (offset cursor over a SuperBlock)
  elf.flash                                 ELF64 header + program-header parser (host-testable)
  task_layout.flash                         Canonical extern-struct layouts (TaskStruct, MmStruct, …)
  user_layout.flash                         User VA constants (TEXT/DATA/HEAP/STACK bases + flags)
  perm.flash                                Owner/mode permission check (host-testable)
  path.flash                                joinResolve — path join + ./.. collapse (host-testable)
  pwfile.flash                              /etc/passwd line parser (host-testable)
  shadow.flash                              Shadow-db line parser (host-testable)
  sha256.flash                              SHA-256 + PBKDF2-HMAC + ctEql (host-testable)
  hwrng.flash                               Kernel entropy source (salt minting)
  block_dev.flash                           BlockDev vtable: board-agnostic LBA read/write indirection
  sdhci_cmd.flash                           SDHCI CMDTM bit layout, CMDx constants, CSD v2 parser, clock divisor
  mailbox.flash                             VideoCore property-tag message layout + parsing (board-agnostic)
  vfs.zig                                   1-bit-superblock VFS dispatch layer
  initramfs.flash                           Read-only initramfs image decode (host-testable)
  initramfs_backend.flash                   initramfs VfsOps backend (read-only)
  fat32.flash                               FAT32 BPB/FAT/dir-entry decode + cluster-chain walk (host-testable)
  fat32_backend.flash                       FAT32 VfsOps backend: read + writeBack over block_dev (real SD I/O — Pi-HW path)
  overlay.flash                             FAT32 permission-overlay parser (/mnt/PERMS.TAB)
  usb_descriptors.flash                     USB CDC-ACM descriptor set + SETUP-packet decode (host-testable)
  usb_tx_ring.flash                         Bounded TX byte ring for the DWC2 CDC-ACM bulk-IN path (host-testable)

  board/rpi4b/                              Raspberry Pi 4 driver bag
    uart.flash                              Mini-UART driver (console)
    gpio.flash                              GPIO pin function/enable
    timer.flash                             BCM2711 system timer
    irq.flash                               BCM2711 GIC + dispatch + invalid-entry reporter
    emmc2.flash                             BCM2711 EMMC2 SDHCI driver — PIO single-block read/write
    mailbox.flash                           VideoCore mailbox MMIO doorbell (pairs with src/mailbox.flash)
    power.flash                             Mailbox-driven power/reset (reboot)
    usb.flash                               BCM2711 DWC2 USB-OTG device (gadget) — CDC-ACM console
    boot_quirks.S                           Pi-specific boot fixups
    board_asm_defs.inc                      Pi memory-layout addresses + macros
    linker.ld                               Per-board kernel link script

  board/virt/                              QEMU `-M virt` driver bag
    uart, gpio, timer, irq.flash            (virt MMIO addresses)
    emmc2, mailbox, power.flash             (board-API parity with rpi4b)
    dtb.flash                               Minimal DTB walker for runtime device-address discovery
    usb.flash                               No-op USB gadget stub (board-API parity with rpi4b)
    image_header.S                          Linux arm64 image header (UEFI/GRUB compatibility)
    boot_quirks.S                           virt-specific boot fixups
    board_asm_defs.inc                      virt memory-layout addresses + macros
    linker.ld                               virt kernel link script

  trace/
    trace_main.zig                          Patchable-entry tracing
    sampler.zig                             Sampling-profiler driver
    fp_walk.zig                             Frame-pointer stack walker
    utils.zig                               Trace I/O helpers (PL011)
    ksyms.zig                               Kernel symbol table lookup
    pl011_uart.zig                          Dedicated PL011 trace UART driver
    hook.S                                  Trace hook stub (saves regs, calls 'traced')
    patchable_trampolines.S                 Patchable per-function entry trampolines

user_space/
  init_main.flash                           PID 1 ELF root (staged at /sbin/init)
  kernel_tests.flash                        In-kernel test harness ([TEST]/[PASS]/[FAIL])
  etc/                                      Seed identity files staged into the initramfs
    passwd                                  Account database (name:uid:gid:…)
    perms.tab                               Initramfs permission table (owner/mode)
  fsh/                                      Flash shell
    fsh.flash                               Interactive shell main
    tokenize.flash                          Command-line tokenizer
    fshrc                                   Default shell rc
  lib/flibc/                                Userland mini-libc for ELF-loaded programs
    flibc.flash                             Root re-exports (printf, malloc, fork, ...)
    start.flash                             ELF entry crt0 (argv unpack → main → exit)
    syscalls.flash                          Raw SVC wrappers (sys.write/fork/exit/...)
    io.flash                                printf / puts / write on sys_writeConsole
    heap.flash                              Bump allocator over sys_brk / sys_sbrk
    mem.flash                               memcpy / memset / memcmp
    process.flash                           fork / wait / exit / execve glue
    execvp.flash                            PATH search + execve
    readline.flash                          Line editor (history, cursor edit)
    completion.flash                        TAB completion
    keys.flash                              Key decode (escape sequences → keycodes)
    gapbuf.flash                            Gap buffer (editor backing store)
    pager.flash                             Scroll pager (less core)

lib/
  syscall_defs.flash                        Shared SYS_* IDs (kernel + user side)
  console_ui/                               Shared console-UI rendering (kernel + user)
    console_ui.flash                        Logger sink + level/tag formatting
    palette.flash                           ANSI color palette
    tags.flash                              [ OK ] / [FAIL] / … status tags
    screen.flash                            Screen + cursor control sequences

tools/                                      Hand-rolled ELF programs (coreutils + [TEST] fixtures)
  ls, cat, cp, mv, rm, grep, echo, clear    coreutils (coreutil_linker.ld)
  edit, less, login, passwd, dmesg          interactive + identity tools
  cpuinfo, meminfo, sysinfo, uptime         system-info readers
  hello.flash, stackbomb.flash              [TEST] exec-elf / stack-overflow fixtures
  flibc_demo, argv_echo, forkbomb           flibc / argv / fork [TEST] fixtures
  grep_match.flash                          grep match engine (host-testable)
  gen_shadow.zig                            Host tool: mint the seed shadow db
  initramfs.S                               Embeds the staged initramfs image
  *_linker.ld                               Per-program PT_LOAD layouts

tests/
  host_stubs.zig                            Shared linker stubs for 'zig build test'
  host_stubs_sched.zig                      Sched-test HW-side stubs
  host_stubs_fork.zig, fork_stubs.zig       Fork-test stubs
  host_stubs_mm_user.zig                    mm_user-test stubs
  host_stubs_utilc.zig                      utilc-test stubs
  host_stubs_initramfs.zig                  File/initramfs stubs (typed `current`)
  host_stubs_vfs.zig                        VFS-test stubs
  host_alloc.zig                            Host allocator shim for unit tests

armstub/src/
  armstub8.S                                EL3→EL1 bootstrap shim
  asm_defs.inc                              Armstub-only assembler macros
  linker.ld                                 Armstub link script (.text at 0)
  root.zig                                  Empty Zig root (build API requirement)

scripts/
  clear_syms.zig                            Reset src/symbol_area.S to its placeholder form
  generate_syms.zig                         Read 'aarch64-elf-nm' and emit src/symbol_area.S
  make_iso.sh                               GRUB-EFI rescue ISO builder (virt only)

assets/                                     Logo and visual assets

build.zig                                   The only build entry point
flashos.zsh                             Shell helpers incl. the two-pass `build` orchestrator
config.txt                                  RPi 4 firmware configuration
```

## 2. Boot-Pfad

1. Der GPU-Bootloader lädt `armstub8.bin` und `kernel8.img` in den RAM
   und startet die Cores auf EL3.
2. `armstub/src/armstub8.S` konfiguriert die Secure-Mode-Register, aktiviert
   den GIC und `eret`et nach EL1.
3. `_start` (`arch/aarch64/boot.S`) setzt den Stack, löscht `.bss`, baut die
   Identity- und High-Page-Tables auf, weckt die Secondary-Cores,
   initialisiert `TCR_EL1` / `MAIR_EL1` / `VBAR_EL1` / `TTBR0` / `TTBR1`
   explizit (erforderlich für QEMU; auf echter Hardware lässt armstub
   diese in einem sinnvollen Zustand), aktiviert die MMU mit einem `ISB` nach
   `SCTLR.M=1` und springt via das High-Virtual-Mapping nach
   `kernel_main`.
4. `kernel_main` (`src/kernel.flash`) initialisiert die Mini-UART, die
   PL011-Trace-UART, den GIC, die Kernel-Symboltabelle, die Syscall-Tabelle
   und den Generic Timer, forkt dann PID 1 und tritt in die
   Scheduler-Loop ein.
5. PID 1 (`kernel_process`) liest `/sbin/init` — das im eingebetteten
   initramfs bereitgestellte `pid1.elf`-Image — und übergibt seine Bytes an
   `prepare_move_to_user_elf`, das die PT_LOAD-Segmente durchläuft,
   jedes mit per-Region-Permissions mappt, die oberste Stack-Page eager
   mappt und zum ELF-Entry-Point `eret`et.
6. `user_space/init_main.flash` ist der `pid1.elf`-Root: `_start`
   ruft `pid1_main` auf, das `run_all()` aus
   `kernel_tests.flash` ausführt. Die Harness durchläuft die dreißig Szenarien
   und gibt einen `X/Y passed`-Tally aus, übergibt PID 1 dann an `/bin/login`:
   das Login-Gate authentifiziert gegen `/etc/shadow`,
   droppt Privilegien gemäß `/etc/passwd` und exect die Shell des Users —
   der Boot endet am interaktiven Shell-Prompt (§4).

## 3. Memory-Management

Ein vierstufiges Übersetzungsregime: PGD → PUD → PMD → PTE, 4-KiB-Pages.

### Physisches Layout (RPi 4, 4-GiB-SKU)

| Range                      | Region           | Nutzung                          |
| :------------------------- | :--------------- | :------------------------------- |
| `0x00000000`–`0x38400000`  | 0 – 948 MiB      | Frei / Kernel-Image bei `0x80000` |
| `0x38400000`–`0x40000000`  | 948 – 1024 MiB   | VideoCore reserviert             |
| `0x40000000`–`0xFC000000`  | 1 GiB – 3960 MiB | `get_free_page`-Pool             |
| `0xFC000000`–`0x100000000` | > 3960 MiB       | MMIO (GIC, UART, GPIO)           |

### Virtuelles Kernel-Layout (EL1)

| Region       | Virtuelle Basis      | Physische Basis | Attribute            |
| :----------- | :------------------- | :------------ | :------------------- |
| Identity-Map | `0x0000000000000000` | `0x00000000`  | Normal-NC (0–16 MiB) |
| Linear high  | `0xffff000000000000` | `0x00000000`  | Normal-NC            |
| VC-Hole      | `0xffff00003B400000` | `0x38400000`  | unmapped             |
| RAM high     | `0xffff000040000000` | `0x40000000`  | Normal-NC            |
| Device high  | `0xffff0000FC000000` | `0xFC000000`  | Device-nGnRnE        |

Die Übersetzung zwischen physisch und dem Linear-High-Mapping nutzt
`PA_TO_KVA` / `KVA_TO_PA` aus `src/mm_user.flash`.

### Virtuelles User-Layout (EL0)

Die Konstanten sind in `src/user_layout.flash` definiert (Zig-autoritativ,
importiert von sowohl `src/fork.flash` als auch `src/mm_user.flash`).

| Region | Virtuelle Basis      | Richtung       | Attribute (post-Loader)  |
| :----- | :------------------- | :------------- | :----------------------- |
| Text   | `0x0000000000000000` | statisch       | RWX (kein UXN, kein RO-Bit) |
| Data   | `0x0000000000100000` | statisch       | RW- (UXN)                |
| Heap   | `0x0000000000200000` | wächst hoch (brk) | RW- (UXN)             |
| Stack  | `0x00000FFFFFFFF000` | wächst runter  | RW- (UXN), Guard darunter |

Text ist heute RWX gemappt: das Default-Page-Bag des Loaders gewährt EL0
Read/Write und löscht UXN, und es ist kein Read-only-(AP[2])-Descriptor-Bit
definiert, sodass W^X für User-Code noch nicht erzwungen wird. Data, Heap und
Stack fügen UXN für RW-NX hinzu.

Der 16-TiB-Gap zwischen `HEAP_BASE` und `STACK_TOP` macht den Heap-/
Stack-Guard implizit — jeder Zugriff in diesem Bereich ist ein Wild Pointer
und `do_data_abort` paniced mit `[KERN] invalid uva at 0x<hex>`, nachdem der
verursachende Task zombified wurde (das `sys_wait` des Parents reapt wie
gewohnt). Die Region-Klassifizierung stützt sich auf `mm.brk` plus die
statischen Layout-Konstanten in `src/user_layout.flash`; siehe `do_data_abort`
in `src/mm_user.flash` für den vollständigen Dispatch.

Die Per-Region-Attribute (Text RX, Data/Heap/Stack RW mit UXN) gelten jetzt
universell, da PID 1 ELF-geladen aus dem initramfs kommt:
`prepare_move_to_user_elf` (`src/fork.flash`) mappt jedes PT_LOAD-Segment
mit aus `p_flags` abgeleiteten Flags, und `do_data_abort`
(`src/mm_user.flash`) stempelt demand-allokierte Heap- und Stack-Pages
mit `TD_USER_PAGE_FLAGS_DEFAULT | TD_USER_XN`. Der Nicht-ELF-Blob-Pfad
(`prepare_move_to_user`) trug den ausgemusterten Blob-Loader und hat keinen
lebenden Caller mehr; jeder Task ist heute ELF-geladen mit
Per-Region-Attributen.

### User-Pages

`map_page` durchläuft (und allokiert lazy) die PGD/PUD/PMD/PTE-Tables für
den Ziel-Task und schreibt dann eine Leaf-PTE mit dem übergebenen Permission-Bag
(`user_layout.TD_USER_PAGE_FLAGS_DEFAULT` für den historischen
Combined-Permission-Stempel; der ELF-Loader wählt Per-Region-Werte).
`allocate_user_page` ist der Convenience-Wrapper, der zusätzlich eine
frische physische Page aus `get_free_page` zieht. Translation-Faults
(`dfsc == 0x4..0x7`) gehen in `do_data_abort`, das nach Region dispatcht:

| Fault-UVA-Range                       | Aktion                                                |
| :------------------------------------ | :---------------------------------------------------- |
| `[HEAP_BASE, current.mm.brk)`         | Demand-allokieren (RW+UXN); OOM → `[KERN] OOM` + zombie |
| `[STACK_LOW, STACK_TOP)`              | Demand-allokieren (RW+UXN); OOM → `[KERN] OOM` + zombie |
| `[STACK_GUARD_LOW, STACK_GUARD_HIGH)` | Panic `stack overflow` + Task zombifizieren           |
| `[TEXT_BASE, DATA_BASE)`              | Panic `text fault` + Task zombifizieren               |
| alles andere                          | Panic `invalid uva` + Task zombifizieren              |

Jeder Task ist ELF-geladen: PID 1 plus die
`{hello,stackbomb,flibc_demo}.elf`-Payloads unter `/test/` respektieren
ihre Link-Time-`p_vaddr`, sodass absolute Pointer, Switch-Jump-Tables
und Arrays-of-Pointers alle korrekt auflösen. Der ausgemusterte Blob-Loader,
der ein Nicht-ELF-Image ungeachtet seiner Link-Time-Adresse auf UVA `0`
kopierte, existiert nicht mehr.

### Out-of-Memory-Policy

`get_free_page` gibt bei Erfolg die Page-PA zurück, **`0` bei Erschöpfung**
(`src/page_alloc.flash`). `0` ist ein eindeutiges Sentinel. Der Pool beginnt
bei `MALLOC_START` (`0x40000000`), sodass keine lebende Allokation je PA 0 ist.
`get_kernel_page` propagiert es als rohe `0` (nie `pa_to_kva(0)`,
was eine gültig aussehende KVA wäre und das Failure verstecken würde). Jede
Allokationsstelle prüft `== 0` und lässt ihre Operation sauber fehlschlagen,
statt den Kernel abzubrechen:

- `mm_user.map_page` gibt bei einem Allokationsfehler mitten im Walk `-1`
  zurück und rollt jede intermediäre PGD/PUD/PMD/PTE-Table zurück, die es in
  diesem Call erstellt hat (sodass das Failure page-balance-neutral ist), und
  schreibt **niemals** einen Descriptor, der PA 0 mappt. `allocate_user_page`
  gibt die verwaiste User-Page frei, wenn das nachfolgende `map_page`
  fehlschlägt.
- `fork.copy_process` gibt das teilweise oder vollständig aufgebaute Child-mm
  frei (`sched.release_user_mm`) auf beiden Failure-Pfaden — einem
  `copy_virt_memory`-Failure und Task-Slot-Erschöpfung — bevor es die
  TaskStruct-Page freigibt.
- `pipe` / `file` / `openFile` / `exec` verwandeln eine Allokations-`0` in ein
  Syscall-`-1` (siehe §5).

Zwei Fault-Pfade behalten eine Prozess-Level-Reaktion statt eines
Syscall-Return:

- **Fault-Context-Demand-Alloc** (`do_data_abort`, Heap/Stack) ist nicht
  recoverable — die faultende Instruktion kann ohne die Page nicht fortsetzen.
  Bei Erschöpfung emittiert es `[KERN] OOM at 0x<hex>` (der
  `stack overflow` / `text fault` / `invalid uva`-Marker-Familie beitretend) und
  zombifiziert den Task via `exit_process`; das `sys_wait` des Parents reapt.
- **`execve` / `exec` post-Teardown**-OOM: der Address-Space des Callers ist
  bereits weg (`pgd == 0`), sodass ein Loader-`-1` jenseits des Point of No
  Return `[KERN] OOM` emittiert und ihn zombifiziert (ein kontrollierter
  Zombie), den Fault-Pfad spiegelnd.

Der **Soft**-Pfad ist das Gegenteil: `copy_from_user` / `copy_to_user`
prefaulten durch `mm_user.soft_demand_alloc`, das bei Erschöpfung `-1`
zurückgibt **ohne** `exit_process` — ein Syscall, dem eine Heap-/Stack-Adresse
übergeben wurde, die nicht gebacked werden kann, schlägt sauber fehl und der
Task überlebt.

Unter den aktuellen Caps ist echte Pool-Erschöpfung aus dem Userland
unerreichbar (`MAX_PAGE_COUNT * NR_TASKS` capt alle lebende User-Memory bei
8 MiB gegen einen ~3-GiB-Pool), sodass der Sentinel-Kontrakt von der
Host-Test-Suite (`page_alloc`, `mm_user`, `sched`, `fork`) statt in-kernel
ausgeübt wird. Es gibt noch kein `free()` / `sys_mmap` — der Allocator ist
allocate-only plus dem Per-Task-mm-Sweep beim Reap; ein General Allocator ist
v1.x.

### Kernel-residente IPC-Pages

Anonyme Pipes (`src/pipe.flash`) allokieren eine
4-KiB-Page pro `Pipe`: Header (refs + head/tail + readers/writers
Wait-Queues) vorne, Byte-Ring füllt den Rest. Die Page wird **nicht** in
`mm.user_pages` oder `mm.kernel_pages` getrackt — ihre Lebensdauer gehört
`Pipe.refs`. Fork dupt die Per-Task-fd-Table (Refcount-Bump pro geerbtem
Slot); `do_wait` ruft `pipe.closeAll(zombie)` vor dem Sweepen der mm-Pages auf,
sodass ungeschlossene fds ihre Refs sauber droppen. Dies ist heute die einzige
Kategorie von Kernel-Page, deren Lebensdauer vom Per-Task-mm-Sweep entkoppelt
ist.

Der Console-RX-Layer (`src/console.flash`) hält einen
256-Byte-Ring in BSS — keine `get_free_page`-Allokation auf dem IRQ →
Syscall-Pfad. Single Producer (IRQ-seitiges `console_push`) / Single
Consumer (`sys_read` auf einem `console`-getaggten fd) per Konstruktion auf
Single-Core; die
Per-Ring-`WaitQueue` blockiert Reader auf dem Empty-Branch und weckt
bei jedem Push.

### Eingebettetes initramfs

Das initramfs wird als `.initramfs`-Section zwischen `bss_end` und
`id_pg_dir` in beide Board-Linker-Scripts in das Kernel-Image gelinkt.
`tools/initramfs.S` trägt ein `.incbin "initramfs.cpio"`
zwischen den Labels `__initramfs_start` / `__initramfs_end`; der Build
stellt `pid1.elf` bei `/sbin/init` und `hello.elf` / `stackbomb.elf`
/ `flibc_demo.elf` bei `/test/*.elf` bereit, via den handgefertigten
`scripts/build_initramfs.zig`-Encoder über eine
sortierte Arc-Liste (fixe mtime/uid/gid/ino, sodass das Archiv eine reine
Funktion von Inhalt + Namensliste ist). `src/initramfs.flash`
exponiert einen `Iterator` + `locate(path)`-Walker über die newc-Bytes
durch den TTBR1-Alias der Section, host-getestet gegen
synthetische Fixtures. PID 1 (`kernel_process`) liest `/sbin/init` aus
diesem Archiv und übergibt es an `prepare_move_to_user_elf`; die
Harness-Szenarien erreichen `/test/{hello,stackbomb,flibc_demo}.elf`
entweder von Hand (`sys_openFile` + `sys_read`) oder durch den
path-aufgelösten Loader `sys_execve`. Das gesamte Archiv
ist read-only und lebt im Address-Space des Kernels — `File`-Handles,
die von `src/file.zig` allokiert werden, tragen einen Offset in die
Section, keine Kopie der Bytes. Die File-Syscalls erreichen dieses Archiv
durch den VFS-Shim (nächster Unterabschnitt) statt `initramfs.locate` direkt
aufzurufen; PID 1s `kernel_process` ist der eine verbleibende direkte Caller,
weil es läuft, bevor der Syscall-Pfad verdrahtet ist.

### Filesystem-Layout (VFS-Shim)

`src/vfs.zig` ist ein 1-Bit-Superblock-Dispatch-Layer,
der zwischen den File-Syscalls und den Storage-Backends sitzt. Er besitzt
eine fixe Zwei-Slot-Mount-Table und routet jeden Pfad nach Prefix:

| Pfad-Prefix     | Slot | Backend                                  |
| :-------------- | :--: | :--------------------------------------- |
| `/mnt/…`        |  1   | FAT32 —`src/fat32_backend.flash`         |
| alles andere    |  0   | initramfs —`src/initramfs_backend.flash` |

initramfs ist der Root `/`; FAT32 mountet bei `/mnt` (das System bootet immer
noch, wenn die SD-Karte unlesbar ist). Der EMMC2-Treiber
(`src/board/rpi4b/emmc2.flash`) ist **auf echter Pi-4-Hardware verifiziert**:
init + write_block + read_block + Byte-
Vergleich alle grün gegen eine 64-GB-SDXC formatiert als FAT32 (MBR, Name
`BOOT`), Pi bootet FlashOS von EMMC2 mit entferntem Toshiba-USB.
Der erste Real-Card-Run deckte einen Treiber-Bug auf — write_block und
read_block pollten `BUFFER_WRITE_READY`/`BUFFER_READ_READY`
vor jedem 32-Bit-Word; diese Interrupts feuern einmal pro Block auf dem
BCM2711-Arasan-Controller. Die Loop wartet jetzt einmal, burstet alle 128
Words durch `DATAPORT` und wartet dann auf `DATA_DONE` (das kanonische
SDHCI-Single-Block-PIO-Pattern).

Der `/mnt`-Slot wird vom echten
`src/fat32_backend.flash` gebacked (es ersetzte `fat32_stub.zig`): `fat32.flash`
dekodiert das BPB / FAT / Root-Dir bei `init()`, und die
`open` / `read` / `seek` / `close` / `write` / `create` / `unlink` /
`rename` des Backends durchlaufen und mutieren die Cluster-Chain über
`block_dev.sd_dev`. `create` / `unlink` / `rename` sind die
File-Metadaten-Operationen (Syscalls 53–55): create findet oder erweitert einen
freien 8.3-Directory-Slot und stempelt einen leeren Eintrag, unlink tombstoned
den Eintrag (`0xE5`) und gibt seine Chain frei, rename schreibt den 8.3-Namen
in place um. Nur Files und (für rename) nur im selben Directory;
Sub-Directory-Erstellung und Cross-Directory-Move sind Future Scope. On-Device-
Source-Files nutzen die 3-Zeichen-Extension `.fl` statt `.flash` (`.flash` ist
5 Zeichen und passt nicht in einen 8.3-Short-Name, den `fat32.encode8_3`
ablehnt); es gibt kein LFN. **Das On-Disk-Layout** entspricht
`scripts/format_sd.sh`: eine einzelne MBR-Primary-Partition, Typ `0x0c`
(FAT32-LBA), beginnend bei **LBA 2048**, gelabelt `BOOT`, die ganze
Disk umspannend. Der Pi-HW-Acceptance-Run seedt zwei Files in den FAT32-Root
vor `picapture`: `ROUNDTR.DAT` (4 KiB Nullen) und `ROUNDTR.MAG`
(1 Byte Null) — 8.3-Short-Names (`fat32.encode8_3` lehnt einen
Basenamen länger als 8 ab). `[TEST] fs-roundtrip` nutzt `ROUNDTR.MAG` als den
Boot-zu-Boot-Zeugen und faltet (auf einem gemounteten Boot) ein CRUD-Bein ein,
das ein Scratch-File erstellt, schreibt, zurückliest, umbenennt und unlinkt
(`CRUD.FL` → `CRUD2.FL`) innerhalb des einen Boots — die
create/unlink/rename-ABI End-to-End ausübend, während die Disk unverändert
bleibt, sodass der Szenario-Tally unbewegt bleibt (eine ungezählte
`[DBG] fs-crud OK …`-Zeile markiert das Bein in einem Pi-Capture).

**Kein QEMU-Gate übt den echten SD-/FAT32-Write-Pfad aus.** QEMU
`-M raspi4b` modelliert die BCM2711-EMMC2/Arasan-SDHCI nicht gut
genug, um CMD8 (SEND_IF_COND) zu bestehen, sodass `board.emmc2.init()`
-1 zurückgibt und `fat32_backend.init()` nie läuft; `virt` hat by Design kein
SD-Device. Auf **beiden** QEMU-Boards nimmt `[TEST] fs-roundtrip` den
Mount-detected-SKIP-Pfad (`[PASS] fs-roundtrip (skip)`, der EL0-Tally
weiterhin 30/34), und das obige CRUD-Bein läuft nie. Der echte Variant-B-
Roundtrip (`[PASS] fs-roundtrip-write` auf Boot 1, `[PASS] fs-roundtrip`
nach einem Power-Cycle auf Boot 2), das CRUD-Bein und alle von
`fat32_backend.writeBack` / `create` / `unlink` / `rename` / `sys_write`
werden **nur auf echter Pi-4-Hardware** validiert;
`zig build test` deckt die Decode-Units von `src/fat32.flash` ab, aber nicht
`fat32_backend.flash`. Der Dispatch ist ein
einzelner `startsWith("/mnt/")`-Branch; der Trailing Slash ist
tragend, sodass `/mnt2/foo` ein initramfs-Pfad bleibt und `/mnt` ohne
Slash auch. `sys_mount`, Longest-Prefix-Matching und Pfad-Normalisierung sind
Future Work.

Jedes Backend exponiert eine `VfsOps`-vtable (`open` / `read` / `seek` /
`close` / `write` / `readdir`, C-ABI-fn-Pointer; `write` ist der 5. Slot,
`readdir` der 6.). `vfs.vfs_open` löst den Pfad auf, dispatcht an den
`open` des Backends und verstaut den backenden `SuperBlock`-Pointer in
`File.sb`; `sys_read` / `sys_write` / `sys_seek` /
`sys_close` (auf einem `file`-getaggten fd) casten diesen opaken Pointer neu
und callen zurück durch die
vtable (`vfs.vfs_write` → Backend-`write`; das FAT32-Backend
implementiert es, das initramfs-Backend gibt -EROFS zurück). Die
vtable-Einträge werden beim Bring-up zu ihren TTBR1-High-Mem-Aliases relociert
(`vfs.relocateOps`, `sys_call_table_relocate` spiegelnd), sodass das indirekte
`blr` überlebt, während es auf EL1 mit der User-pgd in TTBR0 installiert läuft.

Der `open` des Backends berichtet auch die Permission-Metadaten der Datei
(`OpenResult.mode/uid/gid`): initramfs leitet die
cpio-Header-Felder weiter, FAT32 stempelt seinen dokumentierten
`0o100666` root:root-Default. Der Syscall-Layer kopiert sie auf das
`File`-Handle und erzwingt sie — siehe §5 „VFS-Permission-Layer".

### Directory-Enumeration

`sys_readdir` (Slot 37) ist der 6. `VfsOps`-Eintrag — ein
zustandsloser `(path, index, *Dirent)`-Walk ohne `opendir`-Handle und ohne
fd-Cursor (jeder Call löst `path` frisch auf und gibt den `index`-ten Eintrag
zurück). Keiner der beiden Backing-Stores hat einen echten Directory-Inode,
sodass die zwei Backends das Listing unterschiedlich synthetisieren:

- **initramfs — aus Pfad-Prefixen synthetisiert.** Das newc-cpio-Archiv
  ist flach: es gibt keinen `/bin`-Eintrag, nur `/bin/cat`, `/bin/echo`, … Also
  leitet `readdir` das Listing aus Prefixen ab. Für Directory `path` bildet
  es ein `prefix` (der Pfad plus ein garantierter Trailing `/`; Root `/`
  bleibt `/`), durchläuft den cpio-Iterator und nimmt das einzelne
  Pfad-Segment, das `prefix` für jeden Eintrag folgt: ein direktes File-Child
  (`cat` unter `/bin/`) taucht als `DT_REG` auf; ein tieferer Eintrag steuert
  sein erstes Segment als synthetisches `DT_DIR` bei (`bin` unter `/`). Die
  Arc-Liste ist lexikographisch sortiert, sodass doppelte synthetische
  Subdirectories benachbart sind und mit einer einzigen De-Dup kollabieren.
  `ls /` → `bin`, `etc`, `sbin`, `test`; `ls /bin` → `cat`, `clear`, `cpuinfo`,
  `dmesg`, `echo`, `forkbomb`, `fsh`, `less`, `login`, `ls`, `meminfo`,
  `passwd`, `sysinfo`. Der reine `directEntry`-Helper ist host-getestet gegen
  eine Comptime-cpio-Fixture.
- **FAT32 — Root-Directory-8.3-Walk (nur Pi).** `readdir` verwendet den
  Root-Walk wieder (16 Einträge/Sektor, überspringt `0x00` End / `0xE5`
  Deleted / `ATTR_LONG_NAME` / `ATTR_VOLUME_ID` — das Volume-Label ist kein
  enumerierbarer Eintrag), rendert das 11-Byte-8.3-Feld des index-ten
  Überlebenden via das reine `fat32.decode8_3` (lowercase `name.ext`,
  Trailing-Space-Trim) und setzt `d_type` aus `ATTR_DIRECTORY`. Nur der
  Mount-Root enumeriert in diesem Release; ein Subdirectory-Listing würde einen
  Directory-Cluster-Walk brauchen (aufgeschoben — kein verschachteltes
  Directory im Demo-Image), sodass Nicht-Root-Pfade leer listen. Wie jeder
  FAT32-Pfad wird es **nur Pi-interaktiv** validiert: FAT32 mountet nicht unter
  QEMU (CMD8), sodass `vfs.resolve("/mnt/*")` null zurückgibt und `sys_readdir`
  sauber -1 zurückgibt.

Da er zustandslos ist, allokiert der Walk nichts — ein zukünftiges OOM-Audit
erbt von dieser Surface keine neue Stelle, weshalb die zustandslose Form der
POSIX-`opendir`- / fd-Cursor-Handle vorgezogen wurde (das würde ein gefaktes
Directory-`File` oder eine Scratch-Page-Allokation brauchen, beim Close
freigegeben). Die POSIX-Handle-Form ist ein zukünftiges Portable-Userland-
Revisit. Der `Dirent`-ABI-Typ ist in §5 dokumentiert.

## 4. Prozessverwaltung & Scheduling

- **Scheduler.** Priority-Round-Robin in `src/sched.flash`. `_schedule`
  wählt den runnable Task mit dem größten Counter via
  `pick_next_running`; ist der Counter dieses Tasks null (Round-Ende), ruft
  es `refill_counters` auf, das jeden Nicht-Null-Slot als
  `(counter >> 1) + priority` neu schreibt. Beide Helper sind pure und
  host-getestet.
- **Tick.** `timer_tick` dekrementiert `current.counter`. Wenn er
  null erreicht (und Preemption aktiviert ist), ruft es `_schedule`.
- **Task-States.** `TASK_RUNNING`, `TASK_INTERRUPTIBLE`, `TASK_ZOMBIE`.
- **Context-Switch.** `switch_to` aktualisiert `current`, programmiert die neue
  PGD via `set_pgd` und ruft `core_switch_to` (`arch/aarch64/sched.S`), um
  die Callee-Saved-Register, FP, SP und LR zu tauschen.
- **Fork.** `copy_process` allokiert eine Kernel-Page für den neuen Task,
  kopiert die Exception-Frame-Register des Parents, klont die
  User-Page-Table via `copy_virt_memory` und linkt ihn in `task[]`.
- **Exit / Wait.** `exit_process` ruft `zombify_and_wake_parent` auf
  `current` (Flip zu `TASK_ZOMBIE`, weckt jeden `TASK_INTERRUPTIBLE`-
  Parent). `do_wait` reapt die User-Pages, Kernel-Pages und den Slot des
  Zombies — die Page-Balance ist das Leak-Signal der Test-Harness.
- **Kill.** `sys_kill(pid)` durchläuft `task[]` nach einer passenden `.pid`
  und wendet denselben `zombify_and_wake_parent`-Helper an. Self-Kill wird
  abgelehnt — der laufende Task ist seine eigene Kernel-Page; `sys_exit` ist
  der sichere Self-Cancel-Pfad.
- **Exec.** `sys_execve(path, argv)` (Slot 31, `src/execve.flash`) ist der
  path-aufgelöste ELF-Loader. Er löst `path` durch den VFS auf, validiert
  den ELF-Header und reißt dann — jenseits des Point of No Return — den
  Address-Space des Callers ab und installiert eine frische PGD, streamt jedes
  `PT_LOAD`-Segment zu seiner Link-Time-`p_vaddr` und legt den argv-Block
  auf den neuen Stack, bevor er per `ERET` in den Entry-Point geht. Die PID
  wird über den Rebuild hinweg erhalten; ein Loader-`-1` nach dem Teardown ist
  der Controlled-Zombie-Fall (siehe die OOM-Policy oben).

### File-Deskriptor-Modell

Jeder Task trägt eine **einzige getaggte fd-Table** —
`fds: [FD_TABLE_SIZE]FdSlot` auf `TaskStruct` (`src/task_layout.flash`),
`FD_TABLE_SIZE = 8`. Sie ersetzt die zwei parallelen `?*anyopaque` /
`?*File`-Arrays (Pipes + Files), die ein früheres Design unabhängig
indizierte, plus den synthetischen Console-fd. Die Mechanik lebt in
`src/fdtable.flash` (`install` / `get` / `getPipe` / `getFile` /
`isConsole` / `close` / `dup2` / `dupAll` / `closeAll`), das
kernel- + host-testbares pures Pointer-Bookkeeping ist.

```flash
pub const Kind = enum(u8) { none = 0, console = 1, pipe = 2, file = 3 }
pub const FdSlot = extern struct {        // 16 B; 8 slots = 128 B
    ptr ?*mut anyopaque = null,           // *Pipe | *File | null (console)
    kind u8 = 0,                          // Kind; `none` == free slot
    _pad [7]u8 = .{0} ** 7,
}
```

- **Dispatch nach Tag.** `sys_read` / `sys_write` / `sys_close` (Slots
  32/33/34) switchen auf den `kind` des Slots und rufen den Per-Backend-Helper
  (aufgelöst durch `getPipe` / `getFile`). Dies ist der einzige Entry-
  Point — die früheren Per-Kind-Shims sind ausgemustert.
- **Console ist Refcount-exempt.** Ein `console`-Slot ist
  `{ ptr = null, kind = console }` — der RX-Ring und die Mini-UART-TX sind
  prozessweite Singletons ohne Per-fd-Objekt, sodass `dup2` / `close` /
  `dupAll` / `closeAll` den Slot ohne Ref-Math und ohne Page kopieren oder
  löschen. Das hält die Free-Page-Invariante über jede fd-Operation auf stdio
  neutral.
- **fd 0/1/2 vorinstalliert.** PID-1-Bring-up (`kernel_process` in
  `src/kernel.flash`) installiert drei `console`-Slots vor dem Eintritt in den
  User-Space. Es wird keine Page allokiert, sodass die PID-1-Baseline
  `0xbbff2` unverändert bleibt.
- **fork erbt, execve erhält.** `copy_process`
  (`src/fork.flash`) ruft `fdtable.dupAll`, bumpt die Pipe-/File-Ref
  jedes Nicht-Console-Slots; `do_wait` (`src/sched.flash`) ruft
  `fdtable.closeAll` auf dem Zombie. `execve` reißt nur den
  Address-Space (`mm.*`) ab und **lässt `fds` intakt**, sodass eine Shell
  einem Child ihr redirektetes stdio über die `exec`-Grenze übergibt.
- **`dup2`** schließt einen offenen `newfd` (Ref nach Kind gedroppt), zeigt ihn
  auf `oldfd`s Backend und bumpt die Ref; `dup2(fd, fd)` ist ein No-op.
  Dies ist das Primitiv hinter Shell-fd-Redirection (`[TEST]
fd-redirect`, §8).

### Shell & Userland (fsh)

Die Syscall-Surface wird zu einer interaktiven Shell, `fsh`, zusammengebaut,
im initramfs bei `/bin/fsh` bereitgestellt, neben den `/bin`-Coreutils (`echo`,
`cat`, `ls`, `grep`, dem FAT32-Trio `cp` / `mv` / `rm`, dem `less`-Pager,
dem `edit`-Editor und den System-Info-Readern). fsh und die Coreutils linken
gegen **flibc** (`user_space/lib/flibc/`), die Userland-Mini-libc:
SVC-Wrapper, ein Comptime-Format-`printf`, der `_start`-argc/argv-Shim und —
für Payloads, die LLVMs `memcpy` / `strlen`-Idiom-Lowering triggern — ein
freestanding `mem.flash`-Provider. Die Coreutils nutzen Fixed-Size-Stack-/
Static-Buffer, sodass der einzelne R+X-PT_LOAD, in den jedes linkt, kein
schreibbares `.bss` trägt; der Userland-Heap (`brk` / `sbrk` hinter flibcs
Bump-`malloc`) bleibt von ihnen ungenutzt. Sein erster Consumer ist
`/bin/edit` (unten).

**`/bin/edit` — Vollbild-Texteditor.** Der zweite interaktive Consumer des
Navigation-Scaffolds (nach `/bin/less`) und der erste Writer: `edit <file>`
saugt eine Datei in einen heap-gebackten **Gap-Buffer**, übernimmt die Console
mit dem Alternate-Screen + Raw-Mode und editiert sie in place. Es ist der erste
echte Consumer des Userland-Heaps — der Gap-Buffer-Storage wird `malloc`'t und
bei Bedarf verdoppelt (flibcs `free` ist ein No-op, sodass ein Grow den alten
Block aufgibt, beim Exit gereapt). Die Editing-Logik lebt in drei puren,
host-getesteten Cores in flibc —
`gapbuf.GapBuf` (Storage), `gapbuf.LineIndex` (Zeilen + Cursor-Motions) und
`gapbuf.Viewport` (Scroll) — plus `grep_match.find` für Suche; das hält den
Korrektheitsbeweis auf dem Host, da die interaktive Loop nicht unter QEMU
laufen kann (kein PL011-Serial-Input). **Keymap:** Pfeile / Home / End / PgUp /
PgDn bewegen, druckbare Tasten fügen ein, Backspace / Delete entfernen, Enter
splittet die Zeile, `ctrl-O` schreibt, `ctrl-W` sucht vorwärts vom Cursor und
`ctrl-X` beendet (fordert zum Speichern eines modifizierten Buffers auf). Save
ist **unlink + create + write**, nicht in-place: das `write` des FAT32-Backends
lässt nur `file_size` wachsen (es gibt kein Truncate), sodass ein Neuerstellen
der Datei jedes Mal die korrekte, möglicherweise kleinere Größe ergibt. Limits:
eine logische Zeile pro Screen-Row (horizontaler Scroll, kein Soft-Wrap), kein
Undo, Tabs als einzelnes Leerzeichen gezeigt, fixe 24×80-Geometrie. Die
Edit-Loop selbst wird auf echter Pi-Hardware validiert.

- **REPL.** `fsh` liest `/etc/fshrc` einmal beim Start (`open` → `read` →
  `close`; Kommentar- und Leerzeilen übersprungen, jede andere Zeile
  dispatcht), und loopt dann: Prompt drucken → `readline` (fd 0) → tokenize →
  dispatch.
- **`readline`** ist ein Userland-Line-Editor über `sys_read(0, &b, 1)`:
  druckbare Bytes echoen, BS/DEL löschen, CR/LF submitten, `^D` auf einer leeren
  Zeile ist EOF (Logout), `^C` verwirft die Zeile. Die Kernel-Console bleibt
  dumm — `sys_setConsoleMode` ist inert; Raw/Cooked ist ein zukünftiges
  PTY-Anliegen. Die Byte→Buffer-State-Machine ist pure und host-getestet.
- **Tokenizer.** Whitespace-Split in ein fixes `argv[]` mit **höchstens
  einem** `|`; ein zweiter Pipe oder eine leere Seite wird abgelehnt. Die
  Pipe-Grenze wird durch einen `null`-argv-Slot markiert, sodass die linken und
  rechten Kommandos bereits `execve`-ready NULL-terminierte Vektoren sind.
  Pure + host-getestet.
- **Built-ins** laufen in-process (kein Fork): `cd` (`sys_chdir`), `pwd`
  (`sys_getcwd`), `exit` / `logout`, `help`, `free` (wrappt
  `sys_dump_free`), `whoami` (`/etc/passwd`-Lookup via `src/pwfile.flash`),
  `reboot`
  (`sys_reboot`, resettet das Board). Externals forken + `execvp`;
  `execvp` löst einen bloßen Namen zu `/bin/<name>` auf (noch kein `$PATH`, kein
  Environment) und einen geslashten Namen wörtlich. Ein einzelnes `|` verdrahtet
  `sys_pipe` + `dup2`: fork links (`dup2(wfd,1)`), fork rechts (`dup2(rfd,0)`),
  beide Enden in der Shell schließen, beide reapen.
- **Working-Directory.** Jeder Task trägt `cwd` (`TaskStruct.cwd`,
  Default `/`); `cd` aktualisiert es via Slot 36, `pwd` liest es via
  Slot 48 zurück, und relative `open`/`execve` joinen dagegen (§5). Es gibt
  noch kein `$HOME` / uid; `.fshrc` ist ein fixer initramfs-Pfad.
- **Coreutils (`/bin`).** Jedes ist < 100 Zeilen gegen flibc,
  nur Stack-Buffer (Regel 1), und dient doppelt als Smoke-Test: `echo` (Args
  → fd 1), `cat` (Files / stdin → fd 1), `ls` (der erste `sys_readdir`-
  Consumer — `readdir(path, i, &d)` von `i = 0` bis -1, jeden Basenamen plus
  einen `/`-Suffix bei `DT_DIR` druckend; ohne Args listet `cwd`), `meminfo`
  (`printf("free pages: %u\n", sys_dump_free())`, die Standalone-Form des
  `free`-Built-ins), `forkbomb` (eine gecappte 16-Fork/Reap-Leak-Probe
  — eine interaktive Demo der Fork/Reap-Page-Balance, nicht bis `fork() == -1`
  getrieben) und `dmesg` (snapshottet den Kernel-Log-Ring via
  `sys_klog_read` und schreibt das retinierte Boot-Log auf fd 1, sodass das
  Boot-Log über die USB-C-Console ohne den Mini-UART-Adapter lesbar ist). Das
  `ls`-Listing und die Backend-Mechanik, die es zeigt, sind in §3
  „Directory-Enumeration" dokumentiert.
- **PID-1 → login → fsh-Übergabe.** PID 1 bleibt die Test-Harness:
  nachdem `run_all` den `N/N passed`-Tally druckt, `execve`t
  `init_main.flash` `/bin/login` _statt_ `sys_exit` (fällt nur durch zu
  `sys_exit`, wenn execve fehlschlägt). login ist ein **Session-Supervisor**:
  es fragt nach einem Username (Kernel-Echo an) und einem Passwort (der Kernel
  maskiert jedes getippte Zeichen mit `*` via `SYS_SET_CONSOLE_MODE`),
  bittet den Kernel, das Passwort gegen die aktive Shadow-Datenbank zu
  verifizieren (`sys_authenticate`, §5), schaut den User
  in `/etc/passwd` nach (der geteilte `src/pwfile.flash`-Parser), und **forkt**
  dann ein Child, das Privilegien via `setgid` + `setuid` droppt (gid zuerst,
  während noch root) und
  die Shell des Users exect — login selbst bleibt root, wartet, reapt und
  fragt erneut. `exit` (oder sein Alias `logout`) in fsh ist daher ein Logout
  zurück zu `login:`, nicht das Ende des Boots. (Der Drop muss im Child leben:
  setuid ist One-Way für Non-Root, sodass ein login, das sich selbst gedroppt
  hätte, nie eine zweite Session authentifizieren könnte.) Ein optionales
  argv-Session-Limit (`/bin/login 2`) lässt es nach N Sessions beenden — der
  Hook des `[TEST] login`-Capstones (§8).
  **Das Erreichen des interaktiven Prompts ist das Boot-Success-Signal:** fsh
  druckt sein Homescreen-Banner (der stabile `type 'help' for commands`-
  Schweif) beim REPL-Eintritt und zeigt `#` (root) oder `$` (alle anderen) als
  seinen Prompt; mit den zwei gescripteten Sessions von `[TEST] login` wartet
  der CI-QEMU-Watchdog (`scripts/run_qemu_test.sh`) auf den **dritten**
  Homescreen-Marker (SIGTERMt dann) und asserted genau drei. Auf Pi /
  interaktivem QEMU droppt der Boot zu einem echten Login-Prompt,
  dann zu einem `fsh`-Prompt, der als authentifizierter User läuft.
  **Unattended CI:** PID-1 console-injectet die Test-Credentials
  (`flash`/`flash`, `SYS_CONSOLE_INJECT`) vor dem exec, sodass der echte
  Login-Pfad ohne Tipper authentifiziert. Weder login noch fshs Startup
  emittiert `sys_dump_free`, sodass der Free-Page-Checkpoint-Count
  deterministisch bleibt (§8).

## 5. Syscalls & Exceptions

Die Vector-Table ist in `arch/aarch64/entry.S` und wird von
`irq_init_vectors` (`arch/aarch64/irq.S`) in `vbar_el1` geladen. Synchrone
Exceptions von EL0 werden in `handle_sync_el0_64` dispatcht. SVCs gehen durch
`el0_svc` → indizierten Lookup in `sys_call_table` (`src/sys.flash`);
Data-Aborts rufen `do_data_abort`.

`enable_interrupt_gic` (`src/board/<board>/irq.flash`) verdrahtet Interrupt-IDs
zu einem spezifischen Core. Der Kernel routet aktuell den Auxiliary-IRQ
(Mini-UART-RX) und den Non-Secure-Physical-Timer. Der Mini-UART-RX-
Handler leert das FIFO in einem einzigen IRQ-Slot bis leer und speist jedes
Byte in den `console.flash`-RX-Ring; dasselbe Pattern lebt im
`virt`-PL011-Pfad. Siehe `### Console-Subsystem` unten.

### Syscall-ABI

User-Space invoked einen Syscall, indem er die Syscall-Nummer in `x8` legt,
Argumente in `x0..x5` und `svc #0` ausführt. Der Return-Value ist
in `x0`.

```text
x8       syscall number
x0..x5   arguments (per syscall)
svc #0   trap into the kernel
x0       return value
```

Der Vector bei `vbar_el1 + 0x400` (`el0_svc` in `arch/aarch64/entry.S`)
indiziert in `sys_call_table` (`src/sys.flash`) und `blr`t zum
ausgewählten Handler. `NR_SYSCALLS = 56` (in `arch/aarch64/asm_defs_common.inc`)
wird durch einen `b.hs`-Check auf `x8` erzwungen; Out-of-Range-Nummern fallen
durch zum Invalid-Entry-Pfad. Ein Comptime-Guard in `src/sys.flash`
re-asserted `defs.NR_SYSCALLS == 56`, sodass die Zig-Table und das asm-Literal
im Gleichschritt bleiben.

Da die User-PGD zum Zeitpunkt des SVC in TTBR0 installiert ist, wird die
Syscall-Table beim Boot zu High-Mem-Adressen umgeschrieben (das
`LINEAR_MAP_BASE`-OR-in), sodass das `blr` im TTBR1-Mapping des Kernels landet
statt in den UVA-Space zu jagen.

### Syscall-Referenz

| `x8` | Name              | Args                                                                                                                           |                                                                         Returns                                                                         | Anmerkungen                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| :--: | :---------------- | :----------------------------------------------------------------------------------------------------------------------------- | :-----------------------------------------------------------------------------------------------------------------------------------------------------: | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
|  0   | ~~`write_str`~~   | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-NUL-terminierter Console-String-Printer entfernt, nachdem die vereinheitlichte fd-ABI (Slots 31-35) ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück. Der saubere `write`-Name gehört jetzt dem vereinheitlichten `(fd, buf, len)`-Call bei Slot 33                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
|  1   | `fork`            | (keine)                                                                                                                        |                                                       `i32` PID des Childs im Parent, `0` im Child                                                       | Standard-Fork-Semantik. Bei Task-Slot-Erschöpfung (oder, kontraktuell, Page-OOM) gibt es `-1` zurück, wobei das teilweise aufgebaute Child-mm freigegeben wird — page-balance-neutral, kein halbgebauter Zombie                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
|  2   | `exit`            | (keine)                                                                                                                        |                                                                     kehrt nicht zurück                                                                   | Markiert den Task `TASK_ZOMBIE`, reschedult                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
|  3   | `wait`            | (keine)                                                                                                                        |                                                                `i32` PID des gereapten Childs                                                            | Blockiert auf `TASK_INTERRUPTIBLE`, bis irgendein Child exitet, gibt dann seine Pages und den Slot frei                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
|  4   | `dump_free`       | (keine)                                                                                                                        |                                                                `u64` Anzahl freier Pages                                                                 | **Public-Introspection-ABI.** Druckt + gibt den Free-Page-Count zurück. Die In-Kernel-Test-Harness nutzt den Return-Value als ihr Leak-Detection-Signal                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
|  5   | ~~`exec`~~        | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Blob/ELF-Loader entfernt, nachdem Slot 31 `execve` ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
|  6   | `kill`            | `x0 = pid`                                                                                                                     |                                                               `i32` 0 bei Treffer, -1 bei Fehltreffer                                                    | Findet den Task mit passender `pid`, flippt ihn zu `TASK_ZOMBIE`, weckt den Parent. **Self-Kill wird abgelehnt** — nutze `exit`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
|  7   | `openFile`        | `x0 = const u8 *` (NUL-terminierter Pfad)                                                                                      |                               `i32` fd ≥ 0 bei Erfolg, -1 bei Fehltreffer / Alloc-Failure, -13 (`-EACCES`) bei einer Permission-Verweigerung             | Dispatcht den Pfad durch den VFS-Shim (`vfs.vfs_open`, siehe §3) an das passende Backend, führt den Permission-Check aus (open ist Read-Intent — die Effective-IDs des Callers gegen die Mode/Owner der Datei, root bypasst; Verweigerung gibt `-EACCES` zurück, bevor eine `File`-Page allokiert wird), allokiert eine `File`-Page (`src/file.zig`), verstaut den backenden `SuperBlock` + die Mode/uid/gid der Datei im `File`, installiert das Handle in den Per-Task-`open_files`-Slot. Die Pfad-UVA erreicht den Kernel via `copy_from_user`; eine Wild-UVA gibt `-1` zurück via den Soft-Pfad in `mm_user.check_and_prefault_user_range` — Caller zombifiziert **nicht**                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|  8   | ~~`readFile`~~    | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Per-Kind-File-Read entfernt, nachdem Slot 32 `read` ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|  9   | ~~`writeFile`~~   | —                                                                                                                              |                                                                            —                                                                            |  **AUSGEMUSTERT** — Legacy-Per-Kind-File-Write entfernt, nachdem Slot 33 `write` ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück. FAT32-Write-Back (`/mnt/…`) routet jetzt durch das vereinheitlichte `write`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
|  10  | `seek`            | `x0 = fd`, `x1 = i64 off`, `x2 = whence`                                                                                       |                                                     `i64` neuer Offset, `-1` bei bad fd / Out-of-Range                                                    | `whence = 0` SEEK_SET, `1` SEEK_CUR, `2` SEEK_END. Bounds-Check `[0, File.size]`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
|  11  | ~~`closeFile`~~   | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Per-Kind-File-Close entfernt, nachdem Slot 34 `close` ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück. `do_wait` reclaimt weiterhin die geleakten fds eines Zombies via `fdtable.closeAll`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
|  12  | `brk`             | `x0 = addr` (oder 0 zum Lesen)                                                                                                 |                                          `i64` neuer Break, oder aktueller Break falls `addr == 0`, `-1` bei bad Request                                  | Setzt den Heap-Break (auf PAGE_SIZE aufgerundet). Bounds:`[HEAP_BASE, STACK_TOP - STACK_BUDGET)`. Pages werden von `do_data_abort` demand-allokiert; Shrinks unmappen + geben die freigegebenen Pages frei und TLB-flushen via `set_pgd`. Heap-OOM surfaced daher beim ersten Touch als `[KERN] OOM` + Zombie (der Fault-Pfad), nicht als `brk`-Return                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
|  13  | `sbrk`            | `x0 = delta` (i64)                                                                                                             |                                                     `i64` vorheriger Break, `-1` bei Overflow / Range                                                     | Convenience-Wrapper:`brk(current + delta)`. Gibt den _vorherigen_ Break zurück                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
|  18  | `pipe`            | (keine)                                                                                                                        |                                         `i64` gepackt (`(wfd << 32) \| rfd`), `-1` bei Alloc- oder fd-Table-Failure                                       | Allokiert eine 4-KiB-Pipe-Page (Header + Ring). Zwei fds installiert in der vereinheitlichten `current.fds`-Table (`fdtable.install(.pipe, …)` ×2), `refs = 2`. Single-Producer / Single-Consumer pro Ende; Multi-Reader/Writer aufgeschoben. Die zwei Enden werden via die vereinheitlichten Slots 32/33 gelesen/geschrieben                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|  27  | ~~`pipe_read`~~   | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Per-Kind-Pipe-Read entfernt, nachdem Slot 32 `read` ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|  28  | ~~`pipe_write`~~  | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Per-Kind-Pipe-Write entfernt, nachdem Slot 33 `write` ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
|  29  | ~~`pipe_close`~~  | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Per-Kind-Pipe-Close entfernt, nachdem Slot 34 `close` ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
|  23  | ~~`openConsole`~~ | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Console-Open entfernt; fd 0/1/2 sind echte `console`-Slots, auf PID 1 vorinstalliert (siehe §4 „File-Deskriptor-Modell"). Die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
|  24  | ~~`readConsole`~~ | —                                                                                                                              |                                                                            —                                                                            | **AUSGEMUSTERT** — Legacy-Console-Read entfernt, nachdem Slot 32 `read` auf einem `console`-fd ihn ersetzte; die Slot-Nummer bleibt für immer reserviert und gibt `-1` zurück                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
|  25  | `setConsoleMode`  | `x0 = u64 mode`                                                                                                                |                                                                         `i64` 0                                                                         | **Console-Echo/Mask-Flags.** `mode & CONSOLE_MODE_ECHO` an ⇒ der Kernel echot geleerte druckbare Console-Bytes durch den Console-TX-Mux zurück (cooked-style); `mode & CONSOLE_MODE_MASK` an ⇒ er echot stattdessen ein `*` pro druckbarem Byte (Passwort-Masking; Mask gewinnt, falls beide gesetzt); keins (der Boot-Default) behält den historischen Split, wo der Kernel nie echot und Userland-`readline` das Echo besitzt. `/bin/login` setzt Echo für den Username und Mask für das Passwort, löscht dann beide vor dem exec der Shell. Zwei Bits vorerst; volles termios / Line-Discipline ist noch Future Work                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
|  26  | `closeConsole`    | (keine)                                                                                                                        |                                                                          void                                                                           | Inert (fd-Table-Teardown — noch nicht verdrahtet)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
|  30  | `console_inject`  | `x0 = byte`                                                                                                                    |                                                                          void                                                                           | **Nur Debug — nicht Teil der stabilen ABI.** Pusht ein Byte in den Kernel-RX-Ring, als wäre es auf der UART angekommen. Powert deterministische `[TEST] console-echo`-Coverage auf QEMU, wo es keinen externen Input-Driver gibt. Zu entfernen, sobald ein echter Host-Input-Driver landet                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
|  31  | `execve`          | `x0 = const char *path` (NUL-terminiert), `x1 = char *const argv[]` (NULL-terminiert)                                          | `i32` 0 (kehrt bei Erfolg nicht zurück), -1 bei Resolve- / Parse- / Alloc- / argv-Fault-Failure, -13 (`-EACCES`), wenn die Mode des Targets dem Caller exec verweigert | Path-aufgelöster ELF-Loader (löst Slot 5 `exec` ab). Der Permission-Layer gatet ihn auf das Exec-Bit: die Effective-IDs des Callers werden direkt nach dem VFS-Resolve und **vor** dem Address-Space-Teardown gegen die Mode/Owner des Targets geprüft, sodass ein verweigertes exec soft zu `-EACCES` failt, mit intaktem Caller (root bypasst). Löst `path` durch den VFS-Shim auf, streamt das ganze ELF in einen statischen Kernel-Buffer (kein `PAGE_SIZE`-Cap), kopiert argv auf die neue oberste Stack-Page (Entry-Kontrakt `x0 = argc`, `x1 = argv`, AAPCS64), reißt den Address-Space des Callers ab, mappt dann das neue Image. Pfad- + argv-UVAs erreichen den Kernel via `copy_from_user`; eine Wild-UVA gibt `-1` zurück via den Soft-Pfad in `mm_user.check_and_prefault_user_range` — Caller zombifiziert **nicht** (jede Kopie ist vor dem Teardown-Point-of-No-Return abgeschlossen). Die fd-Table (`current.fds`) wird über den Teardown hinweg bewusst **erhalten**, sodass eine Shell einem Child ihr redirektetes stdio übergibt. Ein Post-Teardown-Loader-OOM emittiert `[KERN] OOM` und zombifiziert den Caller (Controlled Zombie — der Address-Space ist bereits abgerissen) |
|  32  | `read`            | `x0 = fd`, `x1 = u8 *buf`, `x2 = len`                                                                                          |                                              `i64` gelesene Bytes (Short-Read OK), `0` bei EOF, `-1` bei bad fd                                          | **Vereinheitlichtes read.** Schaut `fd` in `current.fds` nach und dispatcht auf den Slot-Tag: `console` → Console-RX-Pfad, `pipe` → Pipe-Ring-Drain, `file` → Backend-`read`. Löste die Per-Kind-Read-Shims ab (ausgemusterte Slots 8/24/27). Die `buf`-UVA erreicht den Kernel via `copy_to_user`; eine Wild-UVA gibt `-1` zurück via den Soft-Pfad, keine Zombifizierung                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
|  33  | `write`           | `x0 = fd`, `x1 = const u8 *buf`, `x2 = len`                                                                                    |                          `i64` geschriebene Bytes, `-1` bei bad fd, -13 (`-EACCES`), wenn die Mode eines `file`-fd dem Caller write verweigert           | **Vereinheitlichtes write** (besitzt den sauberen `write`-Name — der Legacy-NUL-terminierte Console-Printer früher bei Slot 0 `write_str` ist ausgemustert). Dispatcht auf den `current.fds`-Slot-Tag (`console`/`pipe`/`file`). Auf einem `file`-fd prüft der Permission-Layer Write-Intent gegen die Mode/uid/gid, die das `File` seit open trägt (open ist in dieser ABI nur Read-Intent, sodass eine lesbare-aber-nicht-schreibbare Datei sauber öffnet und hier verweigert wird; root bypasst). Löste die Per-Kind-Write-Shims ab (ausgemusterte Slots 9/0/28). Die `buf`-UVA erreicht den Kernel via `copy_from_user`; eine Wild-UVA gibt `-1` zurück via den Soft-Pfad, keine Zombifizierung                                                                                                                                                                                                                                                                                                                                                                                                                                            |
|  34  | `close`           | `x0 = fd`                                                                                                                      |                                                               `i32` 0 bei Treffer, -1 bei Fehltreffer                                                    | **Vereinheitlichtes close.** Löscht den `current.fds`-Slot und droppt die Ref des backenden Objekts nach Kind (`pipe`/`file`); `console`-Slots sind refcount-exempt (kein Per-fd-Objekt). `file`-fds routen auch durch `vfs_close`. Löste die Per-Kind-Close-Shims ab (ausgemusterte Slots 11/29)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
|  35  | `dup2`            | `x0 = oldfd`, `x1 = newfd`                                                                                                     |                                                   `i32` `newfd` bei Erfolg, -1 bei bad `oldfd`/`newfd`                                                    | **POSIX `dup2`.** Ist `newfd` offen, wird er zuerst geschlossen (Ref nach Kind gedroppt); `newfd` zeigt dann auf `oldfd`s Backend und seine Ref wird gebumpt (`console` ist refcount-exempt). `dup2(fd, fd)` ist ein No-op, das `fd` zurückgibt. Das Primitiv hinter Shell-fd-Redirection                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
|  36  | `chdir`           | `x0 = const u8 *path` (NUL-terminiert)                                                                                         |                                              `i32` 0 bei Erfolg, -1 bei Wild-UVA / un-terminiert / oversize                                              | **Working-Directory.** Normalisiert `path` gegen das `cwd` des Tasks (`TaskStruct.cwd`, 256 B, Default `/`) — relative Pfade werden vom puren host-getesteten `src/path.flash:joinResolve` gejoint und `.`/`..`-kollabiert, absolute Pfade kollabieren in place — und speichert das Ergebnis. Kein Backend-Existenz-Check in diesem Release (aufgeschoben zu `sys_readdir`); die open/execve-Grenze joint relative Pfade gegen dieses gespeicherte `cwd` vor dem noch-nur-absoluten `vfs.resolve`. `cwd` wird über `fork` geerbt und über `execve` erhalten                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
|  37  | `readdir`         | `x0 = const u8 *path` (NUL-terminiert), `x1 = u64 index`, `x2 = Dirent *out`                                                   |                                    `i32` 0 mit gefülltem `*out` bei Treffer, -1 bei End-of-Directory / bad Pfad / Wild-UVA                                | **Directory-Enumeration.** Zustandsloser Index-Walk — füllt den `index`-ten Eintrag des Directorys bei `path` und gibt 0 zurück, oder -1 jenseits des letzten Eintrags. Kein fd-Cursor / `opendir`-Handle (die POSIX-Form ist ein zukünftiges Portable-Userland-Revisit). `path` wird `cwd`-gejoint wie `open`/`chdir`, dann `vfs.resolve`d (null → -1, z. B. `/mnt/*` unter QEMU, wo FAT32 nicht mountet). Das initramfs-Backend synthetisiert Directory-Listings aus cpio-Pfad-Prefixen; das FAT32-Backend rendert 8.3-Root-Directory-Einträge (nur Pi). Pfad-UVA rein und `Dirent`-UVA raus queren beide via das Soft-`copy_from_user` / `copy_to_user`; eine Wild-UVA gibt -1 zurück, keine Zombifizierung. Allokiert nichts — die zustandslose ABI fügt keine OOM-Stelle hinzu                                                                                                                                                                                                                                                                                                                                                          |
|  38  | `klog_read`       | `x0 = u8 *buf`, `x1 = u64 len`                                                                                                 |                                                  `i64` Byte-Count (0 bei leerem Ring), -1 bei Wild-UVA                                                    | **Kernel-Log-Read.** Snapshottet die neuesten `min(len, retained)` Bytes des Kernel-Byte-Rings (`src/klog_ring.flash`) in `buf`, oldest-first, und gibt den Count zurück. `main_output` (`src/utilc.flash`) tee't jede emittierte Zeile in den 16-KiB-Overwrite-Oldest-Ring, sodass das Boot-Log im RAM überlebt; `/bin/dmesg` liest es über die USB-C-Console ohne den Mini-UART-Adapter zurück. Consume-free + zustandslos — jeder Call sieht den Live-Ring, sodass er nie blockiert und keinen Per-fd-Cursor hält. `buf` quert via das Soft-`copy_to_user` (Wild-UVA → -1, keine Zombifizierung); allokiert nichts (der Ring ist statisches BSS, baseline-neutral). Ring-Kapazität `KLOG_SIZE` ist die geteilte ABI-Konstante, auf die `dmesg` seinen Buffer dimensioniert                                                                                                                                                                                                                                                                                                                                                                |
|  39  | `getuid`          | (keine)                                                                                                                        |                                                                     `i64` real uid                                                                      | **Prozess-Credentials.** Berichtet die Real-uid des rufenden Tasks (`TaskStruct.uid`). Credentials werden über `fork` geerbt und über `execve` erhalten                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
|  40  | `geteuid`         | (keine)                                                                                                                        |                                                                   `i64` effective uid                                                                   | Wie `getuid`, für die Effective-uid — die ID, gegen die die VFS-Permission-Checks testen                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
|  41  | `getgid`          | (keine)                                                                                                                        |                                                                     `i64` real gid                                                                      | Wie `getuid`, für die Real-Group-ID                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
|  42  | `getegid`         | (keine)                                                                                                                        |                                                                   `i64` effective gid                                                                   | Wie `getuid`, für die Effective-Group-ID                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
|  43  | `setuid`          | `x0 = u32 uid`                                                                                                                 |                                                             `i64` 0 bei Erfolg, -1 (EPERM)                                                              | **Privilege-Drop.** Root (euid 0) setzt sowohl die Real- als auch die Effective-uid auf einen beliebigen Wert — so wird `/bin/login` zum authentifizierten User. Ein Non-Root-Caller darf seine euid nur auf eine ID setzen, die er bereits hält (real oder effective); alles andere gibt -1 zurück, sodass ein gedroppter Prozess nie zurück zu root klettern kann. Kein Saved-uid (setresuid) in diesem Release                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
|  44  | `setgid`          | `x0 = u32 gid`                                                                                                                 |                                                             `i64` 0 bei Erfolg, -1 (EPERM)                                                              | Spiegel von `setuid` über die Group-IDs. `/bin/login` ruft es _vor_ `setuid` (gid zuerst, während noch root — nach dem uid-Drop wäre es verweigert)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
|  45  | `authenticate`    | `x0 = const u8 *user`, `x1 = u64 user_len`, `x2 = const u8 *pass`, `x3 = u64 pass_len`                                         |                                                            `i64` 0 bei Match, -1 sonst                                                                   | **Kernel-eigene Credential-Verify.** Liest die aktive Shadow-Datenbank in-kernel (die execve-artige No-Alloc-VFS-Rezeptur — baseline-neutral): die schreibbare FAT32-Kopie `/mnt/shadow` zuerst (dort schreibt `passwd`), fällt auf den initramfs-`/etc/shadow`-Seed zurück, wenn `/mnt` unmounted ist (QEMU virt), die Datei fehlt (frische Karte) oder sie korrupt ist — Letzteres laut angekündigt (die Anti-Brick-Regel: Korruption sperrt den Operator nie aus, die eingebackenen Seed-Credentials funktionieren weiter). Findet die Zeile des Users (`user:iterations:salt_hex:hash_hex`, geparst vom host-getesteten `src/shadow.flash`), läuft PBKDF2-HMAC-SHA256 (`src/sha256.flash`) über das Passwort mit dem gespeicherten Salt + Iteration-Count und constant-time-vergleicht (`ctEql`) gegen den gespeicherten Verifier. Die KDF und jedes Salt-/Hash-Byte bleiben im Kernel — Userland sieht nur Pass/Fail. Das Klartext-Passwort quert die User→Kernel-Grenze genau einmal in einen statischen Kernel-Buffer (vom nächsten Call überschrieben). Credential-UVAs queren via das Soft-`copy_from_user` (Wild-UVA / Over-Long-Input → -1, keine Zombifizierung)    |
|  46  | `passwd`          | `x0 = const u8 *user`, `x1 = u64 user_len`, `x2 = const u8 *old`, `x3 = u64 old_len`, `x4 = const u8 *new`, `x5 = u64 new_len` |                                      `i64` 0 bei Erfolg, -13 (`-EACCES`) bei einer Autorisierungs-Failure, -1 sonst                                       | **Kernel-eigene Passwort-Änderung.** Schreibt den Record von `user` im schreibbaren FAT32-Shadow (`/mnt/shadow`) mit einem frischen kernel-gemünzten Salt (`src/hwrng.flash`) und einem PBKDF2-Re-Hash des neuen Passworts um. Autorisierung: root (euid 0) darf jeden Record ohne das alte Passwort zurücksetzen (der Forgotten-Password-Recovery-Pfad); alle anderen nur den Record, dessen Name auf ihre eigene uid mappt (`/etc/passwd`-Lookup via das host-getestete `src/pwfile.flash`) und nur mit dem korrekten alten Passwort. Das Umschreiben ist per Konstruktion splice-safe: der Iteration-Count bleibt erhalten und Salt/Hash sind Fixed-Width-Hex, sodass die neue Zeile byte-identisch in der Länge ist und der Whole-File-In-Place-Write die Dateigröße nie ändert (kein FAT32-Dir-Entry-Resize). Gibt -1 zurück, wenn kein schreibbarer Shadow existiert (QEMU virt / frische Karte — der initramfs-Seed ist immutable), der User keinen Record hat, oder das Umschreiben die Record-Länge ändern würde. `/bin/passwd` ist der interaktive Consumer                                                                              |
|  47  | `reboot`          | (keine)                                                                                                                        |                                                                     kehrt nicht zurück                                                                   | **Machine-Reset.** Resettet das Board durch den Per-Board-Pfad (PSCI `SYSTEM_RESET` auf QEMU virt, der BCM2711-Watchdog-Full-Reset auf rpi4b, hinter der `board.power`-Facade) und kehrt nie zurück. EL0 kann das privilegierte SMC / Power-Manager-MMIO nicht selbst ausgeben, weshalb es ein Syscall ist. Noch kein Privilege-Gate — jede eingeloggte Session darf rebooten                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|  48  | `getcwd`          | `x0 = u8 *buf`, `x1 = u64 len`                                                                                                 |                                          `i64` Pfad-Länge exklusive des NUL, -1 bei Wild-UVA / `len` zu klein                                            | **Working-Directory-Readback** — die Readback-Hälfte des Slot-36-`chdir`-Store. Kopiert das NUL-terminierte `cwd` des Tasks (`TaskStruct.cwd`) in den User-Buffer; `cwd` ist ein plain TaskStruct-Feld, sodass dies nichts allokiert. `buf` quert via das Soft-`copy_to_user`; eine Wild-UVA oder ein `len` zu klein, um den Pfad plus seinen Terminator zu halten, gibt -1 zurück, keine Zombifizierung. `pwd` ist der einzige Consumer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
|  49  | `mem_total`       | (keine)                                                                                                                        |                                                          `u64` allokierbare Pool-Größe in Pages                                                          | **Hardware-Monitoring.** Gibt die eingefrorene Post-Reserve-allokierbare Pool-Größe zurück (die Boot-Free-Page-Baseline des Boards). Konstant nach dem Boot — anders als `dump_free` bewegt es sich nicht, wenn Pages ausgegeben werden — sodass ein Tool „used" als dies minus `dump_free` und Total-Bytes als pages << 12 ableitet. Board-unabhängig (`page_alloc`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
|  50  | `uptime`          | (keine)                                                                                                                        |                                                                `u64` Sekunden seit Boot                                                                 | **Hardware-Monitoring.** Sekunden seit Boot vom Architectural-Counter, `CNTPCT_EL0` durch die Runtime-`CNTFRQ_EL0` teilend (nicht die fixe Tick-Periode, die von der Counter-Rate abweichen kann). Monoton. Board-unabhängig                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
|  51  | `cpu_temp`        | (keine)                                                                                                                        |                                                       `u64` Milli-Grad Celsius, `0` = unbekannt                                                         | **Hardware-Monitoring.** SoC-Temperatur über die VideoCore-Mailbox (`TAG_GET_TEMPERATURE`). Liest `0` = unbekannt auf einem Board ohne die Firmware (QEMU virt) oder bei einem Mailbox-Timeout. Der Kernel läuft die Transaktion unter `preempt_disable`, um den geteilten Property-Buffer gegen einen Task-Switch zu serialisieren                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
|  52  | `cpu_freq`        | (keine)                                                                                                                        |                                                                 `u64` Hz, `0` = unbekannt                                                               | **Hardware-Monitoring.** ARM-Core-Clock über die VideoCore-Mailbox (die firmware-berichtete Rate, die mit DVFS skaliert). Liest `0` = unbekannt auf einem Board ohne die Firmware (virt) oder bei einem Mailbox-Timeout. Dieselbe `preempt_disable`-Serialisierung wie `cpu_temp`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
|  53  | `create`          | `x0 = const u8 *path` (NUL-terminiert)                                                                                         |                                                          `i32` schreibbarer fd (≥ 0), -1 bei Error                                                       | **File-Create (`creat`).** Erstellt eine neue leere Datei bei `path` und gibt einen schreibbaren fd zurück — die Create-then-Write-Hälfte, die der `open`-ABI fehlt (Slot 7 hat kein `O_CREAT`). `path` wird `cwd`-gejoint wie `open`, dann `vfs.resolve`d; nur der FAT32-`/mnt`-Mount ist schreibbar (initramfs gibt -1 zurück, EROFS). Failt -1 bei einem Namen, der nicht in 8.3 passt, einem existierenden Namen (kein Clobber), einem vollen oder unmounted Volume, oder keinem freien fd. Die neue Datei ist **caller-owned** (uid/gid = die Effective-IDs des Callers, Mode 0644); Created-File-Permission-Metadaten persistieren nicht über einen Reboot (fällt auf den `/mnt`-Overlay-Default zurück). Dasselbe Off-Stack-Pfad-Scratch wie `open`, sodass der tiefe `joinResolve`-Frame nie den TaskStruct-Credential-Tail erreicht. Nur Pi (FAT32 mountet nicht unter QEMU). `/bin/cp` ist der Consumer                                                                                                                                                                                                                                |
|  54  | `unlink`          | `x0 = const u8 *path` (NUL-terminiert)                                                                                         |                                                             `i32` 0 bei Erfolg, -1 bei Error                                                            | **File-Remove.** Tombstoned den 8.3-Directory-Eintrag der Datei (`0xE5`) und gibt ihre FAT-Cluster-Chain frei (FSInfo gutschreibend). Nur Files — ein Directory gibt -1 zurück (kein `rmdir` in diesem Release). `path` löst auf wie `open`; eine fehlende Datei, ein Read-only-Mount oder ein Fault gibt -1 zurück. Nur Pi. `/bin/rm` ist der Consumer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
|  55  | `rename`          | `x0 = const u8 *old`, `x1 = const u8 *new` (beide NUL-terminiert)                                                              |                                                             `i32` 0 bei Erfolg, -1 bei Error                                                            | **File-Rename (gleiches Directory).** Schreibt den 8.3-Namen von `old` in place zu dem von `new` um — kein Daten-Move — Cluster, Größe und Attribute erhaltend. Nur gleiches Directory: der VFS lehnt ein Cross-Mount-Paar ab, und das Backend lehnt ein anderes Parent-Directory ab, vor jedem Umschreiben (ein Cross-Directory-Move ist `/bin/mv`s Copy+Unlink-Fallback). Failt -1 bei einer fehlenden Source, einem `new`-Namen, der nicht in 8.3 passt, einem existierenden Target (kein Clobber), oder einem Fault. Beide Pfade nutzen separates Off-Stack-Scratch (sie müssen zusammen live sein). Nur Pi. `/bin/mv` ist der Consumer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

`sys_console_inject` ist ein dokumentierter Debug-Syscall, nicht Teil der
Forward-Stable-ABI-Surface. Es wird beibehalten, weil die In-Kernel-Test-
Harness davon abhängt.

Die Live-File-ABI ist `sys_openFile` (Slot 7) und `sys_seek`
(Slot 10), die durch den VFS-Shim (§3) an das passende Backend dispatchen.
FAT32-Write-Back ist live: Writes zu `/mnt/…`
routen zum FAT32-Backend, jeder andere Pfad gibt -EROFS vom
initramfs-Backend zurück. Die früheren Per-Kind-Read/Write/Close-Beine (Slots
8/9/11) sind **ausgemustert** — das vereinheitlichte Read/Write/Close (Slots
32/33/34) ersetzte sie, und diese Slot-Nummern bleiben reserviert und geben `-1`
zurück. Slots `14..17` (`sys_mmap`, `sys_munmap`, `sys_mlock`, `sys_munlock`)
und `19..22` (Socket- / IPC-Stubs) sind in `src/sys.flash` für Forward-
Kompatibilität vorhanden, kehren aber sofort zurück. Slot `18` ist das aktive
`sys_pipe`. Das Legacy-Console-Open/Read (`sys_openConsole` /
`sys_readConsole`, Slots 23/24) und das Legacy-Per-Kind-Pipe-
Read/Write/Close (`sys_pipe_read` / `_write` / `_close`, Slots 27/28/29)
sind **ausgemustert**: ihre Handler sind weg, die vereinheitlichte fd-ABI
ersetzte sie, und diese Slot-Nummern bleiben reserviert und geben `-1` zurück.
Slot 25 (`sys_setConsoleMode`) ist live als das Single-Bit-Console-Echo-Flag;
Slot 26 (`sys_closeConsole`) bleibt ein inerter Stub (fd-Table-Teardown noch
nicht verdrahtet). Slot `30` (`sys_console_inject`) ist der
Debug-only-Host-Input-Shim — er powert auch das Unattended-Boot-Login
(PID-1 injectet die CI-Credentials durch ihn).

**Vereinheitlichte fd-ABI (Slots 32..35).** `sys_read` / `sys_write` /
`sys_close` / `sys_dup2` operieren auf jedem fd, indem sie ihn in der
Per-Task-getaggten `fds`-Table nachschauen (§4 „File-Deskriptor-Modell") und
auf das Slot-Kind dispatchen. Die früheren Per-Kind-Console/Pipe/File-
Read/Write/Close-Calls wurden **ausgemustert**: ihre Kernel-Handler sind
gelöscht, die Dispatch-Table routet diese Slot-Nummern zu einem Stub, der
`-1` zurückgibt, und die Nummern bleiben für immer reserviert (nie
wiederverwendet). Es gibt jetzt einen Code-Pfad pro Backend, nur durch die
vereinheitlichte ABI erreicht. Slot 0s Legacy-`write` (`write_str`) ist ebenso
ausgemustert; der saubere `write`-Name ist der vereinheitlichte Slot 33.

**Working-Directory (Slots 36 + 48).** `sys_chdir` (Slot 36) speichert einen
normalisierten Pfad in `TaskStruct.cwd`; die open- / execve-Grenze joint
relative Pfade dagegen vor `vfs.resolve` (noch nur absolut).
Der Join + `.`/`..`-Kollaps ist der pure host-getestete `src/path.flash`-
Helper. `sys_getcwd` (Slot 48) ist die Readback-Hälfte — es kopiert `cwd`
zurück in einen User-Buffer (Pfad + NUL, die Länge zurückgebend), sodass `pwd`
ihn drucken kann; allokationsfrei, baseline-neutral. Siehe §4 „Shell & Userland
(fsh)".

**Directory-Enumeration (Slot 37).** `sys_readdir` ist ein
zustandsloser `(path, index, *Dirent)`-Index-Walk — kein `opendir`-Handle, kein
fd-Cursor (aufgeschoben zu einem zukünftigen Portable-Userland-Revisit). Der
geteilte `Dirent`-ABI-Typ (`lib/syscall_defs.flash`, die User↔Kernel-Definition,
die beide Seiten importieren) quert die Grenze per Pointer: `name` (32-Byte-
NUL-terminierter Basename — initramfs-cpio-Namen laufen länger als 8.3; FAT32
füllt ≤ 12 gerenderte 8.3-Zeichen), `d_type` (`DT_REG` 0 / `DT_DIR` 1) und 7
Pad-Bytes (40-Byte-Struct, 8-Byte-aligned). Ein `size`-Feld ist zu
`ls -l` (fsh-v2) aufgeschoben. Die Backends unterscheiden sich: initramfs
synthetisiert Directories aus cpio-Pfad-Prefixen (die flachen Archiv-Namen
benennen keinen Directory-Eintrag); FAT32 durchläuft die 8.3-Root-Directory-
Einträge (nur Pi). Siehe §3 „Directory-Enumeration" für die Backend-Mechanik
und §4 „Shell & Userland (fsh)" für den `ls`-Consumer.

**Kernel-Log (Slot 38).** `sys_klog_read(buf, len)` snapshottet die
neuesten `min(len, retained)` Bytes des Kernel-Byte-Rings
(`src/klog_ring.flash`) in `buf`, oldest-first. `main_output`
(`src/utilc.flash`) tee't jede emittierte Zeile in den 16-KiB-Overwrite-Oldest-
Ring (`KLOG_SIZE`, geteilt in `lib/syscall_defs.flash`), sodass das Boot-Log
im RAM überlebt und `/bin/dmesg` es über die USB-C-Console zurückliest —
den Mini-UART/FTDI-Adapter für die Boot-Diagnose ausmusternd. Der Ring ist
Lock-free und statisches BSS: der Tee allokiert nie (baseline-neutral) und
nimmt nie einen Lock (`main_output` läuft aus Kernel- / Syscall- / IRQ-Kontext
und so früh wie beim Boot, bevor `current` existiert), sodass ein Race
schlimmstenfalls ein Byte verstümmeln kann, nie den maskierten Buffer entkommen.
Der Read ist consume-free und zustandslos — jeder Call sieht den Live-Ring.
Siehe §4 „Shell & Userland (fsh)" für den `dmesg`-Consumer.

**Kernel-Crypto + Entropy.** `src/sha256.flash`
(SHA-256, HMAC-SHA256, PBKDF2-HMAC-SHA256 und der Constant-Time-`ctEql`-
Vergleich — host-test-gegatet gegen NIST FIPS 180-2, RFC 4231 und die
publizierten PBKDF2-HMAC-SHA256-Vektoren, plus `std.crypto`-Differential-
Checks) und `src/hwrng.flash` (die Kernel-Entropy-Quelle) sind das
Crypto-Fundament für die Identity-Arbeit. Beide sind by Design
kernel-intern: das Hashing passiert innerhalb `sys_authenticate` (Slot 45,
oben), sodass Key-Material nie die User/Kernel-Grenze quert und kein
getrandom-artiger Syscall existiert. Das sha256-Modul wird immer ReleaseSmall
gebaut — selbst in Debug-Kernel-Builds — weil die PBKDF2 → HMAC → SHA-256-
Call-Chain auf dem Per-Task-Kernel-Stack läuft und Debug-Mode-Frames groß
genug sind, um eine einzelne 4-KiB-Stack-Page zu überlaufen (siehe die Notiz in
`build.zig`). Dieser Stack ist seine eigene Page, separat vom
`TaskStruct` allokiert, sodass selbst ein Overflow die Credential-Felder, die
auf dem Task gespeichert sind, nicht mehr erreichen kann — der Failure-Mode,
den die `[TEST] authenticate`-Canary bewacht (§8).

**Identity-Files.** `/etc/passwd` (`user:uid:gid:home:shell`,
world-readable, ein committetes File — überall geparst vom host-getesteten
`src/pwfile.flash`) und `/etc/shadow`
(`user:iterations:salt_hex:hash_hex`, zur Build-Zeit generiert von
`tools/gen_shadow.zig`, das dieselbe `src/sha256.flash`-PBKDF2 läuft, mit der
der Kernel verifiziert) shippen im initramfs. `/etc/shadow` ist Mode `0o100600`
root:root — der cpio-Encoder stempelt Per-File-Modes aus der Policy-Liste des
Builds (`build.zig`), und der VFS-Permission-Layer (unten) verweigert ein
Non-Root-Open mit `-EACCES`, sodass die Passwort-Hashes für einen gedroppten
Prozess unlesbar sind.

Die initramfs-Kopie ist der immutable **Seed**; die _Live_-Shadow-Datenbank
ist `/mnt/shadow` auf der FAT32-Karte (mit denselben Bytes geseedt von
`scripts/make_test_disk.sh` für QEMU und `zig build deploy` für echte
Hardware, geschützt auf `0600 root:root` durch das Permission-Overlay unten).
`sys_authenticate` liest `/mnt/shadow` zuerst und fällt auf den Seed zurück;
`sys_passwd` + `/bin/passwd` schreiben es mit Per-Change-Random-Salts um,
gemünzt aus `hwrng`, sodass geänderte Passwörter über Reboots persistieren,
während der Seed immer als Recovery-Anker bleibt (korrupter oder fehlender
FAT32-State kann den Operator nie aussperren — es fällt zurück, laut).

**Eine bewusste Limitierung bleibt:** die _Seed_-Accounts nutzen
fixe Public-Salts + einen moderaten Iteration-Count, sodass das Kernel-Image
byte-reproduzierbar bleibt (die Pi-Hash-Baseline) und die Boot-Pfad-KDF unter
QEMU-TCG schnell bleibt; nur `passwd`-rotierte Records bekommen Random-Salts.
Die Entropy-Quelle selbst läuft einen bewusst schwachen Fallback — CNTPCT_EL0-
Samples gemischt durch SplitMix64 — und kündigt ihn laut beim Boot an
(`[Debug] hwrng: fallback (timer mix, weak) ok`). Der BCM2711-Hardware-RNG
(der RNG200-Block)-Treiber bleibt ein benannter Carve-out: QEMUs `raspi4b`-
Machine emuliert diesen Block nicht, und ein EL1-Read einer ungebackten Device-
Adresse hebt einen synchronen External-Abort, sodass keins der beiden CI-Targets
ihn ausüben kann. Zurückfallen ist Announce-and-Continue unter QEMU/CI; sobald
der Hardware-Treiber landet, wird ein Fallback auf echtem Silizium ein Hard-
Failure. `[TEST] rng` (§8) asserted den gesunden Announce durch den Kernel-Log-
Ring.

**VFS-Permission-Layer.** Jede Datei trägt `mode` / `uid` /
`gid`-Metadaten, berichtet von ihrem Backend zur Open-Zeit (`vfs.OpenResult`)
und erzwungen an der Syscall-Grenze vom puren, host-test-gegateten
`src/perm.flash:checkAccess`:

- **Woher die Metadaten kommen.** initramfs-Einträge tragen die
  Mode/uid/gid-Felder des newc-cpio-Headers; der deterministische Encoder
  (`scripts/build_initramfs.zig`) stempelt sie aus der Per-File-Policy-Liste
  in `build.zig` — Binaries (`/bin/*`, `/sbin/init`, `/test/*.elf`)
  sind `0o100755`, Config-Files (`/etc/passwd`, `/etc/fshrc`) `0o100644`,
  und `/etc/shadow` `0o100600`, alle root:root. FAT32 hat kein natives
  Owner/Mode-Konzept, sodass `/mnt`-Metadaten aus dem **Permission-
  Overlay** kommen: eine Root-Level-Textdatei (`PERMS.TAB`, Format
  `NAME MODE UID GID` pro Zeile, geparst vom host-getesteten
  `src/overlay.flash`), die das Backend einmal zur Mount-Zeit liest. Annotierte
  Basenamen bekommen ihren Eintrag; un-annotierte Pfade behalten den
  dokumentierten Default `0o100666` root:root (rw-rw-rw-, kein Exec-Bit — der
  historische „jeder Prozess darf SD-Card-Files lesen/schreiben"-Kontrakt) —
  außer dem `shadow`-Basenamen, der bei `0o100600` root:root floored, selbst
  wenn das Overlay fehlt oder korrupt ist, sodass ein verlorenes Overlay die
  On-Card-Passwort-Datei nie exponieren kann. Das Overlay schützt sich selbst
  durch seinen eigenen Eintrag; ein malformed Overlay wird komplett abgelehnt
  (laute Boot-Message, Defaults + Floor gelten). Das Editieren von `PERMS.TAB`
  wirkt beim nächsten Mount (Reboot).
- **Was wo geprüft wird.** `openFile` (Slot 7) prüft Read-Intent;
  `write` (Slot 33) prüft Write-Intent gegen die Metadaten, die das
  `File` seit open trägt; `execve` (Slot 31) prüft das Exec-Bit vor
  seinem Point of No Return. Verweigerung gibt `-EACCES` (-13, die erste und
  bisher einzige errno-Konstante, `lib/syscall_defs.flash`) zurück; jedes andere
  Failure behält das historische `-1`.
- **Die Regeln** (klassisches Unix, lean): Effective uid 0 bypasst
  alles (inklusive exec einer Datei ohne x-Bit — eine dokumentierte
  Vereinfachung); ansonsten entscheidet das erste passende Triad — Owner falls
  `euid` der uid der Datei matcht, sonst Group falls `egid` deren gid matcht,
  sonst Other — ohne Fall-through zu einem freundlicheren Triad.
- **Die privilegierte Tür.** Kernel-interne VFS-Opens laufen den Check nie:
  `sys_authenticate` liest `/etc/shadow` im Auftrag des Callers
  (das ist der Punkt — Userland bittet den Kernel zu verifizieren, der Kernel
  liest, was Userland nicht kann), und der execve-ELF-Streamer liest die
  Datei, die er bereits exec-geprüft hat.
- Carve-outs (aufgeschoben): Open-Flags (`O_RDONLY`/`O_WRONLY`),
  `chmod`/`chown`-Syscalls, Directory/readdir-Permissions, setuid-Bits,
  Supplementary-Groups, ACLs.

### Sicherheitsmodell

Es gibt einen Prozess-Identity- und Authentifizierungs-Layer: jeder Task
trägt Unix-Credentials, die interaktive Console ist hinter einem
Login-Prompt gegatet, und das Filesystem erzwingt Per-File-Permissions. Das
Ziel ist eine getreue, lehrbare Unix-artige Grenze — keine gehärtete
Multi-Tenant. Auf einem Single-Core-Kernel mit einem geteilten
Kernel-Address-Space ist die Grenze, die es tatsächlich verteidigt,
_unprivilegierter EL0-Prozess vs. privilegierter Kernel + root_: ein Prozess,
der Privilegien gedroppt hat, kann die Passwort-Hashes nicht lesen, kein
geschütztes File schreiben oder exec, was er nicht darf, und die Console kann
nicht ohne Passwort genutzt werden. Die ehrlichen Non-Goals sind am Ende
gelistet.

**Credentials.** Jeder Task trägt `uid` / `gid` / `euid` / `egid`
(`TaskStruct`), geerbt über `fork` und erhalten über `execve`.
Effective uid 0 ist root und bypasst jeden Permission-Check. Die geseedten
Accounts sind `root` (uid 0) und `flash` (uid 1000).

**Authentifizierungs-Flow.** PID 1 läuft die Test-Harness, exect dann
`/bin/login` (§4). login fragt nach einem Username (Console-Echo an) und einem
Passwort (maskiert mit `*` via `setConsoleMode`), bittet dann den Kernel, es
mit `sys_authenticate` (Slot 45) zu verifizieren. Der Kernel liest die
Shadow-Datenbank selbst, läuft PBKDF2-HMAC-SHA256 über das Passwort mit dem
gespeicherten Salt und Iteration-Count des Records und constant-time-vergleicht
gegen den gespeicherten Verifier; die KDF und jedes Salt-/Hash-Byte bleiben
im Kernel, sodass Userland nur Pass oder Fail sieht. Bei Erfolg **forkt** login
ein Child, das Privilegien droppt — `setgid` dann `setuid`, Group
zuerst während noch root — und die Shell des Users exect; login selbst bleibt
root, um die Session zu reapen und neu zu prompten, sodass `exit` ein Logout
zurück zu `login:` ist. Der Drop muss im Child leben: `setuid` ist One-Way für
einen Non-Root-Prozess, sodass ein login, das sich selbst gedroppt hätte, nie
eine zweite Session authentifizieren könnte.

**Shadow-Datenbank + Anti-Brick.** Das autoritative Shadow-File ist eine
schreibbare FAT32-Kopie bei `/mnt/shadow`; der Read-only-initramfs-
`/etc/shadow`-Seed ist der Fallback, wenn `/mnt` unmounted (QEMU virt),
abwesend (eine frische Karte) oder korrupt ist. Ein korrupter On-Card-Shadow
wird laut angekündigt und die eingebackenen Seed-Credentials funktionieren
weiter, sodass ein schlechter Write oder eine beschädigte Karte den Operator
nie aussperren kann. Als Defence-in-Depth wird der Shadow-Basename auf Mode
`0600` gefloored, selbst wenn kein Overlay-Eintrag ihn benennt.

**File-Permissions.** Jede offene Datei trägt eine `mode` / `uid` / `gid`.
initramfs-Files nehmen ihre Modes aus den cpio-Headern (der Build stempelt
`0600` auf shadow, `0755` auf Binaries, `0644` auf den Rest, alle
root:root); FAT32-Files defaulten auf `0666 root:root`, außer das optionale
Root-Level-`PERMS.TAB`-Overlay (`src/overlay.flash`) benennt sie. Die Checks
laufen an der Syscall-Grenze — `open` für Read-Intent, `write` für Write-
Intent, `execve` für das Exec-Bit — und entscheiden nach dem ersten passenden
Triad (Owner falls `euid` der uid der Datei matcht, sonst Group, sonst Other),
wobei Effective uid 0 bypasst. Eine Verweigerung gibt `-EACCES` (-13) zurück.
Kernel-interne VFS-Opens sind eine bewusste _privilegierte Tür_:
`sys_authenticate` liest das Shadow-File im Auftrag des Callers — das ist der
ganze Punkt, den Kernel zu bitten zu verifizieren — und der `execve`-Loader
liest das Image, das er bereits exec-geprüft hat.

**Ein Passwort ändern.** `sys_passwd` (Slot 46) / `/bin/passwd` re-hashen
mit einem frischen kernel-gemünzten Salt und schreiben den Record in
`/mnt/shadow` um. Root darf jeden Record ohne das alte Passwort zurücksetzen
(der Recovery-Pfad); jeder andere Caller darf nur den Record ändern, dessen
Name auf seine eigene uid mappt, und nur mit dem korrekten alten Passwort. Das
Umschreiben ist per Konstruktion splice-safe: der Iteration-Count bleibt
erhalten und Salt und Hash sind Fixed-Width-Hex, sodass die Zeile ihre
Byte-Länge behält und der Whole-File-Write den FAT32-Directory-Eintrag nie
resized.

**Secure by Default.** Ein für Hardware gebauter Kernel bootet immer zu einem
echten `login:` und verlangt ein Passwort. Der Unattended-CI-Watchdog — der
keinen Tipper hat und die Console aus `/dev/null` speist — würde dort
für immer hängen, sodass PID 1 die Test-Credentials _nur_ console-injectet,
wenn der Kernel mit `-Dci-login-seed=true` gebaut ist. Das Flag defaultet auf
**false**: ein geshipptes Image auto-loggt sich nie ein, und ein Watchdog, der
das Flag vergisst, failt laut (er timeoutet bei `login:`), statt ein still
passwortfreies System zu booten.

**Credential-Integrität ist strukturell.** Der Kernel-Stack jedes Tasks ist
seine eigene Page, separat vom `TaskStruct`, das seine Credentials speichert
(§8). Das schließt eine Klasse von Bug, wo der tiefste Syscall-Stack — die
`authenticate`-PBKDF2-Chain — plus ein verschachtelter Timer-IRQ-Frame in die
`uid` / `euid`-Felder überlaufen und einen Privilege-Drop fehlschlagen lassen
könnte; mit dem Stack auf einer anderen Page als die Credentials kann ein
Overflow sie nicht mehr erreichen. Die `[TEST] authenticate`-Canary bewacht
die Regression.

**Non-Goals (dieses Release).** Das Modell ist bewusst lean: kein `chmod`
/ `chown`, kein Open-Flag (`O_RDONLY` / `O_WRONLY`)-Intent jenseits des
Read/Write-Splits oben, keine Directory- oder `readdir`-Permissions, keine
setuid-Bits, keine Supplementary-Groups oder ACLs und kein Saved-uid
(`setresuid`). Effective uid 0 bypasst sogar das Exec-Bit. Es ist ein
Single-Core-Kernel mit einem geteilten Kernel-Address-Space; dies ist ein
Research- und Teaching-Security-Modell, keine gehärtete Isolations-Grenze.

### Console-Subsystem

Der Board-IRQ-Handler (`src/board/{rpi4b,virt}/irq.flash`) leert das
UART-RX-FIFO bei jedem IRQ-Slot und pusht jedes Byte in einen 256-Byte-
BSS-residenten Ring in `src/console.flash` via `console_push`. Der Ring
ist per Konstruktion Single-Producer (IRQ) / Single-Consumer (Syscall)
auf Single-Core. `console_push` weckt die Per-Ring-`WaitQueue`
(`src/wait_queue.flash`); der Console-Read-Pfad blockiert darauf, wenn der
Ring leer ist, und leert einen Short-Read beim Wake. Die Echo-Policy lebt im
User-Space — der Kernel loopt das Byte _nicht_ zurück durch den
TX-Pfad. Wenn der Ring voll ist, droppt `console_push`
(`src/console.flash:54`) das einkommende Byte still; das ist
korrekt für den aktuellen Human-Typing-Rate-Use-Case und ein zukünftiger Line-
Buffered-Terminal-Mode wird es nicht ändern. Console-
und Pipe-Reads sind hinter einem einzigen `sys_read(fd, buf, len)`
vereinheitlicht, das auf den getaggten `fds`-Slot dispatcht (§4
„File-Deskriptor-Modell"); das frühere Per-Kind-`sys_readConsole` ist
ausgemustert (seine Slot-Nummer bleibt reserviert und gibt `-1` zurück).

### USB-C-Gadget-Console (CDC-ACM)

Der USB-C-Port des Pi ist ein zweiter Console-Transport. Der
DWC2-USB-OTG-Controller des BCM2711 wird als Full-Speed-USB-_Device_
von `src/board/rpi4b/usb.flash` hochgefahren: `kernel_main` ruft
`usb_init()` nach dem GIC-Bring-up, und die PID-0-Idle-Loop bedient den
Controller durch Pollen von `GINTSTS` (`board.usb.poll()`) neben dem UART-
RX-Backstop — keine IRQ-Line, Slave-/PIO-Mode, kein DMA. Das Device
enumeriert als CDC-ACM-Serial-Funktion (byte-exakte Descriptors in
`src/usb_descriptors.flash`, host-getestet); macOS bindet seinen eingebauten
`AppleUSBCDCACM`-Treiber und erstellt `/dev/tty.usbmodemXXXX`.

**Connection-Management.** Das Gadget wird bei `usb_init` nicht
host-sichtbar. Ein USB-Bus-Reset hardware-disarmt EP0, und der Host sendet
sein erstes SETUP ~20 ms nach Ende eines Resets — sodass die
Enumeration nur funktioniert, während die Idle-Loop mit Mikrosekunden-Rate
pollt, was während der Boot-Test-Harness nie der Fall ist (und macOS
deaktiviert einen Port dauerhaft nach ein paar fehlgeschlagenen
Enumerations-Versuchen). `usb.flash` hält das Device daher elektrisch
detached (`DCTL.SftDiscon`), bis `poll()` 2 s gap-free gelaufen ist
(sustained Idle, gemessen off CNTPCT), und asserted erst dann den D+-Pull-up.
Eine steckengebliebene Enumeration (10 s attached ohne `SET_CONFIGURATION`)
self-healt via einen 1-s-Detach-Puls — elektrisch ein Replug, der auch
den Port-State des Hosts resettet. Der Scheduler-Timer-Tick pollt den Core
zusätzlich, während nicht enumeriert: ein 1-Hz-Backstop, sodass
Reset-/Enumerations-State weiterbewegt, wenn das System busy ist, und der
Connection-Manager self-healt, sobald Idle zurückkehrt.

Console-Flow einmal enumeriert:

- **RX (Host → fsh).** Bulk-OUT-Pakete leeren aus dem geteilten RX-FIFO
  in `console.console_push` — derselbe Ring, den der UART-RX-Pfad speist —
  sodass `sys_read(0, …)`, das Wait-Queue-Blockieren und fsh keine
  Änderungen brauchen; die Byte-Quelle ist für den User-Space unsichtbar.
- **TX (fsh → Host).** Der User-Write-Pfad (`writeConsoleBytes` /
  `sys_writeConsole` in `src/sys.flash`) geht durch einen `console_tx`-
  Mux: `board.usb.cdc_tx` wenn `enumerated()`, sonst die Mini-UART
  (ein Switch, kein Tee). `cdc_tx` enqueuet in einen bounded
  preempt-guarded TX-Ring; die Poll-Loop leert ihn in das EP2-IN-
  FIFO in 64-Byte-Chunks. Ein voller Ring spinnt kurz, dann droppt — der
  Kernel blockiert nie auf einem Host, der aufgehört hat zu lesen.

Kernel-`[Debug]`-Prints, der OOM-Trace und der Bring-up-Trace des USB-Treibers
selbst bleiben unbedingt auf der Mini-UART; die USB-Console trägt nur den
User/fsh-Byte-Stream. Unter QEMU (`raspi4b` modelliert die DWC2-Register,
aber nicht den Device-Mode-Data-Pfad) failt `usb_init` soft mit `-1` und die
Console fällt auf die Mini-UART zurück — das hält den CI-Boot-Watchdog grün und
ist auch das No-Cable-Verhalten auf echter Hardware. Replug-Re-Enumeration wird
vom Connection-Manager gehandhabt: auf einer Mac-powered Bench power-cyclet ein
Replug den Pi, und das Gadget re-enumeriert deterministisch, sobald der frische
Boot Sustained-Idle erreicht. Ein IRQ-getriebener Service-Pfad bleibt
Future Work.

## 6. Kernel-Symboltabelle (ksyms)

Die Trace-Maschinerie schlägt Funktionsnamen per Adresse nach. Die Table ist
Teil des gelinkten Images, sodass der Build ein Two-Pass-Prozess ist:

1. **Pass 1.** `zig build` linkt `kernel8.elf` mit einer Platzhalter-
   `_symbols`-Section, groß genug, um die populierte Table zu halten
   (`scripts/generate_syms.zig:pre_allocated_size`).
2. **Extraktion.** `zig build populate-syms` läuft
   `aarch64-elf-nm -n kernel8.elf | sort | grep -v '\$' | zig run scripts/generate_syms.zig`, das
   `src/symbol_area.S` mit `.quad` / `.string` / `.space`-Direktiven
   überschreibt — ein 64-Byte-Eintrag pro Symbol, terminiert von einem
   Zero-Byte-Sentinel.
3. **Pass 2.** Ein weiteres `zig build` relinkt mit der populierten Section.

Der `build`-Helper (aus `flashos.zsh`) läuft beide Passes und
diff-checkt, dass das Symbol-Layout konvergierte (d. h. das Einfügen der
Symbol-Daten störte keine Adressen).

## 7. Tracing

- `-fpatchable-function-entry=2` ist im aktuellen Build nicht aktiviert,
  sodass die Patchable-Functions-Section leer ist und
  `trace_init` effektiv ein No-op ist. Die Runtime-Maschinerie ist
  intakt und bereit, wieder verdrahtet zu werden, sobald das Zig-Backend ein
  äquivalentes Flag bekommt.
- Wenn Patchable-Einträge existieren, reloциert `trace_init`
  (`src/trace/trace_main.zig`) die Adress-Table, überschreibt
  den ersten `nop` jedes Eintrags mit `mov x9, lr` und patcht dann den
  zweiten `nop` mit `bl hook`.
- `hook` (`src/trace/hook.S`) sichert die Argument- und Link-Register,
  ruft `traced`, stellt sie wieder her und `blr`t dann in die ursprüngliche
  Funktion. `traced` löst die Adresse mit `ksym_name_from_addr` auf
  und druckt den Symbol-Namen auf der PL011-Trace-UART.

## 8. Testen

FlashOS shippt zwei komplementäre Test-Surfaces.

**Host-seitige Unit-Tests** (`zig build test`).
Pure-Logic-Kernel-Module können ohne die AArch64-Runtime getestet werden.
Jedes getestete Kernel-Modul ist sein eigener Test-Root, gelinkt gegen ein
Host-Stub-Objekt, das die Assembly-only-Externs füllt (`memzero`,
`panic`, `main_output*`, `core_switch_to`, `set_pgd`, das IRQ-
Masking-Paar, die Page-Allocator-Entry-Points). Das geteilte Stub-Set
lebt in `tests/host_stubs.zig`; `sched.flash` und das
initramfs/file-Paar bekommen dedizierte Per-Target-Stub-Objekte
(`tests/host_stubs_sched.zig`, `tests/host_stubs_initramfs.zig`,
`tests/host_stubs_vfs.zig`), um
Doppel-Definitionen von Symbolen zu vermeiden, die das Modul-under-Test bereits
exportiert. Die aktuelle Suite umfasst insgesamt **464 Host-Tests** über 41
Module — siehe die Coverage-Matrix unten für den Per-Modul-Split.

**In-Kernel-Runtime-Harness** (`user_space/kernel_tests.flash`).
PID 1 tritt in `run_all()` ein, das dreißig Szenarien auf echtem
Kernel-State ausübt:

- `fork-stress` — 3 × 5 Fork/Reap-Runden mit Per-Round- und finalen
  Free-Page-Count-Baseline-Checks.
- `oom-graceful` — akkumuliert Children (jedes `sys_exit`t sofort, aber ein
  laufendes-oder-zombiehaftes Child hält einen `task[]`-Slot), bis `fork()`
  `-1` beim 64-Slot-Cap zurückgibt, asserted das saubere `-1` (kein Crash, kein
  halbgebauter Zombie), reapt alle und checkt, dass die Baseline
  wiederhergestellt ist. Der echte Page-Pool wird nie erschöpft (das 8-MiB-
  Live-Memory-Ceiling); der Slot-Cap ist der deterministische Limiter, sodass
  das Szenario auf beiden QEMU-Targets identisch ist. Nur nach dem
  Page-Allocator- / Kernel-Image-Overlap-Fix erreichbar (siehe CHANGELOG).
- `kill` — forke ein Child, kille es per pid, Parent reapt.
- `exec-elf` — forke ein Child, `exec` `/test/hello.elf` durch den
  ELF-Pfad (Parser + PT_LOAD-Walk + eager Top-Stack-Page),
  Parent reapt.
- `execve` — forke ein Child, `sys_execve("/test/argv_echo.elf",
{"argv_echo","A","B"})` durch den path-aufgelösten ELF-Loader (Slot
  31): VFS-Resolve + Whole-File-Stream in den statischen
  `exec_buf` + argv-on-Stack + Address-Space-Teardown + Remap. Child
  läuft bis zur Completion, Parent reapt; der Teardown gibt die alten Pages
  frei und der Reap sweept die Allokationen des Loaders, nettend zur Baseline.
- `brk` — forke ein Child, wachse Heap um 16 Pages (jeder Touch feuert
  den Heap-Range-Demand-Alloc von `do_data_abort`), lies Pattern zurück,
  shrinke zur Baseline, Parent reapt.
- `stack-overflow` — forke ein Child, `exec` `/test/stackbomb.elf`,
  Child rekursiert über `STACK_LOW` in die Guard-Page, Kernel zombiet
  via `[KERN] stack overflow`, Parent reapt.
- `wild-pointer` — forke ein Child, schreibe zu `0xDEADBEEF000`
  (Heap-Stack-Gap), Kernel zombiet via `[KERN] invalid uva`, Parent
  reapt.
- `efault-syscall` — übergib eine Wild-Canonical-UVA an `sys_openFile` und
  asserted, dass es `-1` zurückgibt **ohne den Caller zu zombifizieren** (das
  Soft-Bein von `mm_user.check_and_prefault_user_range`).
  Kein Fork; Baseline hält (ein Parity-`sys_dump_free`).
- `flibc` — forke ein Child, `exec` `/test/flibc_demo.elf` (gebaut gegen
  `user_space/lib/flibc/`), Demo läuft `printf("flibc hello %d\n", 42)`
  - 32-Byte-malloc + Pattern-Verify + `exit`, Parent reapt. Validiert
    flibcs printf / Bump-Allocator / exit-Layers End-to-End durch den
    ELF-Loader.
- `pipe` — forke ein Child, übergib eine 16-Byte-Payload durch eine anonyme
  Pipe (Parent liest, Child schreibt), schließe beide Enden, Parent reapt.
  Validiert `sys_pipe`-Allokation, `fork`-Dup der vereinheitlichten `fds`-
  Table, den vereinheitlichten `read` / `write`-Round-Trip über die Pipe-Enden
  und `close`-Ref-Drop + Page-Free.
- `console-echo` — forke ein Child, das 8 deterministische Bytes
  (`0xC0..0xC7`) via `sys_console_inject` nach einem kurzen Delay injectet,
  Parent blockiert im vereinheitlichten `sys_read` auf dem vorinstallierten
  Console-fd 0 (leerer Ring, deckt den `console.rx_wq.wait`-Pfad), leert via
  Short-Reads, bis die Payload gesammelt ist, dann Byte-Vergleich. Free-Page-
  Baseline weiterhin das [PASS]-Gate. Läuft komplett über die vereinheitlichte
  `fds`-Table.
- `fd-redirect` — treibt die vereinheitlichte `read`/`write`/`close`/`dup2`-ABI
  (Slots 32-35) End-to-End über eine Fork-Grenze, so wie eine Shell
  einem Child ihr redirektetes stdio übergibt. `sys_pipe` → `fork` → Child
  `sys_dup2(wfd, 1)` dann `sys_write(1, …)` (fd 1 startet als Console-
  Slot, sodass der Write beweist, dass dup2 ihn auf das Pipe-Backend re-pointet) →
  Parent `sys_dup2(rfd, 0)` dann `sys_read(0, …)` → 16-Byte-
  Byte-Vergleich → beide Enden schließen alle fds → Child exitet, Parent reapt.
  Die Refcount-Choreografie gibt die Pipe-Page beim finalen
  `sys_close(rfd)` des Parents vor dem Checkpoint frei, sodass die Baseline
  hält.
- `initramfs-open` — `sys_openFile("/sbin/init")` + vereinheitlichtes `read`
  der ersten 4 Bytes, asserted ELF-Magic `0x7f 'E' 'L' 'F'`, vereinheitlichtes
  `close`, Baseline hält. Demonstriert den Read-only-File-Pfad
  End-to-End gegen das eingebettete initramfs.
- `vfs-dispatch` — übt die zwei Beine des VFS-Shims: `/sbin/init`
  löst durch das initramfs-Backend auf (positiv, fd ≥ 0 + sauberes
  close), `/mnt/this-does-not-exist` routet zum FAT32-Stub und
  gibt -1 zurück (negativ-aber-geroutet), `/mnt` ohne Trailing-Slash
  bleibt ein initramfs-Pfad und fehlt dort. Asserted den Dispatch-
  Kontrakt, nicht den Mechanismus; Baseline hält (eine File-Page
  allokiert und freigegeben).
- `trace` — vier sequenzielle Fork/Exit/Wait-Zyklen, die die
  gepatchten Trampolines `copy_process` (fork), `do_wait` (wait) und
  `_schedule` (Timer-Tick + expliziter Yield) ausüben. Auf Pi landet das
  `bl hook` der Trampolines auf PL011 (UART4) mit jedem kanonischen Namen; auf
  virt ist `pl011_uart_send_string` comptime-gestubbt und der Patch-Pfad
  läuft still. Das Pass-Kriterium spiegelt die anderen reap-basierten
  Szenarien: Free-Page-Count nach der Loop gleich der Suite-Baseline.
- `fs-roundtrip` — das Variant-B-Magic-File-Persistence-Szenario.
  Öffnet `/mnt/ROUNDTR.MAG`: ein negativer fd bedeutet `/mnt` ist unmounted
  (kein FAT32 — **Mount-detected SKIP**, `[PASS] fs-roundtrip (skip)`,
  ein Parity-`sys_dump_free`). Magic-Byte `0` → First-Boot-Phase:
  schreibe ein 4-KiB-Pattern zu `/mnt/ROUNDTR.DAT` via das vereinheitlichte
  `write`, setze magic = 1, emittiere
  `[PASS] fs-roundtrip-write (reboot to verify)`.
  Magic-Byte `1` → Second-Boot-Phase: lies `ROUNDTR.DAT` zurück,
  Byte-Vergleich gegen die Formel, resette magic zu `0`, emittiere
  `[PASS] fs-roundtrip`. Baseline-Check gatet jeden Non-Skip-Branch.
  Dies ist das einzige Szenario, das einen Power-Cycle quert, sodass es
  `fat32_backend.writeBack` + Persistence End-to-End validiert —
  **aber nur auf echter Pi-4-Hardware**: QEMU `-M raspi4b` kann
  EMMC2 CMD8 nicht bestehen und `virt` hat kein SD-Device, sodass auf beiden
  QEMU-Boards dieses Szenario den SKIP-Pfad nimmt (siehe §3). Der Pi-HW-Operator
  läuft es zweimal über einen Reboot.
- `readdir` — das Directory-Enumeration-Szenario. Durchläuft
  `/bin` via das rohe `sys_readdir(path, index, *Dirent)` von `index = 0`,
  asserted, dass die bekannten Coreutils `fsh` **und** `ls` vorhanden sind
  (unbeeinflusst von `/bin`-Wachstum; ein exakter Count wäre brüchig), das
  End-Sentinel feuert (der Call jenseits des letzten Eintrags gibt -1 zurück,
  kein Runaway), und der zustandslose Walk nichts leakt (Free-Count gleich
  Baseline — der eine neue `sys_dump_free`-Checkpoint, den dieses Szenario
  hinzufügt). QEMU übt das initramfs-Synthesized-Directory-Bein (der Root-Mount);
  das FAT32-8.3-Bein ist nur Pi (`/mnt/*` mountet nicht unter QEMU → -1 sauber).
- `klog` — das Kernel-Log-Szenario. Ruft `sys_dump_free` (das
  `free_pages:` durch das `main_output` des Kernels emittiert, es in den
  Ring tee'nd), dann `sys_klog_read` für die neuesten 256 Bytes, und asserted,
  dass der gerade emittierte `free_pages`-Marker vorhanden ist — den
  `main_output` → Ring-Tee und den Slot-38-Snapshot-Pfad beweisend. Der Marker
  ist kernel-emittiert, sodass die Assertion vom USB-Console-State auf jedem
  Target unbeeinflusst ist. Das einzelne `sys_dump_free` dient doppelt als
  Baseline-Checkpoint; der Static-BSS-Ring und der warmed-Stack-Snapshot-Buffer
  halten es leak-free. `/bin/dmesg` ist der interaktive Consumer (nicht von der
  Harness getrieben, wie `meminfo` / `forkbomb`).
- `rng` — das Kernel-Entropy-Szenario. Läuft **zuerst** in der
  Szenario-Reihenfolge per Kontrakt: es snapshottet die neuesten 4 KiB des
  Kernel-Log-Rings via `sys_klog_read` und asserted, dass der Boot-Time-Entropy-
  Announce vorhanden (`hwrng:`) und gesund ist (`hwrng: self-test failed`
  abwesend) — beweisend, dass `hwrng_init` lief, sein Two-Draw-Self-Test bestand,
  und der Announce den Ring erreichte. Zuerst zu laufen hält den Gap zwischen
  dem Boot-Announce und dem Snapshot bounded; zuletzt zu laufen würde mehrere
  KiB Harness-Output dazwischen legen, jenseits jedes Baseline-safe Stack-Fensters.
  Beide QEMU-Targets nehmen den schwachen Timer-Mix-Fallback (QEMU emuliert
  keinen BCM2711-RNG200); der Hardware-Pfad ist nur Pi-Bench. Das einzelne
  `sys_dump_free` dient doppelt als Baseline-Checkpoint; der 4-KiB-Snapshot-
  Buffer ist ein Scenario-Frame-Stack-Array (dasselbe Budget wie der Payload-
  Buffer von `fs-roundtrip`), sodass das Szenario leak-free ist.
- `creds` — das Prozess-Credential-Szenario. PID-1 asserted, dass seine
  eigenen Getter root berichten, forkt dann ein Child, das Privilegien droppt
  (`setgid(1000)` + `setuid(1000)`), die Getter neu liest und verifiziert, dass
  ein gedroppter Prozess `setuid(0)` verweigert wird. Das Child berichtet ein
  einzelnes Y/N-Verdict über eine Pipe, sodass PID-1 selbst nie root droppt
  (es muss root bleiben, um `/bin/login` nach der Harness zu exec). Reap-basiert
  und baseline-neutral wie `pipe` / `fork-stress`.
- `authenticate` — das Kernel-Credential-Verify-Szenario. Treibt
  `sys_authenticate` direkt: der geseedte CI-Account muss verifizieren (0), ein
  falsches Passwort und ein unbekannter User müssen beide fehlschlagen (-1).
  Auch eine Kernel-Stack-Overflow-Canary: es liest PID-1s eigene Credentials
  nach den Auth-Calls erneut. Die Crypto-Call-Chain ist der tiefste Syscall-
  Stack im Kernel; bevor der Kernel-Stack jedes Tasks auf seine eigene
  Page zog, teilte der Stack eine Page mit dem `TaskStruct`, und ein tief
  genuger Frame überlief zuerst in die Credential-Felder — sodass diese Canary
  zu `[FAIL]` flippt, falls diese Regression je zurückkehrt. Kein Fork;
  `/etc/shadow` wird durch den No-Alloc-VFS-Pfad des Kernels gelesen, sodass das
  Szenario baseline-neutral ist.
- `perm` — das VFS-Permission-Szenario. Forkt ein Child, das
  auf uid/gid 1000 droppt und die Enforcement-Points probet: `/etc/shadow` zu
  öffnen (Mode `0o100600` root:root) muss mit genau `-EACCES` (-13 — ein
  bloßes -1 würde „not found" bedeuten, d. h. der Permission-Layer feuerte nie)
  fehlschlagen, `/etc/passwd` zu öffnen (`0o100644`) muss gelingen, und `execve`
  dieses No-x-Bit-Files muss ebenfalls mit genau `-EACCES` fehlschlagen. Das
  Child berichtet ein Y/N-Verdict über eine Pipe; PID-1 (noch root) öffnet dann
  dasselbe Shadow-File erneut erfolgreich, den Root-Bypass beweisend. Reap-
  basiert und baseline-neutral wie `creds`.
- `login` — der Login-Lifecycle-Capstone. Injectet ein Two-Session-
  Console-Script (`flash`, dann `root`, jedes endend in `exit`), forkt ein
  Child, das das echte `/bin/login` mit seinem Session-Limit-argv exect
  (`"2"`), und reapt es. login authentifiziert jede Session, forkt ein Child,
  das Privilegien droppt und die Shell exect, reapt es bei `exit` und
  re-promptet — der volle Supervisor-Lifecycle durch die echte Binary. Jede
  Session emittiert fshs Homescreen-Marker (`type 'help' for commands`), sodass
  ein grüner Boot drei trägt (zwei von hier + das echte Boot-
  Login); `scripts/run_qemu_test.sh` keyt sein Success-Kriterium und
  guardet auf genau diese Counts. Reap-basiert und baseline-neutral — der
  ganze Tree (login + zwei Session-Shells) muss reclaimed werden.
- `passwd` — das Passwort-Änderungs-Szenario. Auf einem Board mit einem
  schreibbaren FAT32-Shadow (`/mnt/shadow` — das QEMU-rpi4b-SD-Image und eine
  deployte Karte sind damit geseedt) läuft es den vollen Roundtrip: root
  resettet den `flash`-Record ohne das alte Passwort (der Self-Healing-
  Recovery-Pfad), rotiert es zu einem Temp-Passwort und beweist die Änderung
  durch `sys_authenticate` (neu verifiziert, alt hört auf zu funktionieren),
  dann wird einem gedroppten Child (uid 1000) ein fremder Record und sein
  eigener Record mit einem falschen alten Passwort verweigert (beide genau
  `-EACCES`), bevor es das Seed-Passwort durch den legitimen Own-Record-+-
  Correct-Old-Password-Pfad wiederherstellt. Auf virt (keine SD-Karte) muss
  `sys_passwd` das dokumentierte `-1` beantworten und das Szenario emittiert
  `[PASS] passwd (skip)` — dasselbe SKIP-Pattern wie
  `fs-roundtrip`. Trägt dieselbe Kernel-Stack-Canary wie `authenticate`.

Jedes Szenario emittiert `[TEST] name` … `[PASS] name` (oder `[FAIL]`), und
`run_all` druckt einen finalen `X/Y passed`-Tally. Die Harness läuft
identisch unter QEMU (`zig build -Dboard=virt run-virt` /
`-Dboard=rpi4b run`) und auf echter Hardware (`build -d` → SD-Flash →
`picapture`); ein grüner Run landet `30/30 passed` mit 34 Baseline-
Checkpoints (`0xbbff2` rpi4b / `0x3be45` virt) und 0 `ERROR CAUGHT`
auf beiden Boards, übergibt dann an
`/bin/login` → `/bin/fsh`. Mit dem Login-Lifecycle erscheint fshs Homescreen-
Marker (`type 'help' for commands`) **dreimal** pro Boot —
zweimal von den gescripteten Sessions von `[TEST] login` und einmal vom echten
Boot-Login — und der CI-Watchdog (§4) zählt genau das (sein Early-Exit
feuert beim dritten Homescreen-Marker). (In QEMU ist der
`fs-roundtrip`-Checkpoint sein Parity-`sys_dump_free` auf dem SKIP-Pfad;
auf Pi-HW ist es der echte Write/Verify-Branch. Es gibt kein In-Harness-
`fsh`-Szenario — die Shell wird durch die Übergabe oben plus den
`[TEST] login`-Capstone ausgeübt.)

**Pre-PID-1-EL1-Smoke** (`run_emmc2_smoke` in `src/kernel.flash`).
Ein einzelnes Szenario `emmc2-block` läuft, bevor PID 1 geforkt wird,
schreibt ein deterministisches 512-Byte-Pattern zu LBA 2064 durch
`board.emmc2.write_block`, liest es via `read_block` zurück und
byte-vergleicht. Emittiert `[TEST] emmc2-block` … `[PASS] emmc2-block`
oder `[FAIL] emmc2-block (write|read|mismatch)`. Auf QEMU
übt es das virt-Fake (`src/board/virt/emmc2.flash`); auf Pi 4 übt es
den echten BCM2711-EMMC2-Treiber (verifiziert auf einer 64-GB-SDXC).
Der EL0-30/30-Tally ist unbeeinflusst — beide
Buffer leben auf dem Kernel-Stack und das Szenario läuft im Kernel-
Kontext.

### Behoben — Real-HW-Tally-Flackern

Auf echtem Pi-4 emittierte die EL0-Harness intermittierend einen `18/19`-Tally
(gegen die damals-aktuellen 19 Szenarien), nachdem Commit `55b9515` einen
Per-Tick-Timer-Trace-Print entfernte. Dieser Print hatte die Root-Cause
maskiert: der Scheduling-Tick wurde mit einem **relativen** `CNTP_TVAL`-
Write neu-armiert, sodass Interrupt-Latency in die Tick-Periode auf
echter Hardware akkumulieren konnte. Der Fix schaltete den Timer auf eine
absolute `CNTP_CVAL`-Deadline mit einem Catch-up-Clamp um; das Flackern hat sich
seither nicht reproduziert (14 aufeinanderfolgende grüne Pi-4-Boots beim
Release). QEMU-Runs waren nie betroffen — beide Boards waren durchgehend
deterministisch. Das Boot-Success-Kriterium (der `type 'help' for commands`-
Homescreen-Marker, den der Watchdog matcht, siehe §4 PID-1 → fsh-Übergabe) ist
vom Tally unabhängig, so oder so: ein einzelner später Tick erreicht immer noch
den interaktiven Prompt, und der no-`[FAIL]`- / Checkpoint-Count-Guard des
Watchdogs fängt immer noch ein regrediertes Szenario.

### Free-Page-Invarianten

Die Harness nutzt `sys_dump_free`, um zu verifizieren, dass jedes Szenario
leak-free ist:

- **Kernel-Boot-Baseline:** `0xbc000` — einmal von `kernel_main`
  (`src/kernel.flash`) emittiert, bevor PID 1 erstellt wird. Gleich 4 GiB Pi
  minus VC-Reservation, Kernel-Image und die Identity- + High-Page-Tables.
- **User-Space-Baseline:** `0xbbff2` — von PID 1 beim Eintritt in
  `run_all` emittiert. Gleich der Boot-Baseline minus 14 Pages, die vom PID-1-
  Setup beansprucht werden (ELF-Text + Page-Table-Chain + eager Top-Stack-Page +
  `run_all`s Stack-Warm-up + seine eigene Kernel-Stack-Page + Bookkeeping).
  Jedes leak-free Szenario muss bei diesem selben Wert enden. Die 14. Page ist
  PID 1s eigene Kernel-Stack-Page — jeder Task bekommt seine eigene, der Fix,
  der einen Deep-Syscall-Stack-Overflow aus den Credential-Feldern hält (siehe
  „Sicherheitsmodell" in §5).

Ein voller QEMU- oder Pi-Run druckt 34 `free_pages:`-Zeilen: 1 Kernel-Boot-
Baseline + 1 User-Space-Baseline + 1 Checkpoint pro fork-stress-Runde
(3 Runden) + 1 fork-stress-final + 1 je für rng / oom-graceful / kill /
exec-elf / execve / brk / stack-overflow / wild-pointer / exec-fault /
undef-instr / efault-syscall / flibc / pipe / console-echo / fd-redirect /
initramfs-open / vfs-dispatch / trace / fs-roundtrip / readdir / klog /
hwmon-core / hwmon-mailbox / creds / authenticate / perm / login / passwd —
d. h. 34 × `0xbbff2` (die User-Space-Baseline plus 33 Szenario-Checkpoints) +
1 × `0xbc000`.

```text
free_pages: 00000000000bc000   (kernel boot baseline)
free_pages: 00000000000bbff2   (PID 1 baseline)
free_pages: 00000000000bbff2   (rng)
free_pages: 00000000000bbff2   (fork-stress round 1)
free_pages: 00000000000bbff2   (fork-stress round 2)
free_pages: 00000000000bbff2   (fork-stress round 3)
free_pages: 00000000000bbff2   (fork-stress final)
free_pages: 00000000000bbff2   (oom-graceful)
free_pages: 00000000000bbff2   (kill)
free_pages: 00000000000bbff2   (exec-elf)
free_pages: 00000000000bbff2   (execve)
free_pages: 00000000000bbff2   (brk)
free_pages: 00000000000bbff2   (stack-overflow)
free_pages: 00000000000bbff2   (wild-pointer)
free_pages: 00000000000bbff2   (exec-fault)
free_pages: 00000000000bbff2   (undef-instr)
free_pages: 00000000000bbff2   (efault-syscall)
free_pages: 00000000000bbff2   (flibc)
free_pages: 00000000000bbff2   (pipe)
free_pages: 00000000000bbff2   (console-echo)
free_pages: 00000000000bbff2   (fd-redirect)
free_pages: 00000000000bbff2   (initramfs-open)
free_pages: 00000000000bbff2   (vfs-dispatch)
free_pages: 00000000000bbff2   (trace)
free_pages: 00000000000bbff2   (fs-roundtrip)
free_pages: 00000000000bbff2   (readdir)
free_pages: 00000000000bbff2   (klog)
free_pages: 00000000000bbff2   (creds)
free_pages: 00000000000bbff2   (authenticate)
free_pages: 00000000000bbff2   (perm)
free_pages: 00000000000bbff2   (login)
free_pages: 00000000000bbff2   (passwd)
```

Jede Abweichung indiziert einen Leak im Szenario oberhalb des abweichenden
Checkpoints.

Das Beispiel oben zeigt die rpi4b-Werte. Auf virt gilt dieselbe Struktur
mit dem eigenen Paar des Boards — Boot-Baseline `0x3be53`,
Per-Szenario-Checkpoint `0x3be45` — kleiner, weil virt 1 GiB
RAM hat und sein Kernel _innerhalb_ des Page-Pool-Fensters geladen wird, sodass
`mem_map_reserve_below` das Kernel-Image (inklusive der
128-KiB-`_symbols`-Section und des 16-KiB-klog-Rings) und den 64-MiB-
`.sdscratch`-Buffer vom Pool subtrahiert. Der Per-Task-Kernel-Stack-Page-Fix
— jeder lebende Task bekommt eine zweite Kernel-Page, sodass der Stack eines
Deep-Syscalls nie in seine `TaskStruct`-Credentials überlaufen kann (siehe
„Sicherheitsmodell" in §5) — verbreitert das Boot-zu-Szenario-Delta auf `0xe`
auf beiden Boards, die dokumentierten Paare landend: rpi4b `0xbbff2` / `0xbc000`
und virt `0x3be45` / `0x3be53`.

### Coverage-Matrix

Die Host-Spalte zählt Inline-`test "…"`-Blöcke in jedem Modul (via
`zig build test` gelaufen). Die Kernel-Harness-Spalte listet die `[TEST]`-
Szenarien in `user_space/kernel_tests.flash`, die das Modul End-to-End
auf QEMU + Pi 4 ausüben.

| Modul                                   | Host-Tests | Kernel-Harness-Szenarien                                                                                                                     | Grund falls host-ungetestet                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------------- | ---------: | --------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/page_alloc.flash`                  |         14 | jedes (Free-Page-Baseline)                                                                                                                    | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/elf.flash`                         |         16 | `exec-elf`, `stack-overflow`, `flibc`                                                                                                         | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/wait_queue.flash`                  |          4 | `pipe`, `console-echo`, `fd-redirect`                                                                                                         | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/pipe.flash`                        |          5 | `pipe`, `fd-redirect`                                                                                                                         | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/fdtable.flash`                     |          5 | `fd-redirect`, `pipe`, `console-echo`                                                                                                         | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/console.flash`                     |          7 | `console-echo`, `fd-redirect`                                                                                                                 | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/sched.flash`                       |         13 | jedes fork/kill/wait-Szenario                                                                                                                 | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/initramfs.flash`                   |         13 | `initramfs-open`, `vfs-dispatch`, `exec-elf`, `stack-overflow`, `flibc`, `readdir`, `perm`                                                    | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/file.zig`                          |          2 | `initramfs-open`, `vfs-dispatch`, `exec-elf`, `stack-overflow`, `flibc`, `fd-redirect`                                                        | fd-Table-Helper leben in `src/fdtable.flash`; die `alloc`/`ref`/`unref`-Lifetime-Tests bleiben hier                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `src/vfs.zig`                           |         19 | `vfs-dispatch`, `fs-roundtrip`, `initramfs-open`, `exec-elf`, `stack-overflow`, `flibc`, `readdir`                                            | die create/unlink/rename-Wrapper- + EROFS-Default-Tests sind host-only (Cross-Superblock-Rename-Ablehnung, Default-Stub-Fail-Closed)                                                                                                                                                                                                                                                                                                                                                                                                |
| `src/sdhci_cmd.flash`                   |         13 | `emmc2-block` (CMD17/CMD24-Encoding, CSD-v2-Parse, Clock-Divisor)                                                                             | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/mailbox.flash`                     |         19 | `emmc2-block` (Clock-Rate-Query für SDHCI-Divider; SD-VDD-Power-on und 3.3-V-I/O-Rail bei init); USB-C-Console (`usb_init`s USB-HCD-Power-on) | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/board/virt/dtb.flash`              |          4 | (virt-Boot-Übergabe)                                                                                                                          | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/fat32.flash`                       |         37 | `fs-roundtrip`, `vfs-dispatch`                                                                                                                | die create/unlink/rename-Primitives (finden/erweitern eines freien Dir-Slots, Schreiben/Löschen eines Eintrags, Freigeben einer Chain, FSInfo-Credit) sind hier host-getestet, inklusive der Directory-Extend- und Free-Count-Round-Trip-Fälle                                                                                                                                                                                                                                                                                        |
| `src/initramfs_backend.flash`           |          2 | `initramfs-open`, `vfs-dispatch`, `exec-elf`, `stack-overflow`, `flibc`, `readdir`, `perm`                                                    | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/fat32_backend.flash`               |         17 | `vfs-dispatch`, `fs-roundtrip`, `passwd`                                                                                                      | dünner VfsOps-Wrapper über `src/fat32.flash`; der echte SD-Read/Write-Pfad läuft nur auf Pi-4-Hardware (QEMU `raspi4b`-EMMC2 stirbt bei CMD8, `virt` hat kein SD), sodass die On-Disk-Decode-Logik stattdessen von `src/fat32.flash`-Host-Tests abgedeckt wird. Der Splice-Kontrakt (Sub-Sector- + Whole-File-Same-Length-Writes) und der Permission-Overlay-Parse/Apply sind hier host-getestet; FAT32-`readdir` wird von `[TEST] readdir` auf dem Pi-only-Bein ausgeübt (`/mnt/*` gibt -1 sauber unter QEMU; FAT32-Host-Tests decken den `decode8_3`-Helper) |
| `src/block_dev.flash`                   |          0 | `emmc2-block`                                                                                                                                 | pure vtable-Indirektion; Logik ≈ fn-Pointer-Forwarding                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `src/sys.flash`                         |          0 | jedes Syscall-Szenario                                                                                                                        | extern-heavy Dispatch; Logik ≈ Argument-Forwarding                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `src/fork.flash`                        |          5 | `fork-stress`, `oom-graceful`, `exec-elf`, `brk`                                                                                              | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/execve.flash`                      |          6 | `execve`, `perm`                                                                                                                              | argv-Block-Encoder (`encodeArgvBlock`) ist host-getestet; die Path-Resolve- + PT_LOAD-Stream- + Teardown-Pfade sind extern-heavy und integration-getestet via `[TEST] execve` + der PID-1-Übergabe an `/bin/fsh` (dieselbe Haltung wie `sys.flash` / `fork.flash`); das Exec-Bit-Permission-Gate wird von `[TEST] perm` ausgeübt                                                                                                                                                                                                     |
| `src/path.flash`                        |         16 | (PID-1-Übergabe)                                                                                                                              | pure cwd-aware Join + `.`/`..`-Kollaps (`joinResolve`); die Kernel-open/execve-Grenze und der Host-Test teilen diese Source; der Runtime-Pfad wird von der interaktiven fsh-Shell nach der Harness getrieben                                                                                                                                                                                                                                                                                                                          |
| `src/mm_user.flash`                     |         11 | `brk`, `stack-overflow`, `wild-pointer`, `efault-syscall`                                                                                     | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/utilc.flash`                       |         11 | jedes (jeder Print-Pfad)                                                                                                                      | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/klog_ring.flash`                   |          8 | `klog`                                                                                                                                        | pure Overwrite-Oldest-Ring-Arithmetik (push / snapshot, monotone u64-head/tail); der `main_output`-Tee (`src/utilc.flash`) und der Slot-38-Snapshot (`src/sys.flash`) sind von `[TEST] klog` integration-getestet                                                                                                                                                                                                                                                                                                                  |
| `src/sha256.flash`                      |         17 | `authenticate` (via `sys_authenticate`)                                                                                                       | pure Compute (SHA-256 / HMAC-SHA256 / PBKDF2-HMAC-SHA256 / `ctEql`); die Host-Vector-Tests (NIST FIPS 180-2, RFC 4231, publiziertes PBKDF2-Set) plus `std.crypto`-Differentials sind das Gate; `sys_authenticate` und das Build-Time-`tools/gen_shadow.zig` sind die Consumer                                                                                                                                                                                                                                                         |
| `src/shadow.flash`                      |         15 | `authenticate`, `passwd` (via `sys_authenticate` / `sys_passwd`)                                                                              | pure `/etc/shadow`-Zeilen-Parser + Hex-Encode/Decode + das Same-Length-In-Place-Rewrite (`rewriteLineInPlace`); die Host-Tests pinnen das `user:iterations:salt_hex:hash_hex`-Format, geteilt von `sys_authenticate` (verify), `sys_passwd` (rewrite) und `tools/gen_shadow.zig` (generate)                                                                                                                                                                                                                                          |
| `src/perm.flash`                        |          9 | `perm`                                                                                                                                        | pure `checkAccess`-Decision-Funktion; die Host-Truth-Table (owner/group/other × read/write/exec × root-Bypass) ist das Gate für den Permission-Layer; die drei Syscall-Boundary-Enforcement-Sites (`sys_openFile` / `sys_write` / `execve`) sind von `[TEST] perm` integration-getestet                                                                                                                                                                                                                                              |
| `src/overlay.flash`                     |         14 | `passwd` (via das geseedte `PERMS.TAB`)                                                                                                       | pure FAT32-Permission-Overlay-Parser + Case-Insensitive-Lookup; die Host-Truth-Table (well-formed / Comments / CRLF / malformed-rejects-wholesale / Capacity / Self-Entry) ist das Gate für das Overlay; der Mount-Time-Apply + Open-Time-Lookup leben in `src/fat32_backend.flash` und sind dort host-getestet                                                                                                                                                                                                                       |
| `src/pwfile.flash`                      |          7 | `login`, `passwd` (und `/bin/login` / `whoami` zur Runtime)                                                                                   | pure `/etc/passwd`-Parser (Name- + uid-Lookups), geteilt vom Kernel (`sys_passwd`-Autorisierung), `/bin/login`, `/bin/passwd` und fshs `whoami`-Builtin; die Host-Tests pinnen das 5-Feld-Format gegen `user_space/etc/passwd`                                                                                                                                                                                                                                                                                                       |
| `scripts/build_initramfs.zig`           |          2 | `perm` (via die staged initramfs-Modes)                                                                                                       | deterministischer newc-cpio-Encoder (ein Build-Time-Host-Tool, kein Kernel-Code); seine Host-Tests pinnen die Mode/uid/gid-Byte-Offsets, geteilt mit dem Parser von `src/initramfs.flash` — ein Encoder/Parser-Drift wäre ein stiller Permission-Bypass                                                                                                                                                                                                                                                                              |
| `src/hwrng.flash`                       |          6 | `rng`                                                                                                                                         | der pure SplitMix64-Mixer ist auf dem Host vector- und differential-getestet; das Kernel-Glue (`fill` / der `hwrng_init`-Announce) ist von `[TEST] rng` durch den klog-Ring integration-getestet                                                                                                                                                                                                                                                                                                                                    |
| `user_space/lib/flibc/readline.flash`   |         27 | (PID-1-Übergabe)                                                                                                                              | pure byte→buffer Line-Editor-Cores: die Append-only-State-Machine (TAB-Completion-Action), die Cursor-Edit-Ops (insert/backspace/move/replace) und der Command-History-Ring; der SVC-Driver sitzt hinter einem Comptime-`has_driver`-Gate, sodass der Host-Build nie Inline-asm analysiert; Runtime-Pfad = die interaktive fsh-Shell nach der Harness                                                                                                                                                                                 |
| `user_space/lib/flibc/execvp.flash`     |         13 | (PID-1-Übergabe)                                                                                                                              | pure `/bin/<name>`-Path-Build; SVC-Driver gegatet wie `readline`; Runtime-Pfad = die interaktive fsh-Shell nach der Harness                                                                                                                                                                                                                                                                                                                                                                                                          |
| `user_space/lib/flibc/completion.flash` |         12 | (PID-1-Übergabe)                                                                                                                              | pure Tab-Completion-Core (`parse` Command-vs-Path, `commonPrefixLen`, `classify` für die Double-TAB-Decision); das `readdir`-getriebene Candidate-Gathering + Double-TAB-Listing leben in `readline`s Completing-Driver; Runtime-Pfad = die interaktive fsh-Shell nach der Harness                                                                                                                                                                                                                                                    |
| `user_space/lib/flibc/keys.flash`       |          7 | — (Full-Screen-Tools)                                                                                                                         | pure VT100-Input-`Decoder` (`ESC[` Pfeile / ctrl / tab → `Key`); der SVC-`readKey`-Driver ist gegatet wie `readline` und liest durch die io-Seam; sein Runtime-Consumer ist `/bin/edit` (der Editor braucht das Extended-Key-Set), während `/bin/less` durch die `tui`-Run-Loop der Flash-Standard-Library dekodiert                                                                                                                                                                                                                  |
| `user_space/lib/flibc/pager.flash`      |         10 | — (Full-Screen-Tools)                                                                                                                         | pure Scroll- / Line-Index-Core (`Pager`: Line-Indexing, `line`-Slicing, Scroll-Clamping); kein SVC — der Render- + Key-Loop leben in `/bin/less`; Runtime-Pfad = `/bin/less` über die Serial-Console                                                                                                                                                                                                                                                                                                                                 |
| `lib/console_ui/screen.flash`           |          2 | — (Status-Tools)                                                                                                                             | pure ANSI-Line-Helper (Screen `clear`, aligned `kv`-Metric-Rows); `Sink`-geroutet, allocator-free; Consumer sind `/bin/sysinfo` / `/bin/cpuinfo` / `/bin/uptime` (`kv`) und `/bin/clear` (`clear`). Das Full-Screen-Alternate-Screen-Rendering, das Pager und Editor brauchen, lebt jetzt im `tui`-Render-Core der Flash-Standard-Library                                                                                                                                                                                             |
| `user_space/fsh/tokenize.flash`         |         11 | (PID-1-Übergabe)                                                                                                                              | pure Whitespace-Split + Single-Pipe-Dekomposition; der Shell-Driver (`fsh.flash`) ist integration-only via die PID-1 → fsh-Übergabe (der `type 'help' for commands`-Boot-Success-Marker)                                                                                                                                                                                                                                                                                                                                            |
| `tools/grep_match.flash`                |          8 | — (Coreutil)                                                                                                                                  | pure Windowed-Substring-Matcher mit optionalem ASCII-Case-Fold für `/bin/grep`; der Open/Read/Line-Assembly-Driver lebt in `tools/grep.flash`                                                                                                                                                                                                                                                                                                                                                                                       |
| `tests/host_alloc.zig`                  |          0 | —                                                                                                                                             | geteilter Bump-Allocator-Helper, von anderen Test-Roots konsumiert; trägt keine eigenen Inline-Tests                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `src/trace/*`                           |          0 | `trace`                                                                                                                                       | Runtime-Code-Patching; kein ICache-Sync host-seitig                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `src/trace/fp_walk.zig`                 |          6 | — (pure Host)                                                                                                                                 | AAPCS64-Frame-Record-Decoder für den `-Dtrace`-Sampler; die FP-Walk-Bounds- / Wrap- / Alignment- / Monotonic-Guards sind host-verifiziert (der Live-Sampler feuert nur auf Real-Pi-Async-Timer-Ticks)                                                                                                                                                                                                                                                                                                                               |
| `src/board/*/irq.flash`                 |          0 | Timer-Ticks,`console-echo`-RX                                                                                                                 | pure MMIO; Stubs würden Identity-Read                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `src/board/*/uart.flash`                |          0 | jeder Print                                                                                                                                   | pure MMIO                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `src/board/*/emmc2.flash`               |          0 | `emmc2-block`                                                                                                                                 | pure MMIO + board-spezifisch (BCM2711-SDHCI vs. virt-Fake); Verhalten verifiziert auf echter Pi-4-Hardware                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `src/board/rpi4b/mailbox.flash`         |          0 | `emmc2-block` (via die Clock-Rate- / GPIO- / Power-State-Calls des Treibers)                                                                  | pure MMIO-Doorbell; Message-Layout + Parsing getestet in `src/mailbox.flash`                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `src/usb_descriptors.flash`             |         16 | — (USB-C-Console, nur Pi-HW)                                                                                                                  | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `src/usb_tx_ring.flash`                 |          7 | — (USB-C-Console, nur Pi-HW)                                                                                                                  | pure Bulk-IN-TX-Ring-Arithmetik (monotone u64-head/tail, peek-then-advance); der MMIO/FIFO-Consumer in `src/board/rpi4b/usb.flash` bleibt hardware-verifiziert                                                                                                                                                                                                                                                                                                                                                                       |
| `src/board/rpi4b/usb.flash`             |          0 | — (USB-C-Console, nur Pi-HW)                                                                                                                  | DWC2-MMIO; QEMU `raspi4b` emuliert den Device-Mode-Data-Pfad nicht, sodass Enumeration, der Connection-Manager und die Bulk-Console-Loop (inkl. Replug-Re-Enumeration) auf echter Pi-4-Hardware verifiziert werden; das Descriptor-Set + SETUP-Decode, das es konsumiert, sind in `src/usb_descriptors.flash` host-getestet, der TX-Ring in `src/usb_tx_ring.flash`                                                                                                                                                                    |

Totals: **464 Host-Tests** (`zig build test`, aus dem Build-Graph gezählt von
`scripts/test_tally.sh`) + **30 In-Kernel-EL0-Szenarien** +
**1 Pre-PID-1-EL1-Szenario** (`emmc2-block`, `run-virt` / `run`). Die
Per-Modul-Spalte oben ist ein ungefährer Breakdown — der autoritative
Total ist, was auch immer `zig build test` druckt; der Test-Root von
`fork.flash` re-läuft auch die Tests von `src/elf.flash` durch einen direkten
File-Import, sodass die Tests einiger Module ein zweites Mal innerhalb des
Steps von `fork.flash` ausgeführt werden.

### Ausgabe-Marker

| Marker                     | Bedeutung                                                                                                                                                              |
| :------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[TEST] <name>`            | Szenario gestartet                                                                                                                                                     |
| `[PASS] <name>`            | Szenario mit dem erwarteten Free-Page-Count beendet                                                                                                                    |
| `[FAIL] <name>`            | Szenario mit einem Leak oder falschem Return-Value beendet                                                                                                             |
| `X/Y passed`               | Finaler Tally;`X == Y` ist die Green-Run-Bedingung                                                                                                                     |
| `type 'help' for commands` | Boot-Success-Marker — fshs Homescreen-Schweif, einmal beim interaktiven REPL-Eintritt gedruckt; der QEMU-Watchdog und der Real-HW-`picapture`-Helper warten beide darauf (3× pro Boot) |
| `ERROR CAUGHT`             | Kernel-seitiger Fault (Data-Abort, Instruction-Abort, etc.)                                                                                                            |
| `kill ok`, `exec-elf ok`   | Per-Szenario-Progress-Prints                                                                                                                                           |

Greens erfordern: `X == Y`, alle `[PASS]` kein `[FAIL]`, 0 `ERROR CAUGHT`,
34 Per-Szenario-Checkpoints + 1 Boot-Baseline und fshs Homescreen-
Marker (`type 'help' for commands`) 3× pro Boot emittiert.

## 9. Build-Artefakte

| File                       | Beschreibung                                            |
| :------------------------- | :------------------------------------------------------ |
| `zig-out/kernel8.img`      | Raw-Binary; Firmware lädt es zu physisch `0x80000`      |
| `zig-out/armstub8.bin`     | EL3-Bootstrap-Shim, von der Firmware geladen            |
| `zig-out/bin/kernel8.elf`  | Unstripped-ELF, behält Debug-Info für `nm` / `objdump`  |
| `zig-out/bin/armstub8.elf` | Unstripped-armstub-ELF                                   |

---

[← Zurück: README](README.md) · [Weiter: Setup →](SETUP.md)

<!-- sync-ref: DOCUMENTATION.md @ 8d306a79130b85ad3ba5502a83d80be45709d1f9 | synced 2026-07-01 -->
