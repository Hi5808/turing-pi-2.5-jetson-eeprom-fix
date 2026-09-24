#!/bin/bash
# Direct boot-flash (QSPI) backup and QSPI-ONLY flash for the ONE Jetson Orin module in recovery mode.
#
# Uses NVIDIA's first-stage loader only. It never boots a temporary Linux on the module and
# never writes the NVMe/eMMC, so your OS and data are untouched.
#
#   TARGET=<label> ./qspi.sh prepare   detect the module + build NVIDIA's command file (writes NOTHING)
#   TARGET=<label> ./qspi.sh dump      READ every QSPI partition into ./qspi-backup-<label>/ (read-only)
#   TARGET=<label> ./qspi.sh flash     write ONLY the QSPI (needs a verified backup + the EEPROM fix)
#   TARGET=<label> ./qspi.sh restore   UNDO: put the original boot flash back from the backup (DRY_RUN=1 = read-only)
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
restore)
    # UNDO: put the ORIGINAL boot flash back from a verified backup.
    # Writes only the partitions that differ from the backup, reads every write back and
    # compares it, and stops at the first problem. The module is coldbooted at the end.
    #   DRY_RUN=1  only report which partitions differ; write nothing (read-only)
    #   NO_REBOOT=1  leave the module in recovery mode when done
    # Skipped on purpose: BCT (boot-ROM table, unchanged by the fix), the two GPT copies,
    # and uefi_variables / uefi_ftw (the running firmware rewrites those on every boot).
    one_in_recovery
    ( cd "$OUT" && [ "$(ls -1 *.bin | wc -l)" -ge 60 ] && sha256sum -c --quiet SHA256SUMS ) \
        || { echo "Backup missing or damaged in $OUT."; exit 1; }
    [ -s "$BL/flashcmd.txt" ] || { echo "Run 'TARGET=$TARGET ./qspi.sh prepare' first, on THIS module."; exit 1; }
    if [ "${DRY_RUN:-0}" != 1 ]; then
        echo "This writes the ORIGINAL boot flash (QSPI) back from: $OUT"
        echo "If that original firmware did not boot on this board, run './qspi.sh flash' afterwards to re-apply the fix."
        read -r -p "Type RESTORE to continue: " ans
        [ "$ans" = "RESTORE" ] || { echo "Cancelled."; exit 1; }
    fi
    sudo -v
    DRY_RUN="${DRY_RUN:-0}" NO_REBOOT="${NO_REBOOT:-0}" python3 - "$BL" "$CFG" "$OUT" <<'PY' 2>&1 | tee -a "$LOG"
import subprocess, sys, os, tempfile, shutil
import xml.etree.ElementTree as ET
bl, cfg, out = sys.argv[1:4]
dry = os.environ.get("DRY_RUN") == "1"
no_reboot = os.environ.get("NO_REBOOT") == "1"
base = open(os.path.join(bl, "flashcmd.txt")).read().strip()
i = base.rfind('--cmd "')
if i < 0:
    sys.exit("no --cmd found in flashcmd.txt")
j = base.find('"', i + 7)
sizes, inst = {}, "0"
for d in ET.parse(cfg).getroot().iter("device"):
    if d.attrib.get("type") == "spi":
        inst = d.attrib.get("instance", "0")
        for p in d.iter("partition"):
            s = (p.find("size").text or "").strip()
            if s and p.attrib["name"] != "secondary_gpt":
                sizes[p.attrib["name"]] = int(s, 0)
SKIP = {"BCT", "secondary_gpt", "secondary_gpt_backup", "uefi_variables", "uefi_ftw"}
names = [n for n in sizes if n not in SKIP and os.path.exists(os.path.join(out, n + ".bin"))]
names.sort(key=lambda n: ("BCT" in n, n))          # *_BCT partitions last, like NVIDIA's own flash

def run(cmd):
    return subprocess.run(["sudo", "bash", "-c", "cd '%s' && %s" % (bl, cmd)],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

tmp = tempfile.mkdtemp(prefix="qspi-restore-")
def cleanup():
    subprocess.run(["sudo", "rm", "-rf", tmp])
def fail(msg, r=None):
    print("STOPPED: " + msg)
    if r is not None:
        print(r.stdout[-1200:])
    cleanup()
    sys.exit(1)

print("== starting module session", flush=True)
sess = os.path.join(tmp, "session.bin")
r = run(base[:i] + '--cmd "read BCT %s"' % sess + base[j + 1:])
if not (os.path.exists(sess) and os.path.getsize(sess) == 1048576):
    fail("could not start a session. Power-cycle the module into recovery (tp-recovery.sh) and try again.", r)

def read_current(name):
    dst = os.path.join(tmp, name + ".cur")
    if os.path.exists(dst):
        subprocess.run(["sudo", "rm", "-f", dst])
    r = run("./tegradevflash_v2 --read /spi/%s/%s '%s'" % (inst, name, dst))
    if not os.path.exists(dst) or os.path.getsize(dst) != sizes[name]:
        fail("could not read current contents of %s" % name, r)
    return open(dst, "rb").read()

same, todo, restored = [], [], []
for name in names:
    want = open(os.path.join(out, name + ".bin"), "rb").read()
    if len(want) != sizes[name]:
        fail("backup file for %s has the wrong size" % name)
    if read_current(name) == want:
        same.append(name)
        print("   same     %s" % name, flush=True)
        continue
    todo.append(name)
    if dry:
        print("   DIFFERS  %s  (would restore)" % name, flush=True)
        continue
    # NOR flash must be ERASED before it is written, otherwise old and new bytes are ANDed together.
    # (NVIDIA's own sparse QSPI update does the same: --erase, then --write.)
    run("./tegradevflash_v2 --erase /spi/%s/%s" % (inst, name))
    r = run("./tegradevflash_v2 --write /spi/%s/%s '%s'" % (inst, name, os.path.join(out, name + ".bin")))
    if read_current(name) != want:
        fail("%s did not verify after writing. Do NOT reboot; re-run restore." % name, r)
    restored.append(name)
    print("   RESTORED %s  (verified by read-back)" % name, flush=True)

print("\nSUMMARY: %d checked, %d already identical, %d %s" % (
    len(names), len(same), len(todo), "differ (dry run, nothing written)" if dry else "restored and verified"))
if not dry and not no_reboot:
    print("== coldbooting the module", flush=True)
    run("./tegradevflash_v2 --reboot coldboot")
cleanup()
PY
    ;;
*) echo "usage: TARGET=<label> $0 prepare|dump|flash|restore"; exit 2 ;;
esac
