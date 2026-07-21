# Raspberry Pi 4B boot firmware (vendored)

Closed-source Raspberry Pi 4B boot firmware, vendored here so a clean checkout
can boot on hardware without a separate download. These are third-party
binaries; they are not part of the FlashOS source and are not covered by the
FlashOS licence.

## Files

| File                        | Role                                                        |
| :-------------------------- | :---------------------------------------------------------- |
| `start4.elf`                | VideoCore GPU firmware / second-stage bootloader (BCM2711)  |
| `fixup4.dat`                | SDRAM partition fixup data paired with `start4.elf`         |
| `bcm2711-rpi-4-b.dtb`       | Device tree blob for the Raspberry Pi 4 Model B             |
| `overlays/miniuart-bt.dtbo` | Overlay swapping PL011 to Bluetooth so the Mini-UART is the console |

## Upstream

- Source: [raspberrypi/firmware](https://github.com/raspberrypi/firmware),
  `boot/` directory.
- License: the Raspberry Pi / Broadcom firmware licence that ships with that
  repository (`boot/LICENCE.broadcom`). Redistribution of the unmodified
  binaries is permitted for use on Raspberry Pi devices; see the upstream
  licence for the exact terms.

## Provenance

The exact upstream release tag / `git` commit these blobs were downloaded from
was not recorded when they were first vendored, so it is **to be confirmed**.
The following is established from the repository and from build identifiers
embedded in `start4.elf` itself:

- First committed to this repository in the initial public release
  (2026-06-05).
- `start4.elf` embedded build identifiers (`strings start4.elf | grep VC_BUILD_ID`):
  - `VC_BUILD_ID_VERSION: ce768004a1c9657e60b33b0cc413d8e07320cb0d`
    (the raspberrypi/firmware source revision the binary was built from)
  - `VC_BUILD_ID_TIME: Feb 11 2026`
  - `VC_BUILD_ID_BRANCH: bcm2711_2`
  - `VC_BUILD_ID_PLATFORM: raspberrypi_linux`

To pin this precisely, cross-reference the `VC_BUILD_ID_VERSION` hash above
against the raspberrypi/firmware history and record the matching `boot/`
snapshot here.

## Checksums

`SHA256SUMS` lists a SHA-256 for every file in this directory (paths relative
to this directory; the sums file excludes itself). Verify with:

```bash
cd vendor/raspberrypi-firmware/rpi4b
shasum -a 256 -c SHA256SUMS
```

## Updating

1. Download the desired `boot/` files from raspberrypi/firmware at a known tag
   or commit (`start4.elf`, `fixup4.dat`, `bcm2711-rpi-4-b.dtb`, and any needed
   overlays).
2. Replace the files in this directory.
3. Regenerate the checksums:

   ```bash
   cd vendor/raspberrypi-firmware/rpi4b
   find . -type f ! -name SHA256SUMS -exec shasum -a 256 {} + | sort -k2 > SHA256SUMS
   ```

4. Update the Provenance section above with the tag/commit you fetched.
5. Reboot on hardware to confirm the new firmware still hands off to the kernel.
</content>
</invoke>
