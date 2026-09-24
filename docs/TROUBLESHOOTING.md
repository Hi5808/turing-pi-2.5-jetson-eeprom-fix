# Troubleshooting

Each entry is a message or symptom we actually hit, what caused it, and what fixed it.

## Every run needs a fresh power-cycle

**Symptom:** the first run works, the next fails immediately with `No Board Spec. and no target connected`, `ERROR: might be timeout in USB write`, or reads that fail right after a successful one.
**Cause:** after a tool run the module is left half-way through a session (the tool asks it to "reboot to recovery"). `lsusb` still shows it, but the boot ROM won't start a new session cleanly.
**Fix:** power-cycle through the BMC before *every* tool run: `scripts/tp-recovery.sh <node>`. A changed USB device number in `lsusb` (e.g. `Device 006` → `007`) tells you it really restarted.

## A node comes up in recovery mode after the board restarts

**Symptom:** everything worked, then after a power cut or a restart of the board (or the BMC) one Jetson doesn't boot. `lsusb` on the PC shows it as `0955:7523 … APX` / `… recovery mode`, and it never appears on the network.
**Cause:** the BMC remembers which node is selected for USB flash mode, and that survives restarts. `tpi usb flash -n <node>` (used by `scripts/tp-recovery.sh`) leaves your Jetson selected. When the board comes back, the BMC powers that node on **in recovery mode**.
**Fix:** move the USB selection off it and power-cycle the node:
```bash
scripts/tp-park-usb.sh 4                 # or: tpi usb device -n <empty-or-non-Jetson-node>
tpi power off -n 2; tpi power on -n 2    # the node you flashed
```
Park on an **empty slot** if you have one. Selecting a node always puts *that* node into device mode, so don't park on a Jetson you want to boot. Confirm with `tpi usb status`.
**Tip if the board's Ethernet cable is unplugged:** the BMC is still reachable from any node that's up, over the board's internal switch. From a node with IPv6, e.g. `ssh -L 18443:[<bmc-ipv6-link-local>%<iface>]:443 <node>` then `tpi --host 127.0.0.1 --port 18443 …`.

## Nothing shows up in `lsusb` on the PC

- The board's **three** USB-C ports are not interchangeable. One is the BMC's USB serial (shows as `Turing Pi 2 (v2.5.1)`, a `ttyACM` device), one is the BMC UART bridge (CP210x, `ttyUSB`), and one is the node flashing port **USB_OTG** ("4xnode USB_DEV"). Only the last shows `NVIDIA … recovery mode`, and only after `tpi usb flash -n <node>` plus a power-cycle.
- Use a **data** cable; charge-only cables enumerate nothing.
- Test independently of your PC: `tpi usb device -n <node> --bmc` routes the node's USB to the BMC, whose `dmesg` will show an NVIDIA device if the module is in recovery mode.

## `ERROR: might be timeout in USB write.` at "Sending applet"

Seen right after the boot ROM handshake succeeds (chip ID, first files accepted), then the applet transfer times out. The laptop's kernel log showed no USB errors, so it isn't a cable/hub problem in our case.
- First make sure you power-cycled fresh (above).
- Others report it depends on cable length and node slot ([Turing forum](https://forum.turingpi.com/t/16218946/turing-pi-v2-orin-nx-v36-2-ubuntu-22-04-kernel-5-15-122-tegr)); Turing recommends flashing in **node 2**.
- On our NX it happened repeatedly on an early attempt and did not recur once we used the direct `qspi.sh` path with fresh power-cycles. We never isolated the cause.

## `Waiting for target to boot-up...` and then a timeout (no `usb0` on the host)

That is `l4t_initrd_flash.sh` / `l4t_backup_restore.sh`: they boot a temporary Linux on the module and expect a USB network device from it. On this board it never appeared, and the module's serial console stayed silent, so we could not see why. Well-known problem with published workarounds ([example](https://nvidia-jetson.piveral.com/jetson-orin-nano/waiting-for-target-to-boot-up-timeout-and-there-is-no-usb0-device-on-host/)).
**Our route around it:** don't use those tools. `qspi.sh` uses only the first-stage loader (`tegraflash.py … read` once, then `tegradevflash_v2 --read /spi/0/<partition>`), which never boots that temporary Linux. (Bonus: those tools also write the NVMe.)

## `l4t_backup_restore.sh` errors about missing files under `rootfs/…`

The tool builds its temporary image from the *Sample Root Filesystem*. Unpack it into `Linux_for_Tegra/rootfs/` (as root) and run `sudo ./apply_binaries.sh`. Not needed at all for `qspi.sh`, which only uses the bootloader directory.

## `ERROR abootimg not found` / prerequisites script fails on a new Ubuntu

See [HOST-NOTES.md](HOST-NOTES.md).

## Serial console (`tpi uart -n <N> get`) is empty

- The BMC's capture works: it returned a full boot log for an RK1 node on the same board, so an empty console on a Jetson is real (nothing reaches the BMC), not a broken tool.
- A module in USB recovery mode prints nothing on that console; it is not a useful signal there.

## The WiFi mini-PCIe card doesn't appear

Unrelated to the Jetson fix, but if you also see `PCIe Link Fail … failed to initialize host` on an RK1 node: the card's Bluetooth half shows on USB (proves it has power), while its PCIe side never links. We could not fix that from software.

## After the fix the node boots but I can't SSH in

The node gets a DHCP lease from whatever serves the board's network. If you connect the board straight to a PC, share that PC's connection (e.g. NetworkManager "Shared to other computers") so the nodes get addresses. Your existing users and keys are on the NVMe, so log in the way you always did.
