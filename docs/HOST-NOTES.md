# Preparing the NVIDIA BSP on a very new Ubuntu

NVIDIA supports Ubuntu 22.04/24.04 hosts for Jetson Linux. On newer releases (we used 26.04) a few tools break. This is all you need for the scripts in this repo, plus the extras needed only if you also want NVIDIA's `apply_binaries.sh` to complete.

## What you need for `qspi.sh`

Download from NVIDIA for your JetPack (we used Jetson Linux **R39.2.0** / JetPack 7.2):
- **Driver Package (BSP)** (`Jetson_Linux_R…_aarch64.tbz2`), extracted so you have `Linux_for_Tegra/`.

That is enough for `prepare`, `dump` and `flash` (the QSPI-only board profiles set `NO_ROOTFS=1`). Missing host packages we hit, install what's absent:

```bash
sudo apt-get install -y abootimg lbzip2 whois python3-usb
```

NVIDIA's own `tools/l4t_flash_prerequisites.sh` may fail outright on a new Ubuntu because `qemu-user-static` is now a virtual package; that aborts the whole install, so nothing gets installed. Install the individual packages above instead.

## Only if you also run `apply_binaries.sh` (needed by NVIDIA's initrd tools, not by `qspi.sh`)

1. Unpack the Sample Root Filesystem into `Linux_for_Tegra/rootfs/` **as root** (`sudo tar xpf …`).
2. NVIDIA's helper looks for a program named `qemu-aarch64-static`. Current Ubuntu ships the same static emulator as `qemu-aarch64`:
   ```bash
   sudo apt-get install -y qemu-user-binfmt binfmt-support
   sudo ln -s /usr/bin/qemu-aarch64 /usr/bin/qemu-aarch64-static
   ```
   (NVIDIA's helper already skips a known-buggy step on QEMU ≥ 8.1.1.)
3. Modern OpenSSH removed DSA keys. The recovery-ramdisk builder (`tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh`) runs `ssh-keygen -t dsa` and fails with a bare `command is failed`. The generated ramdisk's `sshd_config` only uses RSA/ECDSA/ED25519, so comment out just the DSA `ssh-keygen` line.

## USB permissions

NVIDIA's tools talk to the module over raw USB and need root, so every flashing command here uses `sudo`. Nothing else on the host needs to change.
