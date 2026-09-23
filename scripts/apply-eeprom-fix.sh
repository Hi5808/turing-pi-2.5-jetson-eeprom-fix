#!/bin/bash
# Turing Pi 2/2.5 has no carrier-board EEPROM. NVIDIA's flasher expects one, so
# Turing's own guide tells you to set the carrier-EEPROM read size to zero:
#   https://docs.turingpi.com/docs/orin-nxnano-flashing-os
#
# Only the CARRIER eeprom (cvb_*) is changed. The MODULE eeprom (cvm_*) must stay readable.
#
#   ./apply-eeprom-fix.sh /path/to/Linux_for_Tegra
#
# Keeps a .orig copy next to each file. Safe to run twice.
set -euo pipefail

L4T="${1:?usage: $0 /path/to/Linux_for_Tegra}"
files=(
    "$L4T/bootloader/tegra234-mb2-bct-common.dtsi"
    "$L4T/bootloader/generic/BCT/tegra234-mb2-bct-misc-p3767-0000.dts"
)
for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "missing: $f (is this a Jetson Linux R36+/R39 Linux_for_Tegra tree?)"; exit 1; }
    [ -f "$f.orig" ] || cp "$f" "$f.orig"
    sed -i 's/cvb_eeprom_read_size = <0x100>/cvb_eeprom_read_size = <0x0>/g' "$f"
    printf '%s\n' "--- $f"
    diff "$f.orig" "$f" || true
done
echo "done. Verify: grep -n eeprom_read_size ${files[*]}"
