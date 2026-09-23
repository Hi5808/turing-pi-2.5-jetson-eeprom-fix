#!/bin/bash
# Put ONE Turing Pi node into a fresh USB recovery session and wait for it to show up on this host.
#
#   TPI_HOSTNAME=<bmc-address> TPI_USERNAME=root TPI_PASSWORD=<bmc-password> ./tp-recovery.sh <node 1-4>
#
# Why "fresh": NVIDIA's flash tools only work reliably right after a genuine
# power-cycle into recovery. A soft "reboot to recovery" from the tool itself can
# leave the module accepting nothing until it is power-cycled through the BMC.
# Only ONE Jetson may be in recovery mode at a time (the NVIDIA tools pick one
# and refuse to guess), so power the other Jetson nodes off or let them boot.
set -euo pipefail

node="${1:?usage: $0 <node 1-4>}"
command -v tpi >/dev/null || { echo "tpi not found (https://github.com/turing-machines/tpi)"; exit 1; }
: "${TPI_HOSTNAME:?set TPI_HOSTNAME to the BMC address}"

recovery_devices() { lsusb | grep -cE '0955:7[0-9a-f]23' || true; }

tpi power off -n "$node"
sleep 3
tpi usb flash -n "$node"     # module into flashing mode, USB routed to the board's USB-C (USB_OTG) port
sleep 2
tpi power on -n "$node"

for _ in $(seq 1 30); do
    if [ "$(recovery_devices)" = 1 ]; then
        lsusb | grep -E '0955:7[0-9a-f]23'
        echo "OK: exactly one Jetson in recovery mode."
        exit 0
    fi
    sleep 1
done
echo "No (or more than one) Jetson in recovery mode after 30s." >&2
echo "Check: data-capable USB-C cable in the board's USB_OTG port, and the right node number." >&2
exit 1
