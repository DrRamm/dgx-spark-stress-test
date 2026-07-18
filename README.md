# GX10 Stress Test Suite

Burn-in suite for the Asus Ascent GX10 / NVIDIA DGX Spark (GB10, 128GB unified
memory). Goal: validate unit stability with sustained 6-24 hour workloads.

Two stress dimensions, run separately or together:

- **LLM inference** (llama.cpp, Llama 3.1 70B) — memory-bandwidth-bound: pins
  ~74GB of unified memory and saturates the memory subsystem.
- **Image generation** (stable-diffusion.cpp, SDXL 1024x1024) — compute-bound:
  near-100% SM utilization, maximum power draw and heat.

The combined test runs both at once: ~96% GPU utilization with ~85GB+ resident.

## Quick start

```bash
./0-setup.sh   # once per machine: installs deps, builds llama.cpp, creates .venv
./run.sh       # interactive menu for everything else
```

`run.sh` menu:

```
0) First-time setup         (0-setup.sh)
1) Download model           (1-download-model.sh - needed once, ~40-95GB)
2) Run server stress test   (5-stress-test-server.sh: LLM only)
3) Run combined stress test (6-stress-test-combined.sh: LLM + SDXL image gen)
```

Every prompt has a sensible default; just pressing Enter through the menus
gives a 6-hour burn-in of the recommended configuration.

## Scripts

| Script | What it does | Direct invocation |
|---|---|---|
| `0-setup.sh` | Idempotent environment bootstrap: apt deps, CUDA check, uv, `.venv` + huggingface-hub, clone/build llama.cpp with CUDA | no arguments |
| `1-download-model.sh` | Downloads a stress-test model from HuggingFace (interactive choice of 4) | no arguments |
| `5-stress-test-server.sh` | LLM stress test: loads model once via llama-server, streams topics over HTTP, logs throughput | `<length> <vram> <model>` |
| `6-stress-test-combined.sh` | Everything script 5 does, plus a concurrent SDXL image-generation loop. First run auto-builds stable-diffusion.cpp and downloads SDXL (~7.2GB) | same as script 5 |
| `9-cleanup.sh` | Delivery cleanup: removes uv + caches + `.bashrc` edits from the machine, then deletes this whole folder | no arguments |
| `run.sh` | Menu wrapper; activates `.venv` automatically | no arguments |
| `tools/dgxtop` | Bundled live TUI monitor (not installed system-wide) | no arguments |

Arguments for scripts 5 and 6 (all prompted interactively if omitted):

- `length` — duration `6h` / `12h` / `24h` (any `Nh` or `Nm` works), or topic
  count `100` / `200` / `300`
- `vram` — `low` / `moderate` / `high` (context/batch size profile)
- `model` — `small` (70B Q4, ~40GB) / `large` (70B Q8, ~74GB) /
  `xlarge` (Mixtral 8x22B Q5, ~95GB)

Example: `./6-stress-test-combined.sh 12h high large`

## Choosing a test

- **Stability qualification of a unit:** combined test, 6h minimum
  (`run.sh` option 3). This loads memory capacity, memory bandwidth, GPU
  compute, and thermals simultaneously — the hardest legitimate load.
- **Throughput benchmarking:** LLM-only test (option 2), since image-gen
  contention lowers tok/s and pollutes comparisons between runs.
- The test aborts only after 5 *consecutive* request failures (a healthy unit
  logging an occasional transient error will keep running); it also stops if
  llama-server dies.

Reference numbers measured on this hardware (70B Q8, `high` profile):

| Metric | LLM only | Combined |
|---|---|---|
| Generation speed | ~2.7-2.9 tok/s | ~1.3 tok/s (expected: shared bandwidth) |
| SDXL image (1024², 30 steps) | — | ~52s sampling + ~30s model reload per batch |
| One topic (2048 tokens) | ~13 min | ~26 min |
| Model load time | ~205s | ~255s |
| GPU temperature | ~65-70°C | ~70°C+ |

## Logs and monitoring

Each run writes to `logs/`:

- `stress_test_server_<timestamp>.log` — per-topic throughput, errors, and a
  final summary (duration, total tokens, average tok/s, error count, peak
  temperatures/power, final `nvidia-smi` snapshot)
- `gpu_monitor_<timestamp>.csv` — automatic thermal/power log for the whole
  run: GPU temp, utilization, power, SM clock, hottest SoC sensor, and system
  memory %, sampled every 10s. Starts and stops with the test.
- `gpu_alerts_<timestamp>.log` — only created if GPU temp crosses 80°C
  (warning) or 85°C (critical)
- `llama_server_<timestamp>.log` — raw llama-server output
- `imagegen_<timestamp>.log` + `images/` — combined test only; newest 20
  images are kept, older ones auto-deleted

After a burn-in, check the summary for: **Total errors** (~0), **Thermal
alerts** (none), **Avg gen throughput** (a large drop vs the reference table
suggests thermal throttling — confirm by plotting `sm_clock_mhz` and
`gpu_temp_c` from the monitor CSV).

For live watching during a run, the Spark-specific TUI monitor `dgxtop`
(GPU/CPU temps, load, memory, disk, network) ships inside this folder — it is
deliberately NOT installed system-wide, so removing the folder removes it:

```bash
./tools/dgxtop        # from any SSH session or terminal on the unit
```

## Troubleshooting

**`nvcc not found` during setup or build**
CUDA toolkit missing or not on PATH. If `/usr/local/cuda/bin/nvcc` exists:
`export PATH=/usr/local/cuda/bin:$PATH`. If not installed (Ubuntu 24.04):

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update && sudo apt install -y cuda-toolkit
```

Note: non-login shells (ssh commands, cron) don't source `~/.bashrc`, so CUDA
may be "missing" there while working in a terminal. The scripts handle this,
but for manual builds pass `-DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc`.

**`libcuda.so.1` / `libcudart.so` / `libmtmd.so` cannot open shared object**
- `libcuda.so.1` — NVIDIA driver problem: check `nvidia-smi`
- `libcudart.so.12` — `export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH`
- `libmtmd.so` (or other llama.cpp libs) — `export LD_LIBRARY_PATH=./llama.cpp/build/bin:$LD_LIBRARY_PATH`
  (the stress scripts already do this)

**Server did not become ready** — the 70B model takes ~3.5 min to load
(longer under GPU load). Script 5 waits 5 min, script 6 waits 15 min. If it
still fails, check `logs/llama_server_*.log` for the real error (usually a
wrong model path or out-of-memory).

**Model not found** — run `./1-download-model.sh` first; script 5's `small`/
`large`/`xlarge` options expect the matching model under `models/`.

**Rebuild llama.cpp or stable-diffusion.cpp after an update**
`rm -rf llama.cpp/build && ./0-setup.sh` (same pattern for
`stable-diffusion.cpp/build`, then rerun script 6).

## Preparing a unit for delivery

The suite is designed so that removing this folder removes (almost)
everything. The only traces outside the folder are what `0-setup.sh`
installs: uv (`~/.local/bin/uv`, `uvx`, `env*`), its caches
(`~/.cache/uv`, `~/.cache/huggingface`), and one PATH line in `~/.bashrc`.
Apt packages (cmake, jq, ...) are standard system tools and are left alone.

When a unit has passed burn-in and is ready for the client:

```bash
~/Desktop/gx10-stress-test/9-cleanup.sh
```

It removes all of the above, optionally clears shell history, and finally
deletes the folder itself. Save `logs/` to the flash drive first if you want
to keep the unit's burn-in evidence.

## Moving to another GX10

Copy the folder but leave run artifacts behind — `logs/` (including generated
images) is this unit's test evidence and should stay with the unit. `.venv/`
is never copied: it is not relocatable and `0-setup.sh` recreates it.

Total size with models: ~79GB (models 77GB, llama.cpp + sd.cpp builds ~2GB).

### Via flash drive (recommended workflow)

Flash drives are usually exFAT: no Linux permissions or symlinks. Use `-rt`
instead of `-a`, and restore executable bits on the target machine.

```bash
# 1. Copy onto the flash drive (drive auto-mounts under /media/$USER/)
rsync -rt --info=progress2 --modify-window=1 \
    --exclude 'logs/' --exclude '.venv/' \
    ~/Desktop/gx10-stress-test/ /media/nvidia/USB_DRIVE/gx10-stress-test/
sync                                    # flush before unplugging!

# Plain cp alternative (no progress, no resume):
# cp -r ~/Desktop/gx10-stress-test /media/nvidia/USB_DRIVE/  && sync

# 2. On the new GX10, copy from the drive and restore exec bits
rsync -rt --info=progress2 --modify-window=1 \
    /media/nvidia/USB_DRIVE/gx10-stress-test/ ~/Desktop/gx10-stress-test/
cd ~/Desktop/gx10-stress-test
chmod +x *.sh tools/dgxtop              # exFAT dropped the executable bits
./0-setup.sh
```

At ~1000 MB/s the 79GB transfer takes ~2-4 minutes each way in practice.
rsync is resumable: if interrupted, rerun the same command and it continues.

### Direct over the network

```bash
rsync -a --info=progress2 --exclude 'logs/' --exclude '.venv/' \
    ~/Desktop/gx10-stress-test/ user@new-gx10:~/Desktop/gx10-stress-test/
```

(Add `--exclude 'models/'` to either method if re-downloading ~77GB is
acceptable; over gigabit LAN the models alone take ~11 min to transfer.)

Then run `./0-setup.sh` on the new unit — it skips what already works and
rebuilds what doesn't, and recreates `.venv` and `logs/` fresh. Binaries built
on an identical OS/driver/CUDA image usually run as-is; when in doubt, delete
the `build/` dirs and let setup recompile (~10 min).

Note on images: the combined test keeps only the newest 20 generated images
(~36MB cap) and deletes older ones automatically, so `logs/images/` never
grows unbounded even on a 24h run. The kept images are worth a glance after a
burn-in — corruption or black frames indicate GPU memory instability.
