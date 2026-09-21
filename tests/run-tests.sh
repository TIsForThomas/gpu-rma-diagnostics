#!/bin/bash
#
# run-tests.sh - exercise collect-gpu-rma-logs.sh on a machine with no GPU.
#
# Two kinds of check:
#
#   STATIC   assertions about the source. Most of these encode a specific bug
#            that shipped in v1.3, so that it cannot come back by accident.
#   RUNTIME  the script actually runs, against a directory of stub binaries
#            that stand in for nvidia-smi, rocm-smi, dmidecode and friends.
#            Nothing here needs a GPU, a driver, or a vendor package.
#
# The runtime group needs root, because the script refuses to run without it
# and that refusal is itself worth keeping. Run the whole file under sudo:
#
#   sudo tests/run-tests.sh
#
# Skip the runtime group with: SKIP_RUNTIME=1 tests/run-tests.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../collect-gpu-rma-logs.sh"
WORK="$(mktemp -d /tmp/gpu-rma-tests.XXXXXX)"
STUB="$WORK/stubbin"
PASS=0; FAIL=0; SKIP=0

trap 'rm -rf "$WORK"' EXIT

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s  -- %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s  -- %s\n' "$1" "${2:-}"; SKIP=$((SKIP+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$3' got '$2'"; fi; }

[ -r "$SUT" ] || { echo "cannot read $SUT" >&2; exit 1; }

# The "never do X" assertions below have to look at code, not at prose. This
# file documents each v1.3 bug in a comment next to the fix, and the usage
# text quite reasonably tells the reader to run the script under sudo, so a
# naive grep matches the very explanations that prove the bug is gone.
# Strip whole-line comments and here-doc bodies first.
CODE="$WORK/code-only.sh"
awk '
    /<<[-]?[A-Z]+$/ { sub(/.*<</,""); gsub(/[-"]/,""); hd=$0; print ""; next }
    hd != "" { if ($0 == hd) hd=""; print ""; next }
    /^[[:space:]]*#/ { print ""; next }
    { print }
' "$SUT" > "$CODE"

echo "gpu-rma-diagnostics test suite"
echo "  subject : $SUT"
echo "  work    : $WORK"
echo

# ===========================================================================
echo "S. Static checks on the source"
# ===========================================================================

# S01: it parses.
if bash -n "$SUT" 2>/dev/null; then ok "S01 bash -n parses cleanly"; else bad "S01 bash -n parses cleanly"; fi

# S02: `local` only ever inside a function.
#
# v1.3 used `local` at script scope in its summary block. bash refuses that
# ("local: can only be used in a function"), so those variables stayed unset
# and the file counts it meant to report never appeared. Walk the file tracking
# brace depth and assert every `local` is nested.
depth_violations=$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { depth++; next }
    /^\}/ { if (depth > 0) depth--; next }
    /^[[:space:]]*local[[:space:]]/ { if (depth == 0) print NR": "$0 }
' "$SUT")
chk "S02 no 'local' at script scope" "$(printf '%s' "$depth_violations" | grep -c .)" "0"
[ -n "$depth_violations" ] && printf '        %s\n' "$depth_violations"

# S03: never kill by pattern-matching ps output.
#
# v1.3 ran `for keyword in nvidia cuda gpu; do ps aux | grep -i $keyword ...
# kill -9`. On a fleet whose node names begin with GPU that matches the
# operator's own SSH session, and it matches this script, whose output
# directory is gpu_rma_*.
psgrep=$(grep -nE 'ps +(aux|-ef).*\|.*grep' "$CODE" | grep -viE '^\s*[0-9]+:\s*#' || true)
chk "S03 no 'ps aux | grep' process selection" "$(printf '%s' "$psgrep" | grep -c .)" "0"

# S04: process selection asks the kernel who holds the device node.
if grep -q 'fuser /dev/nvidia' "$SUT" && grep -q 'lsof -t' "$SUT"; then
    ok "S04 GPU holders resolved via fuser/lsof on the device nodes"
else
    bad "S04 GPU holders resolved via fuser/lsof on the device nodes"
fi

# S05: the kill path refuses to target itself, its parent or its process group.
n=0
grep -q 'self=\$\$' "$SUT" && n=$((n+1))
grep -q 'parent=\$PPID' "$SUT" && n=$((n+1))
grep -q 'pgid' "$SUT" && n=$((n+1))
chk "S05 kill path excludes self, parent and process group" "$n" "3"

# S06: every persistent state change registers an undo.
#
# v1.3 wrote /etc/modprobe.d/nvidia-blacklist.conf and ran `systemctl disable
# dcgm-exporter`, neither of which it ever undid, so a node that had logs
# collected came back from its next reboot with the GPU drivers blacklisted.
blacklist_writes=$(grep -c 'modprobe.d/' "$CODE")
reverts=$(grep -c 'push_revert' "$CODE")
if [ "$blacklist_writes" -gt 0 ] && [ "$reverts" -ge 4 ]; then
    ok "S06 state changes register an undo ($reverts push_revert calls)"
else
    bad "S06 state changes register an undo" "push_revert=$reverts"
fi

# S07: no `systemctl disable` anywhere. Stopping a service is reversible on
# its own; disabling it survives a reboot and is not what a log collector does.
chk "S07 never disables a systemd unit" "$(grep -c 'systemctl disable' "$CODE")" "0"

# S08: the revert stack runs on interrupt, not only on a clean exit.
if grep -qE '^trap .*EXIT' "$SUT" && grep -qE '^trap .*INT TERM' "$SUT"; then
    ok "S08 revert stack is trapped on EXIT and on INT/TERM"
else
    bad "S08 revert stack is trapped on EXIT and on INT/TERM"
fi

# S09: TLS verification is never disabled.
#
# v1.3 fetched a script over HTTPS with --no-check-certificate and then ran it
# as root.
chk "S09 no --no-check-certificate / curl -k" \
    "$(grep -cE 'no-check-certificate|curl[^|]*(-k|--insecure)' "$CODE")" "0"

# S10: sos is never backgrounded into a pipe.
#
# v1.3 ran `timeout ... sos ... | tee ... &` and then used $!, which is the PID
# of tee, not of sos. The monitor loop watched the wrong process, the kill hit
# tee and left sos running, and the exit-code checks read tee's status.
chk "S10 sos is not piped into a background tee" \
    "$(grep -cE 'sos(report)?.*\|.*tee.*&' "$CODE")" "0"

# S11: no `find /` sweeps of the whole filesystem.
chk "S11 no whole-filesystem find sweeps" \
    "$(grep -cE 'find +/ +-name' "$CODE")" "0"

# S12: it does not install packages onto a node it is diagnosing.
chk "S12 installs no packages" \
    "$(grep -cE '(apt|dnf|yum|zypper) +(install|-y +install)' "$CODE")" "0"

# S13: no redundant sudo. The script already refuses to start unless it is root.
chk "S13 no internal sudo calls" "$(grep -cE '\bsudo ' "$CODE")" "0"

# S14: no dead code left behind (v1.3 defined validate_input and never used it).
dead=""
for fn in $(grep -oE '^[a-z_]+\(\)' "$SUT" | tr -d '()'); do
    [ "$(grep -cE "(^|[^a-z_])$fn([^a-z_(]|\$)" "$SUT")" -eq 0 ] && dead="$dead $fn"
done
chk "S14 no unreferenced functions" "$(printf '%s' "$dead" | wc -w)" "0"
[ -n "$dead" ] && printf '        unused:%s\n' "$dead"

echo

# ===========================================================================
echo "R. Runtime, against stub tools"
# ===========================================================================

if [ -n "${SKIP_RUNTIME:-}" ]; then
    skip "R01-R12 runtime group" "SKIP_RUNTIME set"
elif [ "$(id -u)" != 0 ]; then
    skip "R01-R12 runtime group" "needs root; run: sudo $0"
else
    mkdir -p "$STUB"
    # Stub every external tool the script reaches for. Each one prints
    # something recognizable so the assertions below can prove the output
    # actually came from that tool and landed in the right file.
    make_stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

    make_stub nvidia-smi 'case "$*" in
      *"--query-gpu=driver_version"*) echo "999.88.77" ;;
      *"-q -d ECC"*) echo "STUB ECC BLOCK";;
      *nvlink*) echo "STUB NVLINK";;
      *topo*) echo "STUB TOPO";;
      *) echo "STUB NVIDIA-SMI $*";;
    esac'
    make_stub dmidecode 'case "$*" in
      *system-serial-number*) echo "STUBSERIAL123";;
      *system-product-name*) echo "STUB-CHASSIS";;
      *) echo "STUB DMIDECODE $*";;
    esac'
    for t in lspci lstopo-no-graphics fdisk dcgmi rocm-smi amd-smi modinfo journalctl uptime; do
        make_stub "$t" 'echo "STUB '"$t"' $*"'
    done
    make_stub dmesg 'echo "[    0.000000] STUB DMESG"'
    make_stub lsmod 'echo "Module Size Used by"'
    # No sos, no nvidia-bug-report.sh, no gpu-burn on purpose: the script must
    # skip them cleanly rather than fail.

    OUT="$WORK/out"; mkdir -p "$OUT"
    PATH_WITH_STUBS="$STUB:$PATH"

    # --- R01 dry run changes nothing -------------------------------------
    before=$(ls -A /etc/modprobe.d 2>/dev/null | md5sum)
    env PATH="$PATH_WITH_STUBS" GPU_RMA_OUT="$OUT" NO_COLOR=1 \
        "$SUT" --gpu nvidia --vendor lenovo --yes --dry-run >"$WORK/dry.log" 2>&1
    chk "R01 dry run exits 0" "$?" "0"
    after=$(ls -A /etc/modprobe.d 2>/dev/null | md5sum)
    chk "R02 dry run leaves /etc/modprobe.d alone" "$before" "$after"

    # --- R03 real run, nvidia --------------------------------------------
    env PATH="$PATH_WITH_STUBS" GPU_RMA_OUT="$OUT" NO_COLOR=1 \
        "$SUT" --gpu nvidia --vendor lenovo --label SLOT-3 --yes --no-sos --keep-dir \
        >"$WORK/run.log" 2>&1
    rc=$?
    chk "R03 nvidia run exits 0" "$rc" "0"

    DIR=$(find "$OUT" -maxdepth 1 -type d -name 'gpu_rma_lenovo_nvidia_SLOT-3_*' | head -1)
    if [ -z "$DIR" ]; then
        bad "R04 collection directory created" "none found under $OUT"
    else
        ok "R04 collection directory created"

        # --- R05 the stubs' output really landed in the files -------------
        chk "R05 nvidia-smi output captured" \
            "$(grep -c 'STUB NVIDIA-SMI' "$DIR/gpu_logs/nvidia-smi.txt" 2>/dev/null)" "1"
        chk "R06 per-domain queries captured (ECC)" \
            "$(grep -c 'STUB ECC BLOCK' "$DIR/gpu_logs/nvidia-smi-ecc.txt" 2>/dev/null)" "1"
        chk "R07 dmidecode captured" \
            "$(grep -c 'STUB DMIDECODE' "$DIR/system_logs/dmidecode.txt" 2>/dev/null)" "1"

        # --- R08 a missing tool is recorded, not fatal --------------------
        # sos, nvidia-bug-report.sh and gpu-burn are deliberately absent.
        if grep -qi 'sos is not installed' "$WORK/run.log" || [ ! -d "$DIR/vendor_logs/sos" ]; then
            ok "R08 absent tools are skipped without failing the run"
        else
            bad "R08 absent tools are skipped without failing the run"
        fi

        # --- R09 the summary reports honestly -----------------------------
        chk "R09 summary records the driver version from the stub" \
            "$(grep -c '999.88.77' "$DIR/summary.txt" 2>/dev/null)" "1"
        chk "R10 summary states nothing was changed" \
            "$(grep -c 'changed nothing on the node' "$DIR/summary.txt" 2>/dev/null)" "1"

        # --- R11 no state file, because no state was changed --------------
        chk "R11 no changes-made.txt on a read-only run" \
            "$([ -f "$DIR/changes-made.txt" ] && echo yes || echo no)" "no"
    fi

    # --- R12 archive produced and owned by the invoking user -------------
    ARC=$(find "$OUT" -maxdepth 1 -name 'gpu_rma_*.tar.gz' | head -1)
    if [ -n "$ARC" ] && tar -tzf "$ARC" >/dev/null 2>&1; then
        ok "R12 archive created and is a valid tarball"
    else
        bad "R12 archive created and is a valid tarball" "${ARC:-no archive}"
    fi

    # --- R13 amd path ----------------------------------------------------
    env PATH="$PATH_WITH_STUBS" GPU_RMA_OUT="$OUT" NO_COLOR=1 \
        "$SUT" --gpu amd --vendor supermicro --yes --no-sos --keep-dir >"$WORK/amd.log" 2>&1
    chk "R13 amd run exits 0" "$?" "0"
    ADIR=$(find "$OUT" -maxdepth 1 -type d -name 'gpu_rma_supermicro_amd_*' | head -1)
    chk "R14 rocm-smi output captured" \
        "$(grep -c 'STUB rocm-smi' "$ADIR/gpu_logs/rocm-smi.txt" 2>/dev/null)" "1"

    # --- R15 bad input is refused before anything is created -------------
    n_before=$(find "$OUT" -maxdepth 1 -type d | wc -l)
    env PATH="$PATH_WITH_STUBS" GPU_RMA_OUT="$OUT" NO_COLOR=1 \
        "$SUT" --gpu intel --vendor lenovo --yes >/dev/null 2>&1
    chk "R15 unknown --gpu exits 1" "$?" "1"
    chk "R16 refusal created no directory" "$(find "$OUT" -maxdepth 1 -type d | wc -l)" "$n_before"
fi

echo
echo "-----------------------------------------------------------"
printf 'pass %d   fail %d   skip %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
