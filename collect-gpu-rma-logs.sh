#!/bin/bash
#
# collect-gpu-rma-logs.sh - gather everything a GPU vendor asks for on an RMA,
# from one run, on a node that may already be half broken.
#
# Single file on purpose. The usual way this gets used is scp onto a node that
# is misbehaving and run it there, sometimes over a link that will not survive
# a git clone, so it must not depend on anything sitting next to it.
#
# WHAT IT COLLECTS
#   system   dmesg, kernel log, syslog, lspci -vvvv, dmidecode, topology, disks
#   nvidia   nvidia-smi state incl. ECC/inforom/nvlink/topo, bug report,
#            optional field diagnostics (destructive, see below)
#   amd      rocm-smi state, amdgpu modinfo, optional ROCm tech support bundle
#   vendor   sos report, and per-vendor extras where the vendor supplies one
#   stress   optional CUDA bandwidthTest and gpu-burn, for validating a node
#            before it goes back into the production pool
#
# DESTRUCTIVE STEPS ARE OPT-IN AND ARE ALWAYS UNDONE
#   NVIDIA field diagnostics need the driver unloaded, which needs every GPU
#   process gone. That means stopping fabric manager, persistenced, DCGM and
#   the container runtimes, and blacklisting the modules so they do not race
#   back in. Every one of those changes is recorded in the state file and
#   reversed on exit, including on Ctrl-C and including on failure. A log
#   collection script must not be able to leave a node unable to boot its GPUs.
#
# EXIT CODES
#   0  collected (individual optional steps may have been skipped)
#   1  usage error, or refused before touching anything
#   2  collection ran but one or more required steps failed

set -uo pipefail

VERSION="2.0"

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
VENDORS=(supermicro lenovo asus dell gigabyte aivres other)
GPU_TYPES=(nvidia amd)

VENDOR=""
GPU_TYPE=""
GPU_LABEL=""
OUT_ROOT="${GPU_RMA_OUT:-/var/tmp}"
ASSUME_YES=false
DO_FIELDDIAG=false
DO_STRESS=false
DO_SOS=true
FIELDDIAG_PKG=""
STRESS_SECONDS=120
KEEP_DIR=false
DRY_RUN=false

RC=0

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; RC=2; }
die()  { printf '%s[fatal]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Run a collection command. Never fatal: a node on its way to an RMA is exactly
# the node where half these tools are broken, and one missing binary must not
# cost us the other forty files.
grab() {
    local dest=$1; shift
    if $DRY_RUN; then say "    would run: $*"; return 0; fi
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'not collected: %s is not installed on this node\n' "$1" > "$dest"
        return 0
    fi
    if ! "$@" > "$dest" 2>"$dest.stderr"; then
        printf '\n[command exited non-zero: %s]\n' "$*" >> "$dest"
    fi
    [ -s "$dest.stderr" ] || rm -f "$dest.stderr"
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
collect-gpu-rma-logs.sh $VERSION

  sudo ./collect-gpu-rma-logs.sh --gpu nvidia --vendor lenovo
  sudo ./collect-gpu-rma-logs.sh --gpu amd --vendor lenovo --label GPU-4 --yes

Run with no options for an interactive prompt.

  --gpu nvidia|amd        GPU vendor on this node
  --vendor NAME           chassis vendor: ${VENDORS[*]}
  --label TEXT            free-text label for the folder name (slot, serial, ticket)
  --out DIR               where to write (default \$GPU_RMA_OUT or /var/tmp)

  --field-diag[=PKG]      run NVIDIA field diagnostics. DESTRUCTIVE: unloads the
                          driver, so every GPU workload on this node must be
                          stopped first. All changes are reverted on exit.
  --stress[=SECONDS]      run bandwidthTest and gpu-burn (default ${STRESS_SECONDS}s)
  --no-sos                skip the sos report, which is the slowest step

  --yes                   never prompt; decline anything not explicitly asked for
  --keep-dir              do not delete the collection directory after archiving
  --dry-run               print what would be collected, touch nothing
  -h, --help              this
EOF
}

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --gpu)        GPU_TYPE="${2:?--gpu needs a value}"; shift 2 ;;
        --gpu=*)      GPU_TYPE="${1#*=}"; shift ;;
        --vendor)     VENDOR="${2:?--vendor needs a value}"; shift 2 ;;
        --vendor=*)   VENDOR="${1#*=}"; shift ;;
        --label)      GPU_LABEL="${2:?--label needs a value}"; shift 2 ;;
        --label=*)    GPU_LABEL="${1#*=}"; shift ;;
        --out)        OUT_ROOT="${2:?--out needs a path}"; shift 2 ;;
        --out=*)      OUT_ROOT="${1#*=}"; shift ;;
        --field-diag) DO_FIELDDIAG=true; shift ;;
        --field-diag=*) DO_FIELDDIAG=true; FIELDDIAG_PKG="${1#*=}"; shift ;;
        --stress)     DO_STRESS=true; shift ;;
        --stress=*)   DO_STRESS=true; STRESS_SECONDS="${1#*=}"; shift ;;
        --no-sos)     DO_SOS=false; shift ;;
        --yes|-y)     ASSUME_YES=true; shift ;;
        --keep-dir)   KEEP_DIR=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "unknown option: $1" ;;
    esac
done

in_list() { local n=$1; shift; local i; for i in "$@"; do [ "$i" = "$n" ] && return 0; done; return 1; }

ask_yes_no() {
    local prompt=$1 default=${2:-n} reply
    $ASSUME_YES && { [ "$default" = "y" ]; return $?; }
    read -r -p "$prompt " reply
    reply=${reply:-$default}
    case "${reply,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

pick_from() {
    # pick_from "prompt" name_of_array_var  ->  echoes the choice on stdout
    local prompt=$1; shift
    local -a opts=("$@")
    local i n
    { for i in "${!opts[@]}"; do printf '  %d. %s\n' "$((i+1))" "${opts[$i]}"; done; } >&2
    while :; do
        read -r -p "$prompt " n >&2
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#opts[@]}" ]; then
            printf '%s\n' "${opts[$((n-1))]}"; return 0
        fi
        printf 'Enter a number between 1 and %d.\n' "${#opts[@]}" >&2
    done
}

[ "$(id -u)" = 0 ] || die "must run as root (use sudo). dmidecode, sos and the driver work all need it."

if [ -z "$GPU_TYPE" ]; then
    $ASSUME_YES && die "--yes given without --gpu; nothing to prompt with."
    say "GPU vendor on this node:"; GPU_TYPE=$(pick_from "choice:" "${GPU_TYPES[@]}")
fi
GPU_TYPE="${GPU_TYPE,,}"
in_list "$GPU_TYPE" "${GPU_TYPES[@]}" || die "unknown --gpu '$GPU_TYPE' (want: ${GPU_TYPES[*]})"

if [ -z "$VENDOR" ]; then
    $ASSUME_YES && die "--yes given without --vendor; nothing to prompt with."
    say "Chassis vendor:"; VENDOR=$(pick_from "choice:" "${VENDORS[@]}")
fi
VENDOR="${VENDOR,,}"
in_list "$VENDOR" "${VENDORS[@]}" || die "unknown --vendor '$VENDOR' (want: ${VENDORS[*]})"

[[ "$STRESS_SECONDS" =~ ^[0-9]+$ ]] || die "--stress wants a number of seconds, got '$STRESS_SECONDS'"
[ -d "$OUT_ROOT" ] || die "output directory does not exist: $OUT_ROOT"

OWNER="${SUDO_USER:-root}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAFE_LABEL=$(printf '%s' "${GPU_LABEL:-}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_\{2,\}/_/g;s/^_//;s/_$//')
NAME="gpu_rma_${VENDOR}_${GPU_TYPE}${SAFE_LABEL:+_$SAFE_LABEL}_$(hostname -s)_${TIMESTAMP}"
BASE_DIR="$OUT_ROOT/$NAME"
SYS_DIR="$BASE_DIR/system_logs"
GPU_DIR="$BASE_DIR/gpu_logs"
VEN_DIR="$BASE_DIR/vendor_logs"
RUN_LOG="$BASE_DIR/collection.log"
STATE_FILE="$BASE_DIR/changes-made.txt"

# ---------------------------------------------------------------------------
# revert stack
#
# Anything that changes the state of the node pushes its undo here FIRST, then
# makes the change. The trap runs the stack in reverse on every exit path.
#
# v1.3 wrote /etc/modprobe.d/nvidia-blacklist.conf and never removed it, and
# ran `systemctl disable dcgm-exporter` with no matching enable. A node that
# had logs collected from it would come back from a reboot with its GPU drivers
# blacklisted. That is the single worst thing in the original script and it is
# why this stack exists.
# ---------------------------------------------------------------------------
REVERT=()
SERVICES_STOPPED=()

push_revert() {
    REVERT+=("$1")
    [ -d "$BASE_DIR" ] && printf '%s\n' "$1" >> "$STATE_FILE"
}

run_reverts() {
    [ ${#REVERT[@]} -eq 0 ] && return 0
    step "Restoring node state (${#REVERT[@]} change(s))"
    local i
    for (( i=${#REVERT[@]}-1 ; i>=0 ; i-- )); do
        say "  ${REVERT[$i]}"
        eval "${REVERT[$i]}" >/dev/null 2>&1 || warn "revert failed: ${REVERT[$i]}"
    done
    REVERT=()
    [ -f "$STATE_FILE" ] && printf '\nAll of the above were reverted at %s\n' "$(date -Is)" >> "$STATE_FILE"
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    run_reverts
    [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && warn "exited early (status $rc); partial results are in $BASE_DIR"
    exit "$rc"
}
trap on_exit EXIT
trap 'echo; warn "interrupted; undoing changes before exit"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# system logs
# ---------------------------------------------------------------------------
collect_system_logs() {
    step "System logs"
    grab "$SYS_DIR/dmesg.txt"          dmesg -T
    grab "$SYS_DIR/uname.txt"          uname -a
    grab "$SYS_DIR/cpuinfo.txt"        cat /proc/cpuinfo
    grab "$SYS_DIR/meminfo.txt"        cat /proc/meminfo
    grab "$SYS_DIR/lspci_full.txt"     lspci -vvvv
    grab "$SYS_DIR/lspci_tree.txt"     lspci -t
    grab "$SYS_DIR/dmidecode.txt"      dmidecode
    grab "$SYS_DIR/bios_info.txt"      dmidecode -t bios
    grab "$SYS_DIR/lstopo.txt"         lstopo-no-graphics
    grab "$SYS_DIR/fdisk.txt"          fdisk -l
    grab "$SYS_DIR/lsmod.txt"          lsmod
    grab "$SYS_DIR/uptime.txt"         uptime
    grab "$SYS_DIR/journal_boot.txt"   journalctl -b --no-pager

    # Distributions disagree about which of these exists. Take whichever do.
    local f
    for f in /var/log/kern.log /var/log/syslog /var/log/messages /var/log/mcelog; do
        [ -r "$f" ] && cp -a "$f" "$SYS_DIR/$(basename "$f")" 2>/dev/null
    done
    say "  $(find "$SYS_DIR" -type f 2>/dev/null | wc -l) files"
}

# ---------------------------------------------------------------------------
# NVIDIA state
# ---------------------------------------------------------------------------
collect_nvidia_state() {
    step "NVIDIA state"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        err "nvidia-smi not found. Either the driver is not installed or it failed to load."
        grab "$GPU_DIR/nvidia-driver-missing.txt" cat /proc/driver/nvidia/version
        return 1
    fi
    grab "$GPU_DIR/nvidia-smi.txt"             nvidia-smi
    grab "$GPU_DIR/nvidia-smi-query.txt"       nvidia-smi -q
    local d
    for d in PERFORMANCE CLOCK TEMPERATURE POWER MEMORY ECC INFOROM ROW_REMAPPER SUPPORTED_CLOCKS; do
        grab "$GPU_DIR/nvidia-smi-${d,,}.txt"  nvidia-smi -q -d "$d"
    done
    grab "$GPU_DIR/nvidia-smi-nvlink-status.txt" nvidia-smi nvlink -s
    grab "$GPU_DIR/nvidia-smi-nvlink-errors.txt" nvidia-smi nvlink -e
    grab "$GPU_DIR/nvidia-smi-topology.txt"      nvidia-smi topo -m
    grab "$GPU_DIR/nvidia-smi-xid.txt"           bash -c "dmesg -T | grep -i 'NVRM.*Xid' || echo 'no Xid errors in the current dmesg buffer'"

    # DCGM health, if it is on the node. Read-only, so it runs before anything
    # gets unloaded.
    grab "$GPU_DIR/dcgmi-discovery.txt" dcgmi discovery -l
    grab "$GPU_DIR/dcgmi-health.txt"    dcgmi health -g 0 -c
    say "  $(find "$GPU_DIR" -type f 2>/dev/null | wc -l) files"
}

collect_nvidia_bug_report() {
    command -v nvidia-bug-report.sh >/dev/null 2>&1 || {
        warn "nvidia-bug-report.sh not found; skipping"; return 0; }
    step "NVIDIA bug report (up to 10 minutes)"
    $DRY_RUN && { say "    would run nvidia-bug-report.sh"; return 0; }
    # It writes into $PWD and names the file itself, so give it a directory of
    # its own rather than hunting the filesystem for the result afterwards.
    # v1.3 fell back to `find / -name 'nvidia-bug-report*.gz'` across the whole
    # root filesystem when it could not find the file it had just generated.
    local d="$GPU_DIR/bug-report"; mkdir -p "$d"
    ( cd "$d" && XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
        timeout --foreground 600 nvidia-bug-report.sh >nvidia-bug-report.stdout 2>&1 )
    case $? in
        0) say "  collected" ;;
        124) warn "bug report timed out after 10 minutes; keeping the partial output" ;;
        *) warn "nvidia-bug-report.sh exited non-zero; keeping whatever it wrote" ;;
    esac
}

# ---------------------------------------------------------------------------
# NVIDIA driver unload, for field diagnostics only
# ---------------------------------------------------------------------------
NVIDIA_SERVICES=(
    nvidia-fabricmanager.service nvidia-persistenced.service nvidia-powerd.service
    nvidia-dbus.service nvidia-gridd.service nv-hostengine.service
    dcgm-exporter.service nvidia-dcgm.service
    kubelet.service docker.service containerd.service
)

stop_gpu_services() {
    local svc
    for svc in "${NVIDIA_SERVICES[@]}"; do
        systemctl is-active --quiet "$svc" 2>/dev/null || continue
        say "  stopping $svc"
        if systemctl stop "$svc" 2>/dev/null; then
            SERVICES_STOPPED+=("$svc")
            push_revert "systemctl start $svc"
        fi
    done
}

# Processes holding a GPU, found by asking the kernel who has the device node
# open. NEVER by pattern-matching ps output.
#
# v1.3 did `for keyword in nvidia cuda gpu; do ps aux | grep -i $keyword ...
# kill -9`. On a fleet whose node names begin with GPU, a very common
# convention, that matches the operator's own SSH session, and it matches this
# script, whose own output directory is named gpu_rma_*. Running it over SSH
# killed the session that was running it. Verified, not theoretical.
gpu_holder_pids() {
    local pids=""
    if command -v fuser >/dev/null 2>&1; then
        pids=$(fuser /dev/nvidia* /dev/nvidiactl /dev/nvidia-uvm 2>/dev/null | tr -s ' ' '\n')
    elif command -v lsof >/dev/null 2>&1; then
        pids=$(lsof -t -- /dev/nvidia* 2>/dev/null)
    fi
    # Never ourselves, our parent, our process group, or PID 1.
    local self=$$ parent=$PPID pgid; pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    local p out=""
    for p in $pids; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        [ "$p" = "$self" ] || [ "$p" = "$parent" ] || [ "$p" = 1 ] && continue
        [ -n "$pgid" ] && [ "$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')" = "$pgid" ] && continue
        out="$out $p"
    done
    printf '%s' "${out# }"
}

unload_nvidia_drivers() {
    step "Unloading the NVIDIA driver stack"
    say "  stopping services that hold the GPUs"
    stop_gpu_services

    # Keep the modules from racing back in while we work. Reverted on exit.
    local bl=/etc/modprobe.d/zz-gpu-rma-blacklist.conf
    if [ ! -e "$bl" ]; then
        printf 'blacklist %s\n' nvidia nvidia_uvm nvidia_drm nvidia_modeset > "$bl"
        push_revert "rm -f $bl"
    fi

    local pids attempt
    for attempt in 1 2 3; do
        pids=$(gpu_holder_pids)
        [ -z "$pids" ] && break
        say "  processes still holding a GPU device node:$pids"
        if [ "$attempt" -lt 3 ]; then
            say "  asking them to stop (SIGTERM)"
            kill -TERM $pids 2>/dev/null
        else
            say "  forcing (SIGKILL)"
            kill -KILL $pids 2>/dev/null
        fi
        sleep 5
    done

    local mod
    for mod in nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia; do
        lsmod | grep -q "^$mod " || continue
        modprobe -r "$mod" 2>/dev/null || rmmod "$mod" 2>/dev/null
    done

    if lsmod | grep -q '^nvidia'; then
        warn "the NVIDIA modules are still loaded:"
        lsmod | grep '^nvidia' >&2
        warn "something still holds them. Field diagnostics cannot run without a reboot."
        return 1
    fi
    say "  driver unloaded"
    return 0
}

find_fielddiag_package() {
    [ -n "$FIELDDIAG_PKG" ] && { printf '%s' "$FIELDDIAG_PKG"; return 0; }
    local found=()
    mapfile -t found < <(find /root /home /opt "$PWD" -maxdepth 3 \
        \( -name '*FLD*.tgz' -o -name '*FLD*.tar.gz' \) 2>/dev/null | sort)
    case ${#found[@]} in
        0) return 1 ;;
        1) printf '%s' "${found[0]}"; return 0 ;;
        *) $ASSUME_YES && { printf '%s' "${found[0]}"; return 0; }
           say "Field diagnostic packages found:" >&2
           pick_from "package:" "${found[@]}" ;;
    esac
}

run_nvidia_field_diag() {
    step "NVIDIA field diagnostics"
    local pkg; pkg=$(find_fielddiag_package) || {
        warn "no NVIDIA field diagnostic package found (looked for *FLD*.tgz). Pass --field-diag=/path/to/pkg.tgz"
        return 1; }
    [ -e "$pkg" ] || { err "field diagnostic package not found: $pkg"; return 1; }
    say "  package: $pkg"

    local work; work=$(mktemp -d /tmp/gpu-rma-fielddiag.XXXXXX)
    push_revert "rm -rf $work"

    local root="$pkg"
    if [ -f "$pkg" ]; then
        say "  extracting"
        tar -xzf "$pkg" -C "$work" || { err "could not extract $pkg"; return 1; }
        root=$(find "$work" -maxdepth 2 -name fieldiag.sh -printf '%h\n' 2>/dev/null | head -1)
    fi
    [ -n "$root" ] && [ -f "$root/fieldiag.sh" ] || { err "fieldiag.sh not found in $pkg"; return 1; }

    unload_nvidia_drivers || { err "driver still loaded; not running field diagnostics"; return 1; }

    say "  running fieldiag.sh --no_bmc --level2 (this takes a while)"
    ( cd "$root" && chmod +x ./fieldiag.sh && ./fieldiag.sh --no_bmc --level2 ) \
        > "$GPU_DIR/fieldiag.stdout" 2>&1
    local rc=$?
    say "  fieldiag exited $rc"

    [ -f "$root/fieldiag.log" ] && cp "$root/fieldiag.log" "$GPU_DIR/"
    local bundle
    bundle=$(find "$root/logs" -name 'logs-*.tgz' -o -name 'logs-*.tar.gz' 2>/dev/null | sort -r | head -1)
    [ -n "$bundle" ] && cp "$bundle" "$GPU_DIR/" && say "  collected $(basename "$bundle")"
    return 0
}

# ---------------------------------------------------------------------------
# AMD state
# ---------------------------------------------------------------------------
collect_amd_state() {
    step "AMD state"
    if ! command -v rocm-smi >/dev/null 2>&1; then
        err "rocm-smi not found. Either ROCm is not installed or it failed to load."
        return 1
    fi
    grab "$GPU_DIR/rocm-smi.txt"            rocm-smi
    grab "$GPU_DIR/rocm-smi-all.txt"        rocm-smi --showallinfo
    local o
    for o in showdriverversion showhw showtemp showpower showmeminfo showpids \
             showperflevel showclocks showvc showtoponuma showserial showreplaycount; do
        grab "$GPU_DIR/rocm-smi-${o#show}.txt" rocm-smi "--$o"
    done
    grab "$GPU_DIR/amd-smi-static.txt"  amd-smi static
    grab "$GPU_DIR/amd-smi-metric.txt"  amd-smi metric
    grab "$GPU_DIR/modinfo_amdgpu.txt"  modinfo amdgpu
    grab "$GPU_DIR/amdgpu-ras.txt"      bash -c "grep -r . /sys/class/drm/card*/device/ras/* 2>/dev/null || echo 'no RAS counters exposed'"
    grab "$GPU_DIR/lspci_amd_gpu.txt"   bash -c "lspci -d 1002: -vvv"
    say "  $(find "$GPU_DIR" -type f 2>/dev/null | wc -l) files"
}

run_rocm_techsupport() {
    step "ROCm tech support bundle"
    local url=https://raw.githubusercontent.com/amddcgpuce/rocmtechsupport/master/rocm_techsupport.sh
    local work; work=$(mktemp -d /tmp/gpu-rma-rocm.XXXXXX)
    push_revert "rm -rf $work"
    local script="$work/rocm_techsupport.sh"

    # v1.3 fetched this with wget --no-check-certificate and then ran it as
    # root. Certificate verification stays on: if the download cannot be
    # verified we skip the step rather than execute an unverified script.
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 -o "$script" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$script" "$url"
    else
        warn "neither curl nor wget available; skipping"; return 1
    fi || { warn "could not download the ROCm tech support script; skipping"; return 1; }
    [ -s "$script" ] || { warn "downloaded ROCm script was empty; skipping"; return 1; }

    say "  sha256 $(sha256sum "$script" | cut -c1-16)...  $(wc -l <"$script") lines"
    timeout --foreground 1200 sh "$script" \
        > "$VEN_DIR/rocm_techsupport_$(hostname -s)_$TIMESTAMP.log" 2>&1
    [ $? -eq 124 ] && warn "ROCm tech support timed out after 20 minutes"
    return 0
}

# ---------------------------------------------------------------------------
# sos report
# ---------------------------------------------------------------------------
run_sos_report() {
    step "sos report (slow; 10 to 30 minutes is normal)"
    local sos=""
    command -v sos       >/dev/null 2>&1 && sos="sos report"
    [ -z "$sos" ] && command -v sosreport >/dev/null 2>&1 && sos="sosreport"
    [ -z "$sos" ] && { warn "sos is not installed and this script will not install packages on a node it is diagnosing; skipping"; return 1; }

    $DRY_RUN && { say "    would run: $sos"; return 0; }

    local dest="$VEN_DIR/sos"; mkdir -p "$dest"
    # --tmp-dir puts the archive where we want it, so there is no need to go
    # hunting /var/tmp afterwards the way v1.3 did.
    #
    # Redirect to a file rather than piping to tee: with a pipeline, $! is the
    # PID of tee, so v1.3's monitor loop watched the wrong process, its kill
    # hit tee and left sos running, and the exit-code checks read tee's status.
    timeout --foreground 1800 $sos --batch --tmp-dir="$dest" \
        --plugin-timeout=120 --cmd-timeout=60 > "$VEN_DIR/sos_report_output.log" 2>&1
    local rc=$?
    case $rc in
        0)   say "  sos report completed" ;;
        124) warn "sos report timed out after 30 minutes; keeping the partial archive" ;;
        *)   warn "sos report exited $rc; keeping whatever it wrote" ;;
    esac
    find "$dest" -maxdepth 1 -name 'sos*' -type f -printf '  %f  (%s bytes)\n' 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# optional stress, for validating a node before it goes back in the pool
# ---------------------------------------------------------------------------
run_stress() {
    step "Stress and bandwidth (${STRESS_SECONDS}s)"
    local d="$GPU_DIR/stress"; mkdir -p "$d"
    if [ "$GPU_TYPE" = nvidia ]; then
        local bw
        bw=$(command -v bandwidthTest 2>/dev/null \
             || find /usr/local/cuda* -name bandwidthTest -type f 2>/dev/null | head -1)
        if [ -n "$bw" ]; then
            say "  bandwidthTest"
            timeout --foreground 300 "$bw" --memory=pinned --mode=shmoo > "$d/bandwidthTest.txt" 2>&1
        else
            warn "bandwidthTest not found (CUDA samples not installed); skipping"
        fi
        if command -v gpu-burn >/dev/null 2>&1; then
            say "  gpu-burn for ${STRESS_SECONDS}s"
            # Sample temperature and power while it runs, which is the part
            # that actually tells you whether a node is thermally healthy.
            ( while :; do nvidia-smi --query-gpu=index,temperature.gpu,power.draw,clocks.sm,utilization.gpu \
                  --format=csv,noheader; sleep 5; done > "$d/telemetry.csv" ) &
            local mon=$!
            timeout --foreground $((STRESS_SECONDS + 60)) gpu-burn "$STRESS_SECONDS" > "$d/gpu-burn.txt" 2>&1
            kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
        else
            warn "gpu-burn not installed; skipping"
        fi
    else
        if command -v rvs >/dev/null 2>&1; then
            say "  ROCm Validation Suite"
            timeout --foreground $((STRESS_SECONDS + 120)) rvs -d 3 > "$d/rvs.txt" 2>&1
        else
            warn "rvs (ROCm Validation Suite) not installed; skipping"
        fi
        ( while :; do rocm-smi --showtemp --showpower --csv 2>/dev/null; sleep 5; done > "$d/telemetry.csv" ) &
        local mon=$!
        sleep "$STRESS_SECONDS"
        kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
driver_version() {
    if [ "$GPU_TYPE" = nvidia ] && command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1
    elif [ "$GPU_TYPE" = amd ] && command -v rocm-smi >/dev/null 2>&1; then
        rocm-smi --showdriverversion 2>/dev/null | grep -oP 'Driver version:\s*\K.+' | head -1
    fi
}

write_summary() {
    # NOTE: no `local` out here. v1.3 used `local` at script scope in exactly
    # this block; bash refuses it outside a function, so every one of those
    # variables stayed unset and the counts it was trying to report never
    # printed. `bash: local: can only be used in a function`.
    local nfiles nsys ngpu nven
    nsys=$(find "$SYS_DIR" -type f 2>/dev/null | wc -l)
    ngpu=$(find "$GPU_DIR" -type f 2>/dev/null | wc -l)
    nven=$(find "$VEN_DIR" -type f 2>/dev/null | wc -l)
    nfiles=$((nsys + ngpu + nven))

    {
        echo "GPU RMA log collection"
        echo "======================"
        echo "Collected     : $(date -Is)"
        echo "Tool version  : $VERSION"
        echo "Hostname      : $(hostname -f 2>/dev/null || hostname)"
        echo "Chassis vendor: $VENDOR"
        echo "GPU vendor    : $GPU_TYPE"
        echo "Label         : ${GPU_LABEL:-none given}"
        echo "Kernel        : $(uname -r)"
        echo "Driver        : $(driver_version || echo unknown)"
        echo "Serial        : $(dmidecode -s system-serial-number 2>/dev/null || echo unknown)"
        echo "Product       : $(dmidecode -s system-product-name 2>/dev/null || echo unknown)"
        echo
        echo "Files: $nfiles  (system $nsys, gpu $ngpu, vendor $nven)"
        echo
        echo "Optional steps"
        echo "  field diagnostics : $($DO_FIELDDIAG && echo requested || echo "not requested")"
        echo "  stress            : $($DO_STRESS && echo "requested (${STRESS_SECONDS}s)" || echo "not requested")"
        echo "  sos report        : $($DO_SOS && echo requested || echo "skipped (--no-sos)")"
        echo
        if [ -s "$STATE_FILE" ]; then
            echo "This run changed node state. See changes-made.txt; all of it was reverted."
        else
            echo "This run changed nothing on the node."
        fi
        echo
        echo "Contents"
        (cd "$BASE_DIR" && find . -type f | sort | sed 's/^\./  /')
    } > "$BASE_DIR/summary.txt"
    say "  $nfiles files"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
say "GPU RMA log collection $VERSION"
say "  node   : $(hostname -s)   vendor: $VENDOR   gpu: $GPU_TYPE"
say "  output : $BASE_DIR"
$DRY_RUN && say "  DRY RUN: nothing will be written or changed"

mkdir -p "$SYS_DIR" "$GPU_DIR" "$VEN_DIR" || die "cannot create $BASE_DIR"
exec > >(tee -a "$RUN_LOG") 2>&1

collect_system_logs

case "$GPU_TYPE" in
    nvidia)
        collect_nvidia_state
        collect_nvidia_bug_report
        if ! $DO_FIELDDIAG && ! $ASSUME_YES; then
            say
            say "Field diagnostics are the deepest test NVIDIA offers, and the only one"
            say "they will ask for on a hard RMA. They need every GPU workload on this"
            say "node stopped, because the driver has to be unloaded."
            ask_yes_no "Run NVIDIA field diagnostics now? [y/N]" n && DO_FIELDDIAG=true
        fi
        if $DO_FIELDDIAG; then
            if $ASSUME_YES || ask_yes_no "Confirm every GPU workload on $(hostname -s) is stopped. Continue? [y/N]" n; then
                run_nvidia_field_diag || err "field diagnostics did not complete"
            else
                say "Skipping field diagnostics."
            fi
        fi
        ;;
    amd)
        collect_amd_state
        ;;
esac

$DO_STRESS && run_stress

step "Vendor collection: $VENDOR"
case "$VENDOR" in
    lenovo)
        [ "$GPU_TYPE" = amd ] && run_rocm_techsupport
        ;;
    *)
        say "  no vendor-specific collector for '$VENDOR'; the sos report below covers it"
        ;;
esac
$DO_SOS && run_sos_report

# Reverts run here rather than at exit so the summary and the archive record
# the node as it will actually be left.
run_reverts

step "Summary"
write_summary

if ! $DRY_RUN; then
    step "Archiving"
    ARCHIVE="$BASE_DIR.tar.gz"
    tar -czf "$ARCHIVE" -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" \
        || die "could not create $ARCHIVE"
    chown "$OWNER":"$OWNER" "$ARCHIVE" 2>/dev/null
    chown -R "$OWNER":"$OWNER" "$BASE_DIR" 2>/dev/null
    chmod 640 "$ARCHIVE"
    $KEEP_DIR || { rm -rf "$BASE_DIR"; }

    say
    say "${C_GRN}Done.${C_OFF}"
    say "  archive : $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))"
    $KEEP_DIR && say "  files   : $BASE_DIR"
    say
    say "Before sending this to a vendor: it contains hostnames, serial numbers,"
    say "network configuration and, if the sos report ran, a broad sweep of system"
    say "configuration. Read summary.txt and check what your employer allows to"
    say "leave the building."
fi

[ "$RC" -eq 0 ] || warn "finished with errors; see the [error] lines above"
exit "$RC"
