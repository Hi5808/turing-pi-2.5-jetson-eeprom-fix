#!/bin/bash
# Take a node OUT of USB flash/recovery mode after you finish flashing.
#
#   TPI_HOSTNAME=<bmc-address> TPI_USERNAME=root TPI_PASSWORD=<bmc-password> ./tp-park-usb.sh <park-node 1-4>
#
# Why this matters: the BMC REMEMBERS which node is selected for USB flash mode, and it
# survives a board restart. If you leave your Jetson selected, the next time the board (or
# the BMC) restarts, that node is powered on in USB recovery mode and never boots its OS.
#
# The BMC always has exactly one node selected, so "parking" means selecting a node that
# does NOT need to boot into an OS right now: an empty slot is best, or an RK1/CM4 node.
# Do not park on a Jetson you want to boot; that puts it in recovery mode instead.
set -euo pipefail

park="${1:?usage: $0 <park-node 1-4>   (an EMPTY slot is best)}"
command -v tpi >/dev/null || { echo "tpi not found (https://github.com/turing-machines/tpi)"; exit 1; }
: "${TPI_HOSTNAME:?set TPI_HOSTNAME to the BMC address}"

tpi usb device -n "$park"
tpi usb status
echo
echo "USB selection parked on node $park. Now power-cycle the node you just flashed so it boots normally:"
echo "  tpi power off -n <node>; tpi power on -n <node>"
