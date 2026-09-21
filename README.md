# gpu-rma-diagnostics

Collect everything an NVIDIA or AMD GPU vendor asks for on an RMA, in one run,
from a node that may already be half broken.

```bash
sudo ./collect-gpu-rma-logs.sh --gpu nvidia --vendor lenovo --label SLOT-3
sudo ./collect-gpu-rma-logs.sh --gpu amd --vendor lenovo --yes --no-sos
sudo ./collect-gpu-rma-logs.sh --gpu nvidia --vendor dell --field-diag --stress=600
```

It produces one tarball: system state, GPU state, the vendor's own bundle, a
summary naming the node and driver, and a record of anything it changed.

One file, no dependencies beyond the tools it is collecting from. The usual way
this gets used is scp it onto a node that is misbehaving and run it there,
sometimes over a link that will not survive a git clone.

## Why this is not just a list of commands

Two things make GPU RMA collection harder than it sounds.

**The deep tests are destructive.** NVIDIA field diagnostics are the only thing
NVIDIA will accept on a hard RMA, and they need the driver unloaded, which
needs every process holding a GPU gone: fabric manager, persistenced, DCGM, and
whatever container runtime is feeding the cluster. So a log collector ends up
having to stop production services and blacklist kernel modules, on a machine
that is still somebody's asset.

**You are running it on the broken thing.** Half the tools you want to invoke
are missing or hanging, which is often why the node is being RMA'd in the first
place.

So the design holds to three rules:

1. **Nothing is left changed.** Every service stopped, every file written under
   `/etc`, every temporary directory pushes its undo onto a stack first. The
   stack runs in reverse on every exit path, including Ctrl-C, including
   failure. What was changed is written into `changes-made.txt` in the archive,
   so the record survives even when the operator does not see the console.
2. **One missing tool does not cost you the other forty files.** Every
   collection step records what it could not run and continues.
3. **Destructive steps are opt-in and say so.** `--field-diag` warns, names the
   node, and asks for confirmation before it unloads anything.

## What it collects

| Group | Contents |
|---|---|
| system | `dmesg -T`, kernel log, syslog, `lspci -vvvv`, PCIe tree, `dmidecode`, `lstopo`, disks, `lsmod`, boot journal |
| nvidia | full `nvidia-smi -q` plus per-domain ECC, inforom, row remapper, clocks, power, thermals; NVLink status and error counters; topology matrix; Xid errors out of dmesg; DCGM discovery and health; `nvidia-bug-report.sh` |
| amd | `rocm-smi` across every `--show*`, `amd-smi` static and metric, RAS counters from sysfs, `amdgpu` modinfo, PCI detail by vendor ID |
| vendor | sos report; ROCm tech support bundle on Lenovo AMD nodes |
| optional | NVIDIA field diagnostics (`--field-diag`); stress and bandwidth with live thermal and power telemetry (`--stress`) |

`--stress` is for the other half of the job: validating a node before it goes
back into the production pool. It samples temperature, power, clocks and
utilization every five seconds into a CSV while the load runs, because the
thermal curve under sustained load is the thing that actually tells you whether
a repaired node is healthy.

## Tests

```bash
sudo tests/run-tests.sh          # 30 checks
SKIP_RUNTIME=1 tests/run-tests.sh   # static group only, no root needed
```

The runtime group builds a directory of stub binaries standing in for
`nvidia-smi`, `rocm-smi`, `dmidecode` and the rest, then runs the real script
against them and asserts the stub output landed in the right files. No GPU, no
driver, no vendor package. `sos`, `nvidia-bug-report.sh` and `gpu-burn` are
deliberately left out of the stubs, so the suite proves that missing tools are
skipped rather than fatal.

The static group is more interesting: most of those assertions encode a
specific bug from the previous version, so it cannot come back by accident.

## What changed from v1.3

The previous version is kept at [`docs/original-v1.3.sh`](docs/original-v1.3.sh).
It worked, and it collected the right things. These are the defects found when
it was picked back up, each verified by reproducing it rather than by reading.

### It killed the session that was running it

```bash
for keyword in nvidia cuda gpu; do
  pids=$(ps aux | grep -i $keyword | grep -v grep | awk '{print $2}')
  for pid in $pids; do kill -9 "$pid"; done
done
```

`ps aux | grep -i gpu` matches any process whose **command line** contains the
string. That includes this script, whose own output directory was
`/tmp/gpu_rma_*`. On a fleet whose node names begin with `GPU`, which is a
very common convention, it also matches the operator's own SSH session.
Reproduced: a script was killed purely because its path contained "gpu".

Now the holders of a GPU are resolved by asking the kernel who has the device
node open (`fuser /dev/nvidia*`, falling back to `lsof -t`), the list is
filtered against this process, its parent, its process group and PID 1, and it
escalates SIGTERM to SIGKILL over three rounds instead of going straight to
`kill -9`.

### It left nodes unable to load their GPU drivers

`unload_nvidia_drivers()` wrote `/etc/modprobe.d/nvidia-blacklist.conf` and ran
`systemctl disable dcgm-exporter`. Nothing anywhere removed either. A node that
had logs collected from it came back from its next reboot with the NVIDIA
modules blacklisted and DCGM disabled, and nothing in the output said so.

This is the worst defect of the set, because it is silent and it turns a
diagnostic step into an outage. It is why the revert stack exists, why
`changes-made.txt` is written into the archive, and why `S06` and `S07` in the
test suite fail the build if a state change ever ships without an undo.

### The summary block could not run

```bash
local bug_reports=$(find "$GPU_LOG_DIR" -name "nvidia-bug-report*.gz" | wc -l)
```

Four of these sat at script scope, outside any function. Bash refuses `local`
there:

```
bash: local: can only be used in a function
```

The variables stayed unset, the `-gt 0` comparisons that followed failed with
"integer expression expected", and the per-category counts the summary was
trying to report never printed. The test suite now walks brace depth and fails
on any `local` at depth zero.

### The sos report monitor watched the wrong process

```bash
timeout --foreground 1800 sos report ... | tee "$log_dir/sos_report_output.log" &
local sos_pid=$!
```

After a pipeline, `$!` is the PID of the **last** element, so `sos_pid` was
`tee`. The 30-minute watchdog loop polled `tee`, its `kill -TERM` hit `tee` and
left `sos` running, and `wait; exit_code=$?` read `tee`'s status, so the
124/143/137 timeout checks below it were reading the wrong number. Verified.

Now sos redirects to a file instead of piping, and `--tmp-dir` puts the archive
where the script already intends to look. v1.3 passed `--tmp-dir` and then
searched `/var/tmp` and `/tmp` for the result anyway.

### It ran an unverified script as root

```bash
wget -O "$script_path" --no-cache --no-cookies --no-check-certificate \
  "https://raw.githubusercontent.com/..."
chmod +x "$script_path"
```

TLS verification disabled on a download that is then executed as root.
Certificate checking stays on now, the fetch pins `--proto '=https' --tlsv1.2`,
and the step is skipped rather than executed if the download cannot be
verified. The script's SHA256 and line count are logged before it runs.

### Smaller things

- `find / -name "nvidia-bug-report*.gz"` swept the entire root filesystem as a
  fallback for a file the script had just generated. The bug report now runs in
  a directory of its own.
- It installed packages (`apt install -y sosreport`) onto a node it was in the
  middle of diagnosing. It now reports that sos is absent and moves on.
- `validate_input()` was defined and never called.
- Six lines of service-stop and `rmmod` were pasted twice inside one function.
- Every internal command was prefixed with `sudo` in a script that had already
  refused to start unless it was root.
- `rmmod -f` needs `CONFIG_MODULE_FORCE_UNLOAD`, which most distribution
  kernels do not set, and taints the kernel where it works. Replaced with
  `modprobe -r` falling back to plain `rmmod`.
- No argument parsing. Every run required an interactive operator, which is the
  wrong shape for something you want to run across a fleet over SSH. There is
  now a full flag interface, `--yes`, and `--dry-run`.

## Before sending an archive to a vendor

It contains hostnames, serial numbers, network configuration, and if the sos
report ran, a broad sweep of system configuration. `summary.txt` lists every
file. Check what your employer allows to leave the building.

## License

MIT. See `LICENSE`.
