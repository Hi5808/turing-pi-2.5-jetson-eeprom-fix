#!/bin/bash
# Direct boot-flash (QSPI) backup and QSPI-ONLY flash for the ONE Jetson Orin module in recovery mode.
#
# Uses NVIDIA's first-stage loader only. It never boots a temporary Linux on the module and
# never writes the NVMe/eMMC, so your OS and data are untouched.
#
#   TARGET=<label> ./qspi.sh prepare   detect the module + build NVIDIA's command file (writes NOTHING)
#   TARGET=<label> ./qspi.sh dump      READ every QSPI partition into ./qspi-backup-<label>/ (read-only)
#   TARGET=<label> ./qspi.sh flash     write ONLY the QSPI (needs a verified backup + the EEPROM fix)
#
# Environment:
#   TARGET   required. Any label you like (e.g. nx16, nano8). Keeps backups of different modules apart.
#   WORKDIR  directory containing Linux_for_Tegra (default: current directory)
#   BOARD    NVIDIA board name with the "-qspi" suffix (default: jetson-orin-nano-devkit-super-qspi,
#            correct for Jetson Linux R39 / JetPack 7.2; Orin NX and Orin Nano both use it and the
#            tool detects the exact module. For other releases run: ls Linux_for_Tegra/*-qspi.conf)
#
# Needs sudo (USB access to the module). Everything is logged to $WORKDIR/qspi.log.
set -euo pipefail

TARGET="${TARGET:?Set which module first, e.g.  TARGET=nx16 ./qspi.sh dump}"
WORKDIR="${WORKDIR:-$PWD}"
L4T="$WORKDIR/Linux_for_Tegra"
BL="$L4T/bootloader"
CFG="$BL/generic/cfg/flash_t234_qspi.xml"
OUT="$WORKDIR/qspi-backup-$TARGET"
LOG="$WORKDIR/qspi.log"
BOARD="${BOARD:-jetson-orin-nano-devkit-super-qspi}"

[ -d "$BL" ] || { echo "No Linux_for_Tegra/bootloader under $WORKDIR (set WORKDIR)."; exit 1; }

one_in_recovery() {
    [ "$(lsusb | grep -cE '0955:7[0-9a-f]23')" = 1 ] || {
        echo "Need exactly ONE Jetson in recovery mode (see scripts/tp-recovery.sh)."; exit 1; }
}

case "${1:-}" in
prepare)
    one_in_recovery
    cd "$L4T"
    sudo ./flash.sh --no-flash "$BOARD" internal 2>&1 | tee -a "$LOG"
    [ -s "$BL/flashcmd.txt" ] && echo "OK: command file ready: $BL/flashcmd.txt"
    ;;
dump)
    [ -s "$BL/flashcmd.txt" ] || { echo "Run './qspi.sh prepare' first."; exit 1; }
    one_in_recovery
    mkdir -p "$OUT"
    sudo -v
    python3 - "$BL" "$CFG" "$OUT" <<'PY' 2>&1 | tee -a "$LOG"
import subprocess, sys, os, hashlib
import xml.etree.ElementTree as ET
bl, cfg, out = sys.argv[1:4]
base = open(os.path.join(bl, "flashcmd.txt")).read().strip()
i = base.rfind('--cmd "')
if i < 0:
    sys.exit("no --cmd found in flashcmd.txt")
j = base.find('"', i + 7)
parts, inst = [], "0"
for d in ET.parse(cfg).getroot().iter("device"):
    if d.attrib.get("type") != "spi":
        continue
    inst = d.attrib.get("instance", "0")
    for p in d.iter("partition"):
        s = (p.find("size").text or "").strip()
        if p.attrib["name"] == "secondary_gpt" or not s:
            continue
        parts.append((p.attrib["name"], int(s, 0)))

def run(shell_cmd):
    return subprocess.run(["sudo", "bash", "-c", "cd '%s' && %s" % (bl, shell_cmd)],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

# 1) Start the module ONCE, the way NVIDIA's own tool does (this also reads BCT).
sess = os.path.join(out, "BCT.bin")
print("== starting module session (reads BCT)", flush=True)
r = run(base[:i] + '--cmd "read BCT %s"' % sess + base[j + 1:])
if not (os.path.exists(sess) and os.path.getsize(sess) == 1048576):
    print(r.stdout[-2500:])
    sys.exit("FAILED to start the session. Power-cycle the module into recovery mode and try again.")
print("   session OK", flush=True)

# 2) Read every partition with the low-level reader, in the SAME session.
ok, bad = ["BCT"], []
for name, size in parts:
    if name == "BCT":
        continue
    dst = os.path.join(out, name + ".bin")
    r = run("./tegradevflash_v2 --read /spi/%s/%s '%s'" % (inst, name, dst))
    got = os.path.getsize(dst) if os.path.exists(dst) else -1
    if got == size:
        print("   OK   %-22s %d bytes" % (name, size), flush=True)
        ok.append(name)
    else:
        print("   FAIL %-22s got=%s expected=%s" % (name, got, size), flush=True)
        print(r.stdout[-500:], flush=True)
        bad.append(name)
        if len(bad) >= 3:
            print("Three partitions failed, stopping.")
            break
subprocess.run(["sudo", "chown", "-R", str(os.getuid()), out])
with open(os.path.join(out, "SHA256SUMS"), "w") as f:
    for name in ok:
        dst = os.path.join(out, name + ".bin")
        f.write("%s  %s\n" % (hashlib.sha256(open(dst, "rb").read()).hexdigest(), name + ".bin"))
print("\nSUMMARY: %d partitions read OK, %d failed: %s" % (len(ok), len(bad), bad))
sys.exit(0 if not bad else 1)
PY
    ;;
flash)
    # Writes ONLY the module's boot flash (QSPI). The NVMe/eMMC is never touched.
    one_in_recovery
    ( cd "$OUT" && [ "$(ls -1 *.bin | wc -l)" -ge 60 ] && sha256sum -c --quiet SHA256SUMS ) \
        || { echo "Backup missing or damaged in $OUT. Run './qspi.sh dump' first."; exit 1; }
    for f in "$BL/tegra234-mb2-bct-common.dtsi" "$BL/generic/BCT/tegra234-mb2-bct-misc-p3767-0000.dts"; do
        grep -q "cvb_eeprom_read_size = <0x0>" "$f" \
            || { echo "EEPROM fix not applied in $f"; echo "Run scripts/apply-eeprom-fix.sh first."; exit 1; }
    done
    echo "Backup verified. EEPROM fix applied."
    echo "This writes the module's boot flash (QSPI) only."
    read -r -p "Type FLASH to continue: " ans
    [ "$ans" = "FLASH" ] || { echo "Cancelled."; exit 1; }
    cd "$L4T"
    sudo ./flash.sh "$BOARD" internal 2>&1 | tee -a "$LOG"
    ;;
*) echo "usage: TARGET=<label> $0 prepare|dump|flash"; exit 2 ;;
esac
