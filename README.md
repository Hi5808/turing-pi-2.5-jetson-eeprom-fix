# Turing Pi 2.5 Jetson EEPROM fix

**Jetson Orin NX / Orin Nano won't boot in your Turing Pi 2 / 2.5 — but works fine on its original carrier? This fixes it without wiping your NVMe.**

The Turing Pi has no carrier-board EEPROM, which Jetson boot firmware expects. This repo is the tested, scripted way to fix a module that was set up for another carrier (Seeed reComputer, NVIDIA dev kit, …).

If your module was flashed for another carrier board (Seeed reComputer J401/J301, an NVIDIA dev kit, …) and then moved into a Turing Pi node, it often just sits there. This repo documents the fix that worked, plus scripts that make it a few commands. The fix rewrites **only the module's own boot flash (QSPI)**. Your NVMe, OS and data are never touched, and the scripts make you take a verified backup of the boot flash first.

> **Status: worked for us, not proven for everyone.** See [Tested on](#tested-on) and [What we don't know](#what-we-dont-know). Flashing boot firmware carries real risk. Read the whole README first.

## Symptoms (you probably recognise these)

- The node's red power LED is on, but the green/orange status LED never lights and the fan never spins.
- `tpi power status` says the node is **On**.
- `tpi uart -n <N> get` is empty forever; nothing appears on the network (no DHCP lease, no IPv6 link-local reply) — yet the BMC's switch log shows the node's Ethernet **link comes up at 1 Gbps**.
- The module still shows up in USB recovery mode (`lsusb`: `0955:7323 … Orin NX 16GB recovery mode` or `0955:7523 … APX`). That proves it is alive: power, seating and USB are fine.
- Trying the usual routes fails in confusing ways: `l4t_initrd_flash.sh` / Seeed's tool stall at `Waiting for target to boot-up...`, or NVIDIA's tools print `ERROR: might be timeout in USB write.`

## Why (best current understanding)

The boot firmware in the module's QSPI was written for a different carrier. The Turing Pi has **no carrier-board EEPROM**, which NVIDIA's flasher and boot chain expect ([Turing's own guide](https://docs.turingpi.com/docs/orin-nxnano-flashing-os) calls this out). Rewriting the QSPI with NVIDIA's standard configuration plus that EEPROM change made both of our modules boot their existing NVMe systems.

The obvious ways to reflash all **write the NVMe too** (Seeed's tool, `l4t_initrd_flash.sh`), which is exactly what you don't want. The QSPI-only path used here needs neither.

## What you need

- Turing Pi 2/2.5 with the BMC reachable, and [`tpi`](https://github.com/turing-machines/tpi) on your PC.
- A **USB-C data cable** from the board's flashing port (**USB_OTG**, a.k.a. the "4xnode USB_DEV" USB-C) to your PC. The board has three USB-C ports; the other two are the BMC's USB serial and UART console. The right one shows `NVIDIA … recovery mode` in `lsusb`.
- A Linux PC (x86_64) with NVIDIA **Jetson Linux** matching your module's JetPack: only the **Driver Package (BSP)**, extracted so you have `Linux_for_Tegra/` (no root filesystem and no `apply_binaries.sh` needed for these scripts). See [docs/HOST-NOTES.md](docs/HOST-NOTES.md) for a few missing packages on recent Ubuntu versions.
- `sudo` on that PC.

## The method

Set once (BMC address and credentials for `tpi`; never commit these):

```bash
export TPI_HOSTNAME=<bmc-address> TPI_USERNAME=root TPI_PASSWORD=<your-bmc-password>
export WORKDIR=~/jetson-recovery      # the directory that contains Linux_for_Tegra/
```

1. **Apply Turing's EEPROM fix** to the BSP (keeps `.orig` copies; only the *carrier* EEPROM setting changes):
   ```bash
   scripts/apply-eeprom-fix.sh $WORKDIR/Linux_for_Tegra
   ```
2. **Fresh recovery session** for the node (a real BMC power-cycle every time — see [troubleshooting](docs/TROUBLESHOOTING.md#every-run-needs-a-fresh-power-cycle)):
   ```bash
   scripts/tp-recovery.sh 2          # node number 1-4
   ```
3. **Detect the module and build NVIDIA's command file** (writes nothing to the module):
   ```bash
   TARGET=nx16 scripts/qspi.sh prepare
   ```
4. **Back up the module's whole boot flash** (read-only, ~1–2 minutes, 64 MB):
   ```bash
   TARGET=nx16 scripts/qspi.sh dump      # ends with: SUMMARY: 60 partitions read OK, 0 failed
   ```
   Keep this folder (`qspi-backup-nx16/`). It's your way back.
5. **Fresh recovery again**, then flash **QSPI only**:
   ```bash
   scripts/tp-recovery.sh 2
   TARGET=nx16 scripts/qspi.sh flash     # verifies the backup, asks you to type FLASH
   ```
6. The module reboots by itself. Watch for the green LED and a DHCP lease; log in as you always did.

Do one module at a time, and use a different `TARGET` label (`nx16`, `nano8`, …) for each so backups never overwrite each other. Only **one** Jetson may be in recovery mode while the tools run.

### Undoing it (restore)

`qspi.sh restore` puts your original boot flash back from the backup. It reads the module's current contents, **writes only the partitions that differ**, reads every write back to verify it, stops at the first problem, and coldboots the module at the end.

```bash
scripts/tp-recovery.sh 2                           # fresh recovery session
TARGET=nx16 DRY_RUN=1 scripts/qspi.sh restore      # read-only: shows what WOULD change
TARGET=nx16 scripts/qspi.sh restore                # asks you to type RESTORE
```

Tested round-trip on an Orin Nano: fix applied (boots) → `restore` (10 partitions restored, each verified by read-back) → the original firmware again fails to boot on the Turing Pi and the module drops into USB recovery mode → `flash` again (boots, NVMe data intact). Restoring does **not** make an unbootable module boot on your Turing Pi; it returns the original state. Re-run `flash` to get the fix back.

Not restored on purpose: `BCT` (boot-ROM table, unchanged by the fix), the GPT copies, and `uefi_variables`/`uefi_ftw` (the running firmware rewrites those on every boot).

> **Never write flash without erasing first.** Our first restore attempt wrote a partition without an `--erase`; NOR flash then ANDs old and new bytes together and the read-back check failed. `restore` now erases before writing (as NVIDIA's own sparse QSPI update does). If you script your own writes with `tegradevflash_v2`, do the same and always verify by reading back.

## What the fix actually changes

Comparing an original backup with the module after the fix (`qspi.sh restore` in dry-run mode) shows that **only 10 of 56 partitions differ**: five kinds, each in both boot slots (A and B).

| Partition | What it is |
|---|---|
| `mb2` | MB2 bootloader, contains the MB2 BCT, where the carrier-EEPROM read size lives |
| `MB1_BCT` | early hardware configuration: pin-mux, pad voltages, power |
| `cpu-bootloader` | UEFI plus its device tree |
| `dce-fw` | display firmware bundled with a device tree |
| `VER` | version stamps |

Everything else (MB1, memory config, BPMP, secure OS, USB/PSC/TSEC firmware, …) was already identical. If you are hunting the single setting responsible for the non-boot, it is one of these.

## Tested on

| | |
|---|---|
| Board | Turing Pi 2.5.1, BMC firmware 2.3.2 |
| Modules | Jetson Orin NX 16GB (P3767-0000) and Orin Nano 8GB (P3767-0003), both from Seeed reComputer units, each with a 1 TB NVMe holding a JetPack 7.2 system |
| Jetson Linux | R39.2.0 (JetPack 7.2) |
| Host | Ubuntu 26.04 x86_64, `tpi` 1.0.7 |
| Result | Both modules boot their existing NVMe systems on the Turing Pi, data intact |

Not tested: Turing Pi 2 (v2.0 board), other JetPack releases, Orin NX 8GB / Nano 4GB, Xavier / TX2 modules, modules without an NVMe. Reports welcome.

## What we don't know

- **The exact root cause.** We narrowed it to 10 partitions ([above](#what-the-fix-actually-changes)) but never proved which single setting was stopping the boot. Treat "boot firmware for the wrong carrier + missing carrier EEPROM" as the working explanation, not a finding.
- Whether the EEPROM change alone would have sufficed. We applied it together with NVIDIA's standard configuration, so the effects are mixed.
- Whether older JetPack releases (R35/R36) behave the same; board names and paths differ (`ls Linux_for_Tegra/*-qspi.conf`).

## Safety

- Every write step is gated: `qspi.sh flash` refuses to run without an intact, checksum-verified backup and the EEPROM fix, and makes you type `FLASH`.
- Nothing here writes to the NVMe/eMMC. Even so, **back up data you can't lose** first (e.g. image the NVMe on another machine).
- This is community documentation, not NVIDIA or Turing Pi support. Use at your own risk.

## More

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): every error message we hit, the cause, and the fix.
- [docs/HOST-NOTES.md](docs/HOST-NOTES.md): preparing the NVIDIA BSP on a very new Ubuntu.

## Credits and references

- Turing Pi docs: [Flashing OS (Orin NX/Nano)](https://docs.turingpi.com/docs/orin-nxnano-flashing-os), [v2.5 changelog](https://docs.turingpi.com/changelog/turing-pi2-v25-list-of-improvements)
- Community threads with the same symptoms: [Turing Pi forum: Orin NX](https://forum.turingpi.com/t/16218946/turing-pi-v2-orin-nx-v36-2-ubuntu-22-04-kernel-5-15-122-tegr), [OE4T discussion #1304](https://github.com/orgs/OE4T/discussions/1304), [NVIDIA forum: Waiting for target to boot-up](https://forums.developer.nvidia.com/t/waiting-for-target-to-boot-up-timeout-cleaning-up-in-orin-nano/288818)

## License

MIT, see [LICENSE](LICENSE).
